# Minimal Quadlet deploy: one VM (or several identical ones) running Prometheus, Grafana and
# node_exporter. See README.md. Standalone: nothing in the repo loads this directory.

terraform {
  required_version = ">= 1.8"
}

variable "hosts" {
  description = "VMs to deploy to: name => SSH address and user (needs passwordless sudo and podman)."
  type        = map(object({ address = string, user = optional(string, "debian") }))
}

variable "images" {
  description = "Pinned images."
  type        = object({ prometheus = string, grafana = string, node_exporter = string })
}

variable "scrape_targets" {
  description = "Prometheus jobs: job name => [\"host:port\", ...]."
  type        = map(list(string))
  default     = {}
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

locals {
  quadlet_dir = "/etc/containers/systemd"
  conf        = "/etc/monitoring"

  prometheus_yml = yamlencode({
    global = { scrape_interval = "30s" }
    scrape_configs = concat(
      [{ job_name = "prometheus", static_configs = [{ targets = ["localhost:9090"] }] }],
      [for job, targets in var.scrape_targets : { job_name = job, static_configs = [{ targets = targets }] }],
    )
  })

  datasources_yml = yamlencode({
    apiVersion  = 1
    datasources = [{ name = "Prometheus", uid = "prometheus", type = "prometheus", access = "proxy", url = "http://prometheus:9090", isDefault = true }]
  })

  # Every file a VM gets: where, mode, which systemd unit it belongs to, content.
  # A changed Quadlet file restarts its unit; any other changed file reloads it.
  files = [
    { path = "${local.quadlet_dir}/monitoring.network", mode = "0644", unit = "monitoring-network", content = file("${path.module}/quadlets/monitoring.network") },
    { path = "${local.quadlet_dir}/prometheus.container", mode = "0644", unit = "prometheus", content = templatefile("${path.module}/quadlets/prometheus.container.tftpl", { image = var.images.prometheus, retention = "7d" }) },
    { path = "${local.quadlet_dir}/grafana.container", mode = "0644", unit = "grafana", content = templatefile("${path.module}/quadlets/grafana.container.tftpl", { image = var.images.grafana }) },
    { path = "${local.quadlet_dir}/node-exporter.container", mode = "0644", unit = "node-exporter", content = templatefile("${path.module}/quadlets/node-exporter.container.tftpl", { image = var.images.node_exporter }) },
    { path = "${local.conf}/prometheus/prometheus.yml", mode = "0644", unit = "prometheus", content = local.prometheus_yml },
    { path = "${local.conf}/grafana/provisioning/datasources/datasources.yml", mode = "0644", unit = "grafana", content = local.datasources_yml },
    { path = "${local.conf}/grafana.env", mode = "0600", unit = "grafana", content = "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}\n" },
  ]

  deploy_script = {
    for name, host in var.hosts : name => templatefile("${path.module}/deploy.sh.tftpl", {
      host   = name
      files  = local.files
      images = values(var.images)
      # Run against the staging directory ($stage) before anything is installed.
      checks = [
        "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$stage${local.conf}/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check config /etc/prometheus/prometheus.yml",
      ]
      # Start order.
      units = ["monitoring-network", "prometheus", "grafana", "node-exporter"]
    })
  }
}

resource "terraform_data" "deploy" {
  for_each = var.hosts

  # Re-run when the script (so any file or image in it) or the address changes.
  triggers_replace = [sha256(local.deploy_script[each.key]), each.value.address]

  connection {
    type        = "ssh"
    host        = each.value.address
    user        = each.value.user
    private_key = file(pathexpand(var.ssh_private_key_path))
  }

  # The script embeds grafana.env: upload it into a private directory, run it, delete it.
  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/deploy-${self.id}"]
  }
  provisioner "file" {
    content     = local.deploy_script[each.key]
    destination = "/tmp/deploy-${self.id}/deploy.sh"
  }
  provisioner "remote-exec" {
    inline = ["rc=0; sudo -n bash /tmp/deploy-${self.id}/deploy.sh || rc=$?; rm -rf /tmp/deploy-${self.id}; exit $rc"]
  }
}

output "deploy_scripts" {
  description = "The rendered script per VM, for review: tofu output -raw ... or copy to the VM and run with sudo bash."
  value       = local.deploy_script
  sensitive   = true
}
