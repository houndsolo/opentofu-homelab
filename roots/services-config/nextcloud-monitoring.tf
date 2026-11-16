# Host monitoring for the Nextcloud VMs (nextcloud.tf), like the NetBox VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, the pod's container logs included, to Loki's
# telemetry VIP). Nextcloud itself is probed through the proxy (monitoring-config blackbox_https_targets).
# Separate from terraform_data.nextcloud, so changing it never restarts Nextcloud.
variable "nextcloud_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"nextcloud\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  nextcloud_monitoring_parts = {
    for name in(var.nextcloud_monitoring != null ? keys(local.nextcloud_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "nextcloud_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.nextcloud_monitoring_parts

  name   = "nextcloud-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "nextcloud_monitoring" {
  for_each = local.nextcloud_monitoring_parts

  triggers_replace = [
    sha256(module.nextcloud_monitoring[each.key].script),
    local.nextcloud_vms[each.key].management_address,
    local.nextcloud_vms[each.key].vm_id,
    local.nextcloud_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.nextcloud_vms[each.key].management_address)[0]
    user        = local.nextcloud_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-nextcloud-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.nextcloud_monitoring[each.key].script
    destination = "/tmp/tofu-nextcloud-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-nextcloud-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-nextcloud-mon-${self.id}; exit $rc",
    ]
  }
}
