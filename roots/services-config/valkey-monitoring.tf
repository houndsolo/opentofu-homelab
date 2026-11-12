# Monitoring for the Valkey trio (valkey.tf), the same way as the DNS VMs: node_exporter
# (dns-node-exporter.tf's Quadlet), two redis_exporter Quadlets (Valkey :9121 with the password,
# Sentinel :9355 without one; both talk to 127.0.0.1), all listening on the management address,
# where monitoring-config scrapes them (jobs node, valkey, valkey-sentinel; keep the ports in
# step with modules/services/monitoring/valkey.tf). The journal goes to Loki with the DNS VMs'
# rsyslog forwarder (dns_syslog's receivers). Separate from terraform_data.valkey, so changing it
# never restarts Valkey or Sentinel.
variable "valkey_monitoring" {
  description = "node_exporter, Valkey/Sentinel exporters and journal-to-Loki on the role = \"valkey\" VMs. null = don't install them."
  type = object({
    node_exporter_image  = optional(string, "docker.io/prom/node-exporter:v1.12.1") # keep in step with monitoring-config images.node_exporter
    redis_exporter_image = optional(string, "docker.io/oliver006/redis_exporter:v1.97.0")
  })
  default = {}
}

locals {
  valkey_monitoring_ports = { node = 9100, valkey = 9121, sentinel = 9355 }

  valkey_monitoring_scripts = local.valkey_enabled && var.valkey_monitoring != null ? {
    for name, vm in local.valkey_vms : name => {
      node_exporter = templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
          image  = var.valkey_monitoring.node_exporter_image
          listen = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.node}"
        }))
        listen = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.node}"
      })
      exporters = templatefile("${path.module}/templates/valkey-exporters.sh.tftpl", {
        env_b64 = base64encode("REDIS_PASSWORD=${random_password.valkey[0].result}\n")
        valkey_unit_b64 = base64encode(templatefile("${path.module}/templates/valkey-exporter.container.tftpl", {
          name        = "valkey-exporter"
          description = "Prometheus exporter for Valkey"
          after       = "valkey-server.service"
          image       = var.valkey_monitoring.redis_exporter_image
          addr        = "redis://127.0.0.1:6379"
          listen      = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.valkey}"
          env_file    = "/etc/valkey-exporter.env"
        }))
        sentinel_unit_b64 = base64encode(templatefile("${path.module}/templates/valkey-exporter.container.tftpl", {
          name        = "sentinel-exporter"
          description = "Prometheus exporter for Valkey Sentinel"
          after       = "valkey-sentinel.service"
          image       = var.valkey_monitoring.redis_exporter_image
          addr        = "redis://127.0.0.1:26379"
          listen      = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.sentinel}"
          env_file    = ""
        }))
        valkey_listen   = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.valkey}"
        sentinel_listen = "${split("/", vm.management_address)[0]}:${local.valkey_monitoring_ports.sentinel}"
      })
      syslog = local.dns_syslog_script
    }
  } : {}
}

resource "terraform_data" "valkey_monitoring" {
  for_each   = local.valkey_monitoring_scripts
  depends_on = [terraform_data.valkey_canary, terraform_data.valkey]

  triggers_replace = [
    sha256(jsonencode(each.value)),
    local.valkey_vms[each.key].management_address,
    local.valkey_vms[each.key].vm_id,
    local.valkey_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.valkey_vms[each.key].management_address)[0]
    user        = local.valkey_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-valkey-mon-${self.id}"]
  }

  provisioner "file" {
    content     = each.value.node_exporter
    destination = "/tmp/tofu-valkey-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = each.value.exporters
    destination = "/tmp/tofu-valkey-mon-${self.id}/exporters.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.syslog, "#!/bin/bash\n# dns_syslog = null: no journal forwarding\n")
    destination = "/tmp/tofu-valkey-mon-${self.id}/rsyslog-loki.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-valkey-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/exporters.sh && sudo -n bash $d/rsyslog-loki.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
