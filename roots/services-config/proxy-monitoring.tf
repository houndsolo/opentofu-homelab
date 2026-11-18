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
  })
  default = {}
}

locals {
  proxy_monitoring_ports = { nginx = 9113 }

  # nginx-prometheus-exporter: its image has no shell, so the deploy checks it from the host (nginx_up 1).
  nginx_exporter_parts = {
    for name, vm in(var.proxy == null ? {} : local.proxy_vms) : name => {
      units  = ["nginx-exporter"]
      images = [local.container_images.nginx_exporter]
      dirs   = []
      files = [{ path = "/etc/containers/systemd/nginx-exporter.container", units = ["nginx-exporter"], content = templatefile("${path.module}/templates/nginx-exporter.container.tftpl", {
        image  = local.container_images.nginx_exporter
        listen = "${local.scrape_ip[name]}:${local.proxy_monitoring_ports.nginx}"
      }) }]
      checks = []
      verify = ["retry sh -c \"curl -fsS --max-time 3 'http://${local.scrape_ip[name]}:${local.proxy_monitoring_ports.nginx}/metrics' | grep -qx 'nginx_up 1'\""]
    }
  }

  # The deployment's parts (node_exporter, the role's exporters, Alloy), one module call per VM.
  proxy_monitoring_parts = {
    for name in(var.proxy != null && var.proxy_monitoring != null ? keys(local.proxy_vms) : []) : name => [
      for p in [local.node_exporter_parts[name], local.nginx_exporter_parts[name], lookup(local.alloy_parts, name, null)] : p if p != null
    ]
  }
}

module "proxy_monitoring" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.proxy_monitoring_parts

  name   = "proxy-monitoring"
  host   = each.key
  files  = flatten([for p in each.value : p.files])
  units  = flatten([for p in each.value : p.units])
  images = flatten([for p in each.value : p.images])
  dirs   = flatten([for p in each.value : p.dirs])
  checks = flatten([for p in each.value : p.checks])
  verify = flatten([for p in each.value : p.verify])
}

resource "terraform_data" "proxy_monitoring" {
  for_each   = local.proxy_monitoring_parts
  depends_on = [terraform_data.proxy_canary, terraform_data.proxy]

  triggers_replace = [
    sha256(module.proxy_monitoring[each.key].script),
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
    content     = module.proxy_monitoring[each.key].script
    destination = "/tmp/tofu-proxy-mon-${self.id}/deploy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-proxy-mon-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/tofu-proxy-mon-${self.id}; exit $rc",
    ]
  }
}
