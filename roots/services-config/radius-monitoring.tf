# Host monitoring for the FreeRADIUS VMs (radius.tf), like the NetBox VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's node job
# scrapes it, and Grafana Alloy (alloy.tf: the journal, FreeRADIUS' own log included, to Loki's telemetry
# VIP). Separate from terraform_data.radius, so changing it never restarts FreeRADIUS.
variable "radius_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"radius\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  radius_monitoring_parts = {
    for name in(var.radius_monitoring != null ? keys(local.radius_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "radius_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.radius_monitoring_parts

  name   = "radius-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "radius_monitoring" {
  for_each = local.radius_monitoring_parts

  triggers_replace = [
    sha256(module.radius_monitoring[each.key].script),
    local.radius_vms[each.key].management_address,
    local.radius_vms[each.key].vm_id,
    local.radius_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.radius_vms[each.key].management_address)[0]
    user        = local.radius_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.radius_monitoring[each.key].script
    destination = "/tmp/tofu-radius-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-radius-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-radius-mon-${self.id}; exit $rc",
    ]
  }
}
