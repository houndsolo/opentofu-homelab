# Host monitoring for the dark-triage VMs (ticketing.tf), like the NetBox VMs: node_exporter
# (dns-node-exporter.tf's Quadlet; address-info shows which VM holds the VIP 10.52.13.105) on the
# telemetry address :9100 (telemetry.tf scrape_ip), where monitoring-config's node job scrapes it (role "ticketing"), and
# Grafana Alloy (alloy.tf: the journal, the app's container logs included, to Loki's telemetry VIP).
# Separate from terraform_data.ticketing, so changing it never restarts the app.
variable "ticketing_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"ticketing\" VMs. null = don't install them."
  type = object({
    node_exporter_image = optional(string, "docker.io/prom/node-exporter:v1.12.1") # keep in step with monitoring-config images.node_exporter
  })
  default = {}
}

locals {
  ticketing_monitoring_scripts = var.ticketing != null && var.ticketing_monitoring != null ? {
    for name, vm in local.ticketing_vms : name => {
      node_exporter = templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
          image  = var.ticketing_monitoring.node_exporter_image
          listen = "${local.scrape_ip[name]}:9100"
        }))
        listen = "${local.scrape_ip[name]}:9100"
      })
      alloy = lookup(local.alloy_scripts, name, null)
    }
  } : {}
}

resource "terraform_data" "ticketing_monitoring" {
  for_each   = local.ticketing_monitoring_scripts
  depends_on = [terraform_data.ticketing_canary, terraform_data.ticketing]

  triggers_replace = [
    sha256(jsonencode(each.value)),
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
    content     = each.value.node_exporter
    destination = "/tmp/tofu-ticketing-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.alloy, "#!/bin/bash\n# alloy = null: no journal shipping\n")
    destination = "/tmp/tofu-ticketing-mon-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-ticketing-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/alloy.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
