# BIND metrics for dns01/02: BIND's statistics channel (named.conf, 127.0.0.1:8053) read by
# prometheus-community/bind_exporter (Podman Quadlet, host network), listening on the telemetry address
# :9119 where monitoring-config's `bind` job scrapes it (the port is hard-coded there too:
# modules/services/monitoring/bind.tf). Separate from terraform_data.bind9, so changing it never
# restarts BIND. The DNS VMs run no nftables ruleset.
variable "dns_bind_exporter" {
  description = "bind_exporter on each DNS VM (Podman Quadlet, host network, listening on <telemetry address>:9119). null = don't install it."
  type = object({
  })
  default = {}
}

locals {
  # named.conf's statistics-channels port (main.tf), loopback only.
  dns_stats_port = 8053

  # Health: the unit checks that the exporter answers (HealthCmd); the deploy then waits for bind_up 1, which
  # needs BIND's statistics channel (not a unit health check: it depends on another container).
  dns_bind_exporter_parts = {
    for name, vm in(var.dns_bind_exporter == null ? {} : local.dns_vms) : name => {
      files = [{ path = "/etc/containers/systemd/bind-exporter.container", units = ["bind-exporter"], content = templatefile("${path.module}/templates/bind-exporter.container.tftpl", {
        image      = local.container_images.bind_exporter
        stats_port = local.dns_stats_port
        listen     = "${local.scrape_ip[name]}:9119"
      }) }]
      verify = ["retry sh -c \"curl -fsS --max-time 5 'http://${local.scrape_ip[name]}:9119/metrics' | grep -qx 'bind_up 1'\""]
    }
  }
}

module "dns_bind_exporter" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.dns_bind_exporter_parts

  name   = "dns-bind-exporter"
  host   = each.key
  files  = each.value.files
  units  = ["bind-exporter"]
  images = [local.container_images.bind_exporter]
  verify = each.value.verify
}

resource "terraform_data" "dns_bind_exporter" {
  for_each = local.dns_bind_exporter_parts
  # The statistics channel comes with the bind9 deploy (a reload); the exporter fails without it.
  depends_on = [terraform_data.bind9]

  triggers_replace = [
    sha256(module.dns_bind_exporter[each.key].script),
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
    content     = module.dns_bind_exporter[each.key].script
    destination = "/tmp/tofu-bind-exporter-${self.id}/bind-exporter.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-bind-exporter-${self.id}/bind-exporter.sh || rc=$?; rm -rf /tmp/tofu-bind-exporter-${self.id}; exit $rc",
    ]
  }
}
