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
  radius_monitoring_scripts = var.radius_monitoring == null ? {} : {
    for name, vm in local.radius_vms : name => {
      node_exporter = templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
          image  = local.container_images.node_exporter
          listen = "${local.scrape_ip[name]}:9100"
        }))
        listen = "${local.scrape_ip[name]}:9100"
      })
      alloy = lookup(local.alloy_scripts, name, null)
    }
  }
}

resource "terraform_data" "radius_monitoring" {
  for_each = local.radius_monitoring_scripts

  triggers_replace = [
    sha256(jsonencode(each.value)),
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
    content     = each.value.node_exporter
    destination = "/tmp/tofu-radius-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.alloy, "#!/bin/bash\n# alloy = null: no journal shipping\n")
    destination = "/tmp/tofu-radius-mon-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-radius-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/alloy.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
