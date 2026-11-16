# Host monitoring for the dark-triage VMs (ticketing.tf), like the NetBox VMs: node_exporter
# (dns-node-exporter.tf's Quadlet; address-info shows which VM holds the VIP 10.52.13.105) on the
# telemetry address :9100 (telemetry.tf scrape_ip), where monitoring-config's node job scrapes it (role "ticketing"), and
# Grafana Alloy (alloy.tf: the journal, the app's container logs included, to Loki's telemetry VIP).
# Separate from terraform_data.ticketing, so changing it never restarts the app.
variable "ticketing_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"ticketing\" VMs. null = don't install them."
  type = object({
  })
  default = {}
}

locals {
  # The deployment's parts (node_exporter, Alloy), one module call per VM.
  ticketing_monitoring_parts = {
    for name in(var.ticketing != null && var.ticketing_monitoring != null ? keys(local.ticketing_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "ticketing_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.ticketing_monitoring_parts

  name   = "ticketing-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "ticketing_monitoring" {
  for_each   = local.ticketing_monitoring_parts
  depends_on = [terraform_data.ticketing_canary, terraform_data.ticketing]

  triggers_replace = [
    sha256(module.ticketing_monitoring[each.key].script),
    local.ticketing_vms[each.key].management_address,
    local.ticketing_vms[each.key].vm_id,
    local.ticketing_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.ticketing_vms[each.key].management_address)[0]
    user        = local.ticketing_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-ticketing-mon-${self.id}"]
  }

  provisioner "file" {
    content     = module.ticketing_monitoring[each.key].script
    destination = "/tmp/tofu-ticketing-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-ticketing-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-ticketing-mon-${self.id}; exit $rc",
    ]
  }
}
