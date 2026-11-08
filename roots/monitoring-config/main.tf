module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  service_vms    = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" }
  monitoring_vms = { for name, vm in local.service_vms : name => vm if vm.role == "monitoring" }
  grafana_vms    = { for name, vm in local.service_vms : name => vm if vm.role == "grafana" }
  dns_vms        = { for name, vm in local.service_vms : name => vm if vm.role == "dns" }
  dhcp_vms       = { for name, vm in local.service_vms : name => vm if vm.role == "dhcp" }
  deploy_vms     = merge(local.monitoring_vms, local.grafana_vms)

  nics = { for name, vm in local.service_vms : name => vm.network_devices == null ? [] : vm.network_devices }
  mgmt = { for name, vm in local.service_vms : name => try(split("/", vm.management_address)[0], null) }

  # Address on the isolated backend VLAN, and the backend VM's monitoring-network address.
  backend_address = {
    for name in keys(local.deploy_vms) : name => try(split("/", one([
      for nic in local.nics[name] : nic.ipv4_address if nic.vlan_id == var.backend_vlan_id && nic.ipv4_address != null
    ]))[0], null)
  }
  monitoring_address = {
    for name in keys(local.monitoring_vms) : name => try(split("/", one([
      for nic in local.nics[name] : nic.ipv4_address if nic.bridge == var.monitoring_bridge && nic.ipv4_address != null
    ]))[0], null)
  }

  backend_name = try(one(keys(local.monitoring_vms)), null)

  pve_prefix = try(var.pve_network.bridges[var.pve_monitoring_bridge].ipv4.cidrhost_prefix, null)
  # Cluster nodes only: the standalone host would need its own API token.
  pve_nodes = {
    for name, node in var.nodes.proxmox : name => cidrhost(local.pve_prefix, node.id)
    if local.pve_prefix != null
  }

  targets = {
    node = concat(
      [for name in keys(local.monitoring_vms) : { host = name, address = coalesce(local.monitoring_address[name], "0.0.0.0"), labels = { role = "monitoring" } }],
      [for name in keys(local.grafana_vms) : { host = name, address = coalesce(local.backend_address[name], "0.0.0.0"), labels = { role = "grafana" } }],
      [for name in keys(local.dns_vms) : { host = name, address = local.mgmt[name], labels = { role = "dns" } }],
      [for name, address in local.pve_nodes : { host = name, address = address, labels = { role = "proxmox" } }],
      [for host, address in var.node_extra_targets : { host = host, address = address, labels = {} }],
    )
    vyos = concat(
      [for name, leaf in module.leaves.leaves : {
        host = "leaf-${leaf.id}", address = cidrhost(var.fabric.settings.management_prefix, leaf.id), labels = { role = "leaf" }
      }],
      [for name in keys(local.dhcp_vms) : { host = name, address = local.mgmt[name], labels = { role = "dhcp" } }],
      [for host, address in var.vyos_extra_targets : { host = host, address = address, labels = { role = "router" } }],
    )
    pve     = [for name, address in local.pve_nodes : { host = name, address = address } if !var.nodes.proxmox[name].standalone]
    grafana = [for name in keys(local.grafana_vms) : { host = name, address = coalesce(local.backend_address[name], "0.0.0.0") }]
    snmp    = var.snmp_targets
    blackbox = {
      icmp     = [for host, address in var.blackbox_icmp_targets : { host = host, target = address }]
      http_2xx = [for host, url in var.blackbox_http_targets : { host = host, target = url }]
      dns_soa = [
        for name in keys(local.dns_vms) : {
          host = name
          target = split("/", one([
            for nic in local.nics[name] : nic.ipv4_address if nic.ipv4_address != null
          ]))[0]
        }
      ]
    }
  }
}

resource "random_password" "influxdb_admin" {
  length  = 32
  special = false
}

resource "random_password" "influxdb_token" {
  length  = 48
  special = false
}

resource "random_password" "grafana_db" {
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "random_password" "grafana_secret_key" {
  length  = 40
  special = false
}

module "monitoring" {
  source = "../../modules/services/monitoring"

  backend = {
    name               = coalesce(local.backend_name, "missing")
    monitoring_address = coalesce(try(local.monitoring_address[local.backend_name], null), "0.0.0.0")
    backend_address    = coalesce(try(local.backend_address[local.backend_name], null), "0.0.0.0")
  }
  grafana = {
    for name in keys(local.grafana_vms) : name => { backend_address = coalesce(local.backend_address[name], "0.0.0.0") }
  }
  images   = var.images
  targets  = local.targets
  settings = var.settings
  secrets = {
    influxdb_admin_password = coalesce(var.influxdb_admin_password, random_password.influxdb_admin.result)
    influxdb_admin_token    = random_password.influxdb_token.result
    grafana_db_password     = random_password.grafana_db.result
    grafana_admin_password  = coalesce(var.grafana_admin_password, random_password.grafana_admin.result)
    grafana_secret_key      = random_password.grafana_secret_key.result
  }
  pve_exporter_token = var.pve_exporter_token
}

resource "terraform_data" "backend" {
  for_each = local.monitoring_vms

  triggers_replace = [
    sha256(module.monitoring.backend_deployment),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = length(local.monitoring_vms) == 1
      error_message = "Define exactly one services-vms VM with role = \"monitoring\"."
    }
    precondition {
      condition     = local.backend_address[each.key] != null && local.monitoring_address[each.key] != null
      error_message = "The monitoring VM needs one addressed NIC on VLAN ${var.backend_vlan_id} and one on ${var.monitoring_bridge}."
    }
    precondition {
      condition     = alltrue([for name in keys(local.grafana_vms) : local.backend_address[name] != null])
      error_message = "Every grafana VM needs one addressed NIC on VLAN ${var.backend_vlan_id}."
    }
    precondition {
      condition     = local.pve_prefix != null
      error_message = "pve_network.bridges[\"${var.pve_monitoring_bridge}\"].ipv4.cidrhost_prefix is not set."
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
    inline = ["install -d -m 0700 /tmp/tofu-monitoring-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.backend_deployment
    destination = "/tmp/tofu-monitoring-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-monitoring-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-monitoring-${self.id}; exit $rc",
    ]
  }
}

resource "terraform_data" "grafana" {
  for_each = local.grafana_vms

  # Grafana needs Postgres and the datasources on the backend.
  depends_on = [terraform_data.backend]

  triggers_replace = [
    sha256(module.monitoring.grafana_deployments[each.key]),
    each.value.management_address,
    each.value.vm_id,
    each.value.config.ssh_username,
    var.deploy_revision,
  ]

  lifecycle {
    precondition {
      condition     = local.backend_address[each.key] != null
      error_message = "${each.key} needs one addressed NIC on VLAN ${var.backend_vlan_id}."
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
    inline = ["install -d -m 0700 /tmp/tofu-grafana-${self.id}"]
  }

  provisioner "file" {
    content     = module.monitoring.grafana_deployments[each.key]
    destination = "/tmp/tofu-grafana-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # One command, so a failed deploy fails the apply (remote-exec reports the last exit status).
      "rc=0; sudo -n bash /tmp/tofu-grafana-${self.id}/deploy.sh deploy || rc=$?; rm -rf /tmp/tofu-grafana-${self.id}; exit $rc",
    ]
  }
}
