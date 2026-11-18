# Prometheus node exporter on the DNS VMs (Quadlet, like the monitoring VMs), listening on the
# telemetry address :9100 (telemetry.tf scrape_ip; mgmt without a telemetry NIC), where monitoring-config's `node` job scrapes service VMs. Separate from
# terraform_data.bind9, so changing it never restarts BIND. node_exporter_parts is
# the same exporter for every service VM's <role>-monitoring deployment. The DNS VMs run no nftables ruleset.
variable "dns_node_exporter" {
  description = "node_exporter on each DNS VM (Podman Quadlet, host network, listening on <telemetry address>:<port>). null = don't install it."
  type = object({
    port = optional(number, 9100)
  })
  default = {}
}

locals {
  # VM name => node_exporter's part of a deployment (modules/services/quadlet-deploy inputs) on every service
  # VM: :9100 on the telemetry address (the DNS VMs: var.dns_node_exporter.port). Health is in the unit
  # (HealthCmd + Notify=healthy), so the restart returns once it answers. Its template
  # (templates/node-exporter.container.tftpl) keeps the collector flags of monitoring-config's VMs, which
  # are in modules/services/monitoring/templates/node-exporter.container.tftpl. (The template's own comment
  # still names main.tf node_exporter_collectors, a local that no longer exists; it renders onto every
  # service VM, so it is corrected with the next exporter redeploy, not now.)
  node_exporter_parts = {
    for name, vm in local.monitored_service_vms : name => {
      units  = ["node-exporter"]
      images = [local.container_images.node_exporter]
      dirs   = []
      files = [{ path = "/etc/containers/systemd/node-exporter.container", units = ["node-exporter"], content = templatefile("${path.module}/templates/node-exporter.container.tftpl", {
        image  = local.container_images.node_exporter
        listen = "${local.scrape_ip[name]}:${contains(keys(local.dns_vms), name) ? try(var.dns_node_exporter.port, 9100) : 9100}"
      }) }]
      checks = []
      verify = []
    }
  }
  dns_node_exporter_parts = var.dns_node_exporter == null ? {} : { for name in keys(local.dns_vms) : name => local.node_exporter_parts[name] }
}

module "dns_node_exporter" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.dns_node_exporter_parts

  name   = "dns-node-exporter"
  host   = each.key
  files  = each.value.files
  units  = each.value.units
  images = each.value.images
}

resource "terraform_data" "dns_node_exporter" {
  for_each = local.dns_node_exporter_parts

  triggers_replace = [
    sha256(module.dns_node_exporter[each.key].script),
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
    content     = module.dns_node_exporter[each.key].script
    destination = "/tmp/tofu-node-exporter-${self.id}/node-exporter.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-node-exporter-${self.id}/node-exporter.sh || rc=$?; rm -rf /tmp/tofu-node-exporter-${self.id}; exit $rc",
    ]
  }
}
