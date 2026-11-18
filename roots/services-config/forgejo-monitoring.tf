# Host monitoring for the Forgejo VMs (forgejo.tf), like the Nextcloud VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, the Forgejo container's log included, to Loki's
# telemetry VIP). Forgejo itself is probed through the proxy (monitoring-config blackbox_https_targets).
# Separate from terraform_data.forgejo, so changing it never restarts Forgejo.
variable "forgejo_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"forgejo\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  forgejo_monitoring_parts = {
    for name in(var.forgejo_monitoring != null ? keys(local.forgejo_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "forgejo_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.forgejo_monitoring_parts

  name   = "forgejo-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "forgejo_monitoring" {
  for_each = local.forgejo_monitoring_parts

  triggers_replace = [
    sha256(module.forgejo_monitoring[each.key].script),
    local.forgejo_vms[each.key].management_address,
    local.forgejo_vms[each.key].vm_id,
    local.forgejo_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.forgejo_vms[each.key].management_address)[0]
    user        = local.forgejo_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-forgejo-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.forgejo_monitoring[each.key].script
    destination = "/tmp/tofu-forgejo-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-forgejo-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-forgejo-mon-${self.id}; exit $rc",
    ]
  }
}
