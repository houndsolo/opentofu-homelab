# Host monitoring for the OpenBao VMs (openbao.tf), like the Forgejo VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, the OpenBao container's log (incl. the audit log) included, to Loki's
# telemetry VIP). OpenBao itself is probed through the proxy (monitoring-config blackbox_https_targets).
# Separate from terraform_data.openbao, so changing it never restarts OpenBao.
variable "openbao_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"bao\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  openbao_monitoring_parts = {
    for name in(var.openbao_monitoring != null ? keys(local.openbao_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "openbao_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.openbao_monitoring_parts

  name   = "openbao-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "openbao_monitoring" {
  for_each = local.openbao_monitoring_parts

  triggers_replace = [
    sha256(module.openbao_monitoring[each.key].script),
    local.openbao_vms[each.key].management_address,
    local.openbao_vms[each.key].vm_id,
    local.openbao_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.openbao_vms[each.key].management_address)[0]
    user        = local.openbao_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-openbao-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.openbao_monitoring[each.key].script
    destination = "/tmp/tofu-openbao-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-openbao-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-openbao-mon-${self.id}; exit $rc",
    ]
  }
}
