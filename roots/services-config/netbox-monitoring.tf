# Host monitoring for the NetBox VMs (netbox.tf), like the DNS and Valkey VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) on the telemetry address :9100, where monitoring-config's
# node job scrapes it, and Grafana Alloy (alloy.tf: the journal, NetBox's container logs
# included, to Loki's telemetry VIP). NetBox's own /metrics is scraped on each
# node's lylat-app address (monitoring-config job netbox). Separate from terraform_data.netbox, so
# changing it never restarts NetBox.
variable "netbox_monitoring" {
  description = "node_exporter and Alloy (journal to Loki, alloy.tf) on the role = \"netbox\" VMs. null = don't install them."
  type = object({
    node_exporter_image = optional(string, "docker.io/prom/node-exporter:v1.12.1") # keep in step with monitoring-config images.node_exporter
  })
  default = {}
}

locals {
  netbox_monitoring_scripts = var.netbox_monitoring == null ? {} : {
    for name, vm in local.netbox_vms : name => {
      node_exporter = templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
          image  = var.netbox_monitoring.node_exporter_image
          listen = "${local.scrape_ip[name]}:9100"
        }))
        listen = "${local.scrape_ip[name]}:9100"
      })
      alloy = lookup(local.alloy_scripts, name, null)
    }
  }
}

resource "terraform_data" "netbox_monitoring" {
  for_each = local.netbox_monitoring_scripts

  triggers_replace = [
    sha256(jsonencode(each.value)),
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
    content     = each.value.node_exporter
    destination = "/tmp/tofu-netbox-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.alloy, "#!/bin/bash\n# alloy = null: no journal shipping\n")
    destination = "/tmp/tofu-netbox-mon-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-netbox-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/alloy.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
