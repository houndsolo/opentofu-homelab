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
  nextcloud_monitoring_scripts = var.nextcloud_monitoring == null ? {} : {
    for name, vm in local.nextcloud_vms : name => {
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

resource "terraform_data" "nextcloud_monitoring" {
  for_each = local.nextcloud_monitoring_scripts

  triggers_replace = [
    sha256(jsonencode(each.value)),
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
    content     = each.value.node_exporter
    destination = "/tmp/tofu-nextcloud-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.alloy, "#!/bin/bash\n# alloy = null: no journal shipping\n")
    destination = "/tmp/tofu-nextcloud-mon-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-nextcloud-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/alloy.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
