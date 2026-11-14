# Prometheus node exporter on the DNS VMs (Quadlet, like the monitoring VMs), listening on the
# management address :9100, where monitoring-config's `node` job scrapes service VMs. Separate from
# terraform_data.bind9, so changing it never restarts BIND. The DNS VMs run no nftables ruleset.
variable "dns_node_exporter" {
  description = "node_exporter on each DNS VM (Podman Quadlet, host network, listening on <mgmt address>:<port>). null = don't install it."
  type = object({
    image = optional(string, "docker.io/prom/node-exporter:v1.12.1") # keep in step with monitoring-config images.node_exporter
    port  = optional(number, 9100)
  })
  default = {}
}

locals {
  dns_node_exporter_script = {
    for name, vm in local.dns_vms : name => templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
      unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image  = var.dns_node_exporter.image
        listen = "${local.scrape_ip[name]}:${var.dns_node_exporter.port}"
      }))
      listen = "${local.scrape_ip[name]}:${var.dns_node_exporter.port}"
    }) if var.dns_node_exporter != null
  }
}

resource "terraform_data" "dns_node_exporter" {
  for_each = local.dns_node_exporter_script

  triggers_replace = [
    sha256(each.value),
    local.dns_vms[each.key].management_address,
    local.dns_vms[each.key].vm_id,
    local.dns_vms[each.key].config.ssh_username,
    var.dns_deploy_revision,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.dns_vms[each.key].management_address)[0]
    user        = local.dns_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-node-exporter-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-node-exporter-${self.id}/node-exporter.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-node-exporter-${self.id}/node-exporter.sh || rc=$?; rm -rf /tmp/tofu-node-exporter-${self.id}; exit $rc",
    ]
  }
}
