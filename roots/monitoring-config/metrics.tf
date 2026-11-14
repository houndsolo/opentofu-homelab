# Mimir on the role = "metrics" VMs (mim01-03): see modules/services/monitoring/metrics.tf
# and the README (Metrics: Mimir HA). Mimir is deployed only once mimir_s3 (the RGW user's
# keys, metrics.secret.auto.tfvars) is set; until then Prometheus keeps no remote_write and
# Grafana queries Prometheus directly.

locals {
  metrics_vms   = { for name, vm in local.service_vms : name => vm if vm.role == "metrics" }
  mimir_enabled = length(local.metrics_vms) > 0 && nonsensitive(var.mimir_s3 != null)

  # Address and interface name on the backend VLAN (VIP) and the Mimir HA VLAN. The
  # management NIC is eth0 and network_devices[i] is eth<i+1>, as for the Loki VMs.
  metrics_nic = {
    for name in keys(local.metrics_vms) : name => {
      ha = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if nic.vlan_id == var.metrics_ha_vlan_id && nic.ipv4_address != null
      ]), null)
      backend = try(one([
        for i, nic in local.nics[name] : { address = split("/", nic.ipv4_address)[0], interface = "eth${i + 1}" }
        if contains(var.backend_vlan_ids, coalesce(nic.vlan_id, -1)) && nic.ipv4_address != null
      ]), null)
    }
  }
  metrics_ready = alltrue([for name, n in local.metrics_nic : n.ha != null && n.backend != null])
}

check "mimir_s3" {
  assert {
    condition     = length(local.metrics_vms) == 0 || var.mimir_s3 != null
    error_message = "There are role = \"metrics\" VMs but mimir_s3 is not set (metrics.secret.auto.tfvars): Mimir is not deployed and Prometheus has no remote_write. See the README (Metrics: Mimir HA) for the RGW user."
  }
}

# One per Mimir VM. For a rolling restart (one Mimir at a time, each waiting for /ready)
# apply with -parallelism=1, as for Loki.
resource "terraform_data" "metrics" {
  for_each = local.mimir_enabled ? local.metrics_vms : {}

  # Alloy pushes its journal to the Loki VIP.
  depends_on = [terraform_data.logging]

  triggers_replace = [
    sha256(module.monitoring.metrics_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = local.metrics_ready
      error_message = "Every metrics VM needs one addressed NIC each on the Mimir HA VLAN ${var.metrics_ha_vlan_id} and the backend VLAN ${join("/", var.backend_vlan_ids)}."
    }
    precondition {
      condition     = length(local.metrics_vms) >= var.metrics_settings.replication_factor
      error_message = "Mimir's replication_factor (${var.metrics_settings.replication_factor}) needs at least that many metrics VMs."
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
    inline = ["install -d -m 0700 /tmp/tofu-metrics-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.metrics_deployments[each.key]
    destination = "/tmp/tofu-metrics-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-metrics-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-metrics-${self.id}; exit $rc",
    ]
  }
}

output "mimir_url" {
  description = "Mimir on its backend VIP: Prometheus remote_write (/api/v1/push), Grafana's \"prometheus\" datasource (/prometheus). null until mimir_s3 is set."
  value       = module.monitoring.mimir_url
}

output "mimir_urls" {
  description = "Each Mimir on its metrics VM's backend-VLAN address (ring pages, debugging; use mimir_url)."
  value       = { for name, n in local.metrics_nic : name => "http://${try(n.backend.address, "0.0.0.0")}:8080" }
}
