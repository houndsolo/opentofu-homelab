# Minimal Quadlet deploy with the repo's per-VM split: a "prometheus" VM and a "grafana" VM (any number
# of each), node_exporter on all of them. See README.md. Standalone: nothing in the repo loads this directory.

terraform {
  required_version = ">= 1.8"
}

variable "hosts" {
  description = "VMs to deploy to: name => role, SSH address and user (needs passwordless sudo and podman)."
  type = map(object({
    role    = string # "prometheus" or "grafana"
    address = string
    user    = optional(string, "debian")
  }))
  validation {
    condition     = alltrue([for h in values(var.hosts) : contains(["prometheus", "grafana"], h.role)])
    error_message = "role must be \"prometheus\" or \"grafana\"."
  }
}

variable "images" {
  description = "Pinned images."
  type        = object({ prometheus = string, grafana = string, node_exporter = string })
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

  prometheus_hosts = sort([for name, h in var.hosts : name if h.role == "prometheus"])

  # Scrape targets come from the host list, like the live root derives them from the inventory.
  prometheus_yml = yamlencode({
    global = { scrape_interval = "30s" }
    scrape_configs = [
      { job_name = "prometheus", static_configs = [for name in local.prometheus_hosts : { targets = ["${var.hosts[name].address}:9090"], labels = { host = name } }] },
      { job_name = "node", static_configs = [for name, h in var.hosts : { targets = ["${h.address}:9100"], labels = { host = name } }] },
    ]
  })

  # Grafana reaches Prometheus over the network (another VM): one datasource per Prometheus VM.
  datasources_yml = yamlencode({
    apiVersion = 1
    datasources = [for i, name in local.prometheus_hosts : {
      name      = "Prometheus ${name}"
      uid       = "prometheus-${name}"
      type      = "prometheus"
      access    = "proxy"
      url       = "http://${var.hosts[name].address}:9090"
      isDefault = i == 0
    }]
  })

  # What a VM of each role gets. Per file: where, mode, which systemd unit it belongs to, content.
  # A changed Quadlet file restarts its unit; any other changed file reloads it.
  role = {
    prometheus = {
      units  = ["prometheus"]
      images = [var.images.prometheus]
      files = [
        { path = "${local.quadlet_dir}/prometheus.container", mode = "0644", unit = "prometheus", content = templatefile("${path.module}/quadlets/prometheus.container.tftpl", { image = var.images.prometheus, retention = "7d" }) },
        { path = "/etc/prometheus/prometheus.yml", mode = "0644", unit = "prometheus", content = local.prometheus_yml },
      ]
      # Run against the staging directory ($stage) before anything is installed.
      checks = [
        "podman run --rm --network=none --user 0 --entrypoint promtool -v \"$stage/etc/prometheus:/etc/prometheus:ro\" '${var.images.prometheus}' check config /etc/prometheus/prometheus.yml",
      ]
    }
    grafana = {
      units  = ["grafana"]
      images = [var.images.grafana]
      files = [
        { path = "${local.quadlet_dir}/grafana.container", mode = "0644", unit = "grafana", content = templatefile("${path.module}/quadlets/grafana.container.tftpl", { image = var.images.grafana }) },
        { path = "/etc/grafana/provisioning/datasources/datasources.yml", mode = "0644", unit = "grafana", content = local.datasources_yml },
        { path = "/etc/grafana/grafana.env", mode = "0600", unit = "grafana", content = "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}\n" },
      ]
      checks = []
    }
  }

  # On every VM, whatever its role.
  common = {
    units  = ["node-exporter"]
    images = [var.images.node_exporter]
    files = [
      { path = "${local.quadlet_dir}/node-exporter.container", mode = "0644", unit = "node-exporter", content = templatefile("${path.module}/quadlets/node-exporter.container.tftpl", { image = var.images.node_exporter }) },
    ]
  }

  # One script per VM: its role's files plus the common ones.
  deploy_script = {
    for name, host in var.hosts : name => templatefile("${path.module}/deploy.sh.tftpl", {
      host   = name
      files  = concat(local.role[host.role].files, local.common.files)
      images = concat(local.role[host.role].images, local.common.images)
      checks = local.role[host.role].checks
      units  = concat(local.role[host.role].units, local.common.units) # start order
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

  # The script can embed secrets (grafana.env): upload it into a private directory, run it, delete it.
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
  description = "The rendered script per VM, for review."
  value       = local.deploy_script
  sensitive   = true
}
