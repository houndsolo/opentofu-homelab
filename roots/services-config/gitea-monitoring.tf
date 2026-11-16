# Host monitoring for the Gitea VMs (gitea.tf), like the Nextcloud VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, the Gitea container's log included, to Loki's
# telemetry VIP). Gitea itself is probed through the proxy (monitoring-config blackbox_https_targets).
# Separate from terraform_data.gitea, so changing it never restarts Gitea.
variable "gitea_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"gitea\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  gitea_monitoring_parts = {
    for name in(var.gitea_monitoring != null ? keys(local.gitea_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "gitea_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.gitea_monitoring_parts

  name   = "gitea-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "gitea_monitoring" {
  for_each = local.gitea_monitoring_parts

  triggers_replace = [
    sha256(module.gitea_monitoring[each.key].script),
    local.gitea_vms[each.key].management_address,
    local.gitea_vms[each.key].vm_id,
    local.gitea_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.gitea_vms[each.key].management_address)[0]
    user        = local.gitea_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-gitea-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.gitea_monitoring[each.key].script
    destination = "/tmp/tofu-gitea-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-gitea-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-gitea-mon-${self.id}; exit $rc",
    ]
  }
}
