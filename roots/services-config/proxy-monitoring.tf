# Monitoring for the reverse proxy pair (proxy.tf), the same way as the Valkey VMs: node_exporter
# (dns-node-exporter.tf's Quadlet) and nginx-prometheus-exporter (reads nginx's stub_status on
# http://127.0.0.1/nginx_status, which only answers localhost), both on the telemetry address where
# monitoring-config scrapes them (jobs node and nginx; keep the ports in step with
# modules/services/monitoring/nginx.tf). Grafana Alloy (alloy.tf) ships the journal to Loki, nginx's
# access and error log included (app="nginx", the nginx dashboard reads it there).
# Separate from terraform_data.proxy, so changing it never touches nginx.
variable "proxy_monitoring" {
  description = "node_exporter, nginx-prometheus-exporter and Alloy (journal to Loki, alloy.tf) on the role = \"proxy\" VMs. null = don't install them."
  type = object({
    node_exporter_image  = optional(string, "docker.io/prom/node-exporter:v1.12.1") # keep in step with monitoring-config images.node_exporter
    nginx_exporter_image = optional(string, "docker.io/nginx/nginx-prometheus-exporter:1.5.3")
  })
  default = {}
}

locals {
  proxy_monitoring_ports = { node = 9100, nginx = 9113 }

  proxy_monitoring_scripts = var.proxy != null && var.proxy_monitoring != null ? {
    for name, vm in local.proxy_vms : name => {
      node_exporter = templatefile("${path.module}/templates/node-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/node-exporter.container.tftpl", {
          image  = var.proxy_monitoring.node_exporter_image
          listen = "${local.scrape_ip[name]}:${local.proxy_monitoring_ports.node}"
        }))
        listen = "${local.scrape_ip[name]}:${local.proxy_monitoring_ports.node}"
      })
      exporter = templatefile("${path.module}/templates/nginx-exporter.sh.tftpl", {
        unit_b64 = base64encode(templatefile("${path.module}/templates/nginx-exporter.container.tftpl", {
          image  = var.proxy_monitoring.nginx_exporter_image
          listen = "${local.scrape_ip[name]}:${local.proxy_monitoring_ports.nginx}"
        }))
        listen = "${local.scrape_ip[name]}:${local.proxy_monitoring_ports.nginx}"
      })
      alloy = lookup(local.alloy_scripts, name, null)
    }
  } : {}
}

resource "terraform_data" "proxy_monitoring" {
  for_each   = local.proxy_monitoring_scripts
  depends_on = [terraform_data.proxy_canary, terraform_data.proxy]

  triggers_replace = [
    sha256(jsonencode(each.value)),
    local.proxy_vms[each.key].management_address,
    local.proxy_vms[each.key].vm_id,
    local.proxy_vms[each.key].config.ssh_username,
  ]

  connection {
    type        = "ssh"
    host        = split("/", local.proxy_vms[each.key].management_address)[0]
    user        = local.proxy_vms[each.key].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-proxy-mon-${self.id}"]
  }

  provisioner "file" {
    content     = each.value.node_exporter
    destination = "/tmp/tofu-proxy-mon-${self.id}/node-exporter.sh"
  }

  provisioner "file" {
    content     = each.value.exporter
    destination = "/tmp/tofu-proxy-mon-${self.id}/nginx-exporter.sh"
  }

  provisioner "file" {
    content     = coalesce(each.value.alloy, "#!/bin/bash\n# alloy = null: no journal shipping\n")
    destination = "/tmp/tofu-proxy-mon-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; d=/tmp/tofu-proxy-mon-${self.id}; sudo -n bash $d/node-exporter.sh && sudo -n bash $d/nginx-exporter.sh && sudo -n bash $d/alloy.sh || rc=$?; rm -rf $d; exit $rc",
    ]
  }
}
