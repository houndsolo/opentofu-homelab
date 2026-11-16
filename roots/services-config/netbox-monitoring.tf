# Host monitoring for the NetBox VMs (netbox.tf), like the DNS and Valkey VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's
# node job scrapes it, and Grafana Alloy (alloy.tf: the journal, NetBox's container logs
# included, to Loki's telemetry VIP). NetBox's own /metrics is scraped on each
# node's lylat-app address (monitoring-config job netbox). Separate from terraform_data.netbox, so
# changing it never restarts NetBox.
variable "netbox_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"netbox\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  netbox_monitoring_parts = {
    for name in(var.netbox_monitoring != null ? keys(local.netbox_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "netbox_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.netbox_monitoring_parts

  name   = "netbox-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "netbox_monitoring" {
  for_each = local.netbox_monitoring_parts

  triggers_replace = [
    sha256(module.netbox_monitoring[each.key].script),
    local.netbox_vms[each.key].management_address,
    local.netbox_vms[each.key].vm_id,
    local.netbox_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.netbox_vms[each.key].management_address)[0]
    user        = local.netbox_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-netbox-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.netbox_monitoring[each.key].script
    destination = "/tmp/tofu-netbox-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-netbox-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-netbox-mon-${self.id}; exit $rc",
    ]
  }
}
