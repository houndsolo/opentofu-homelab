# Host monitoring for the arr VM (arr.tf), like the Gitea VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, the arr pod's container logs included, to Loki's
# telemetry VIP). Jellyfin is probed through the proxy (monitoring-config blackbox_https_targets).
# Separate from terraform_data.arr, so changing it never restarts the apps.
variable "arr_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"arr\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  arr_monitoring_parts = {
    for name in(var.arr_monitoring != null ? keys(local.arr_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "arr_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.arr_monitoring_parts

  name   = "arr-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "arr_monitoring" {
  for_each = local.arr_monitoring_parts

  triggers_replace = [
    sha256(module.arr_monitoring[each.key].script),
    local.arr_vms[each.key].management_address,
    local.arr_vms[each.key].vm_id,
    local.arr_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.arr_vms[each.key].management_address)[0]
    user        = local.arr_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-arr-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.arr_monitoring[each.key].script
    destination = "/tmp/tofu-arr-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-arr-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-arr-mon-${self.id}; exit $rc",
    ]
  }
}
