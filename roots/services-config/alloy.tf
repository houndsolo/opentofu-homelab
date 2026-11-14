# Grafana Alloy on the service VMs (DNS, NetBox, proxy, Valkey, ticketing): the journal (every
# Quadlet container included) to Loki with the same labels as monitoring-config's VMs
# (source="journal", host, unit, container, app, level). It replaced the rsyslog forwarder
# (source="syslog"); alloy.sh retires that on the first run. Alloy's HTTP listener (/metrics,
# /-/ready) is on the telemetry address (telemetry.tf scrape_ip), where monitoring-config's alloy job scrapes it
# (targets.alloy there; keep the port in step). The DNS VMs get it from terraform_data.dns_alloy
# below, the others from their <role>-monitoring.tf resource, so changing it never restarts a service.
variable "alloy" {
  description = "Grafana Alloy (journal -> Loki) on the DNS, NetBox, proxy, Valkey and ticketing VMs, pushing to loki_url (Loki's telemetry VIP) from the VM's lylat-telemetry NIC. null = don't install it (and leave rsyslog alone)."
  type = object({
    image    = optional(string, "docker.io/grafana/alloy:v1.21.3") # keep in step with monitoring-config images.alloy
    port     = optional(number, 12345)                             # keep in step with modules/services/monitoring logging.tf
    loki_url = optional(string, "http://10.55.18.101:3100")        # Loki's telemetry VIP (monitoring-config logging_settings.vips.telemetry)
    max_age  = optional(string, "12h")                             # journal backlog read after an outage, as on monitoring-config's VMs
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
  alloy_vms = merge(local.dns_vms, local.netbox_vms, local.proxy_vms, local.valkey_vms, local.ticketing_vms)

  # VM name => the install script (templates/alloy.sh.tftpl); empty when var.alloy is null.
  alloy_scripts = var.alloy == null ? {} : {
    for name, vm in local.alloy_vms : name => templatefile("${path.module}/templates/alloy.sh.tftpl", {
      image  = var.alloy.image
      listen = "${local.scrape_ip[name]}:${var.alloy.port}"
      unit_b64 = base64encode(templatefile("${path.module}/templates/alloy.container.tftpl", {
        image  = var.alloy.image
        listen = "${local.scrape_ip[name]}:${var.alloy.port}"
      }))
      config_b64 = base64encode(templatefile("${path.module}/templates/alloy.config.alloy.tftpl", {
        host      = name
        max_age   = var.alloy.max_age
        loki_urls = [var.alloy.loki_url]
      }))
    })
  }
}

resource "terraform_data" "dns_alloy" {
  for_each = { for name, script in local.alloy_scripts : name => script if contains(keys(local.dns_vms), name) }

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
    inline = ["install -d -m 0700 /tmp/tofu-alloy-${self.id}"]
  }

  provisioner "file" {
    content     = each.value
    destination = "/tmp/tofu-alloy-${self.id}/alloy.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-alloy-${self.id}/alloy.sh || rc=$?; rm -rf /tmp/tofu-alloy-${self.id}; exit $rc",
    ]
  }
}
