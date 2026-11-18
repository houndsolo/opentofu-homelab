# Grafana Alloy on every service VM this root configures (local.alloy_vms): the journal (every
# Quadlet container included) to Loki with the same labels as monitoring-config's VMs
# (source="journal", host, unit, container, app, level). It replaced the rsyslog forwarder
# (source="syslog", retired on every VM by 2026-11-14). Alloy's HTTP listener (/metrics,
# /-/ready) is on the telemetry address (telemetry.tf scrape_ip), where monitoring-config's alloy job scrapes it
# (targets.alloy there; keep the port in step). The DNS VMs get it from terraform_data.dns_alloy
# below, the others from their <role>-monitoring.tf deployment, so changing it never restarts a service.
variable "alloy" {
  description = "Grafana Alloy (journal -> Loki) on every service VM this root configures, pushing to loki_url (Loki's telemetry VIP) from the VM's lylat-telemetry NIC. null = don't install it."
  type = object({
    port     = optional(number, 12345)                      # keep in step with modules/services/monitoring logging.tf
    loki_url = optional(string, "http://10.55.18.101:3100") # Loki's telemetry VIP (monitoring-config logging_settings.vips.telemetry)
    max_age  = optional(string, "12h")                      # journal backlog read after an outage, as on monitoring-config's VMs
  })
  default = {}
  validation {
    condition     = var.alloy == null || try(can(regex("^https?://[A-Za-z0-9.:-]+$", var.alloy.loki_url)), false)
    error_message = "alloy.loki_url is a base URL (http://host:port, no path)."
  }
}

# Every Alloy VM pushes from its telemetry NIC; without one it has no route to the VIP (lylat-telemetry is isolated).
check "alloy_telemetry_nic" {
  assert {
    condition     = var.alloy == null || alltrue([for name in keys(local.alloy_vms) : local.telemetry_ip[name] != null])
    error_message = "Every Alloy VM needs a NIC on VLAN ${var.telemetry_vlan_id} (lylat-telemetry): ${join(", ", [for name in keys(local.alloy_vms) : name if local.telemetry_ip[name] == null])}."
  }
}

locals {
  alloy_vms = merge(local.dns_vms, local.netbox_vms, local.nextcloud_vms, local.radius_vms, local.proxy_vms, local.valkey_vms, local.ticketing_vms, local.gitea_vms, local.arr_vms, local.openbao_vms)

  # VM name => Alloy's part of a deployment (modules/services/quadlet-deploy inputs); empty when var.alloy is
  # null. The config is validated in a throwaway container; a config change reloads Alloy (ExecReload, SIGHUP),
  # a unit change restarts it. The image has no curl/wget, so readiness is checked from the host (verify).
  alloy_parts = {
    for name, vm in(var.alloy == null ? {} : local.alloy_vms) : name => {
      units  = ["alloy"]
      images = [local.container_images.alloy]
      dirs   = [{ path = "/var/lib/alloy", mode = "0750" }]
      files = [
        { path = "/etc/containers/systemd/alloy.container", units = ["alloy"], content = templatefile("${path.module}/templates/alloy.container.tftpl", {
          image  = local.container_images.alloy
          listen = "${local.scrape_ip[name]}:${var.alloy.port}"
        }) },
        { path = "/etc/alloy/config.alloy", units = ["alloy"], content = templatefile("${path.module}/templates/alloy.config.alloy.tftpl", {
          host      = name
          max_age   = var.alloy.max_age
          loki_urls = [var.alloy.loki_url]
        }) },
      ]
      checks = ["podman run --rm --network=none --user 0 -v \"$stage/etc/alloy:/etc/alloy:ro\" '${local.container_images.alloy}' validate /etc/alloy/config.alloy"]
      verify = ["retry curl -fsS -o /dev/null --max-time 3 'http://${local.scrape_ip[name]}:${var.alloy.port}/-/ready'"]
    }
  }
  dns_alloy_parts = { for name, p in local.alloy_parts : name => p if contains(keys(local.dns_vms), name) }
}

module "dns_alloy" {
  source   = "../../modules/services/quadlet-deploy"
  for_each = local.dns_alloy_parts

  name   = "dns-alloy"
  host   = each.key
  files  = each.value.files
  units  = each.value.units
  images = each.value.images
  dirs   = each.value.dirs
  checks = each.value.checks
  verify = each.value.verify
}

resource "terraform_data" "dns_alloy" {
  for_each = local.dns_alloy_parts

  triggers_replace = [
    sha256(module.dns_alloy[each.key].script),
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
    inline = ["install -d -m 0700 /tmp/tofu-alloy-${self.id}"]
  }

  provisioner "file" {
    content     = module.dns_alloy[each.key].script
    destination = "/tmp/tofu-alloy-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-alloy-${self.id}/alloy.sh || rc=$?; rm -rf /tmp/tofu-alloy-${self.id}; exit $rc",
    ]
  }
}
