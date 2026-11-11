# Postgres HA for Grafana: the Patroni cluster on the role = "postgres" VMs (pg01-03). See
# modules/services/monitoring/postgres.tf, the README (Postgres HA: Patroni) and
# ~/network_automation/mon-ha/runbook-postgres.md. Deployed only once postgres_s3 (the
# pgBackRest RGW user's keys, postgres.secret.auto.tfvars) is set. Grafana moves to the VIP
# with postgres_settings.grafana_on_cluster; mon01's container goes with legacy_on_primary.

locals {
  postgres_vms     = { for name, vm in local.service_vms : name => vm if vm.role == "postgres" }
  postgres_enabled = length(local.postgres_vms) > 0 && nonsensitive(var.postgres_s3 != null)

  # Address and interface name on the backend VLAN (VIP) and the Postgres HA VLAN; the
  # management NIC is eth0 and network_devices[i] is eth<i+1>.
  # Backend-VLAN addresses of the VMs of each app database (see module "monitoring" postgres_apps).
  postgres_app_clients = {
    triage = sort(flatten([
      for name, vm in var.vms : [
        for nic in vm.network_devices : split("/", nic.ipv4_address)[0]
        if nic.vlan_id == var.backend_vlan_id && nic.ipv4_address != null
      ] if vm.role == "ticketing"
    ]))
  }

  # What Grafana's read-only role may read (the dark-triage dashboard): tickets and comments, and
  # only the non-secret user columns. Never password hashes, sessions or API token hashes.
  postgres_app_grafana_grants = {
    triage = [
      "SELECT ON tickets",
      "SELECT ON comments",
      "SELECT (id, username, display_name, role, disabled, is_bot, color, created, last_login) ON users",
    ]
  }

  postgres_nic = {
    for name in keys(local.postgres_vms) : name => {
      ha = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.postgres_ha_vlan_id && nic.ipv4_address != null
      ]), null)
      backend = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.backend_vlan_id && nic.ipv4_address != null
      ]), null)
    }
  }
  postgres_ready = alltrue([for name, n in local.postgres_nic : n.ha != null && n.backend != null])
}

resource "random_password" "pg_superuser" {
  length  = 32
  special = false
}

resource "random_password" "pg_replication" {
  length  = 32
  special = false
}

resource "random_password" "pg_restapi" {
  length  = 32
  special = false
}

resource "random_password" "pg_monitor" {
  length  = 32
  special = false
}

# The Postgres VIP's VRRP instance (HA VLAN 217, router id 104): VRRPv2 PASS, 8 characters at most.
resource "random_password" "pg_vrrp" {
  length  = 8
  special = false
}

check "postgres_s3" {
  assert {
    condition     = length(local.postgres_vms) == 0 || var.postgres_s3 != null
    error_message = "There are role = \"postgres\" VMs but postgres_s3 is not set (postgres.secret.auto.tfvars): the Patroni cluster is not deployed. See the README (Postgres HA: Patroni) for the RGW user."
  }
}

# Cutover guard: plan-time errors for switch combinations the module would silently ignore.
resource "terraform_data" "postgres_cutover" {
  input = {
    grafana_on_cluster = var.postgres_settings.grafana_on_cluster
    legacy_on_primary  = var.postgres_settings.legacy_on_primary
  }

  lifecycle {
    precondition {
      condition     = !var.postgres_settings.grafana_on_cluster || local.postgres_enabled
      error_message = "postgres_settings.grafana_on_cluster needs the Patroni cluster (role = \"postgres\" VMs and postgres_s3)."
    }
    precondition {
      condition     = var.postgres_settings.legacy_on_primary || var.postgres_settings.grafana_on_cluster
      error_message = "postgres_settings.legacy_on_primary = false would remove the Postgres Grafana still uses: set grafana_on_cluster = true first (runbook-postgres.md)."
    }
  }
}

# One per Patroni member. The first deploy must run all members together (default
# parallelism): etcd and Patroni bootstrap only with a quorum. Later changes: -parallelism=1
# for a rolling deploy (etcd restarts one at a time; Patroni is only ever reloaded).
resource "terraform_data" "postgres" {
  for_each = local.postgres_enabled ? local.postgres_vms : {}

  # Alloy pushes its journal to the Loki VIP.
  depends_on = [terraform_data.logging]

  triggers_replace = [
    sha256(module.monitoring.postgres_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = local.postgres_ready
      error_message = "Every postgres VM needs one addressed NIC each on the Postgres HA VLAN ${var.postgres_ha_vlan_id} and the backend VLAN ${var.backend_vlan_id}."
    }
    precondition {
      condition     = length(local.postgres_vms) >= 3 && length(local.postgres_vms) % 2 == 1
      error_message = "The Patroni cluster needs an odd number (at least 3) of postgres VMs: etcd runs on each and needs a majority."
    }
  }

  connection {
    type        = "ssh"
    host        = split("/", each.value.management_address)[0]
    user        = each.value.config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-postgres-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.postgres_deployments[each.key]
    destination = "/tmp/tofu-postgres-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-postgres-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-postgres-${self.id}; exit $rc",
    ]
  }
}

output "postgres_vip" {
  description = "Grafana's database on the Patroni cluster (leader VIP, host:port). null until postgres_s3 is set."
  value       = module.monitoring.postgres_vip
}

output "grafana_db_host" {
  description = "Where Grafana's database is now: the Patroni VIP after the cutover (postgres_settings.grafana_on_cluster), mon01's Postgres before."
  value       = module.monitoring.grafana_db_host
}

output "patroni_urls" {
  description = "Each member's Patroni REST API on its backend-VLAN address (GET /cluster, /metrics; reachable from the backends only)."
  value       = { for name, n in local.postgres_nic : name => "http://${try(n.backend.address, "0.0.0.0")}:8008" }
}
