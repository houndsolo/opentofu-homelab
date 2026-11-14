# BIND metrics for dns01/02: BIND's statistics channel (named.conf, 127.0.0.1:8053) read by
# prometheus-community/bind_exporter (Podman Quadlet, host network), listening on the management address
# :9119 where monitoring-config's `bind` job scrapes it (the port is hard-coded there too:
# modules/services/monitoring/bind.tf). Separate from terraform_data.bind9, so changing it never
# restarts BIND. The DNS VMs run no nftables ruleset.
variable "dns_bind_exporter" {
  description = "bind_exporter on each DNS VM (Podman Quadlet, host network, listening on <mgmt address>:9119). null = don't install it."
  type = object({
    image = optional(string, "docker.io/prometheuscommunity/bind-exporter:v0.8.0")
  })
  default = {}
}

locals {
  # named.conf's statistics-channels port (main.tf), loopback only.
  dns_stats_port = 8053

  dns_bind_exporter_script = {
    for name, vm in local.dns_vms : name => templatefile("${path.module}/templates/bind-exporter.sh.tftpl", {
      unit_b64 = base64encode(templatefile("${path.module}/templates/bind-exporter.container.tftpl", {
        image      = var.dns_bind_exporter.image
        stats_port = local.dns_stats_port
        listen     = "${local.scrape_ip[name]}:9119"
      }))
      listen = "${local.scrape_ip[name]}:9119"
    }) if var.dns_bind_exporter != null
  }
}

resource "terraform_data" "dns_bind_exporter" {
  for_each = local.dns_bind_exporter_script
  # The statistics channel comes with the bind9 deploy (a reload); the exporter fails without it.
  depends_on = [terraform_data.bind9]

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
    inline = ["install -d -m 0700 /tmp/tofu-bind-exporter-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-bind-exporter-${self.id}/bind-exporter.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-bind-exporter-${self.id}/bind-exporter.sh || rc=$?; rm -rf /tmp/tofu-bind-exporter-${self.id}; exit $rc",
    ]
  }
}
