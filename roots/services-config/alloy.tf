# Grafana Alloy on the service VMs (DNS, NetBox, proxy, Valkey, ticketing): the journal (every
# Quadlet container included) to Loki with the same labels as monitoring-config's VMs
# (source="journal", host, unit, container, app, level). It replaced the rsyslog forwarder
# (source="syslog"); alloy.sh retires that on the first run. Alloy's HTTP listener (/metrics,
# /-/ready) is on the management address, where monitoring-config's alloy job scrapes it
# (targets.alloy there; keep the port in step). The DNS VMs get it from terraform_data.dns_alloy
# below, the others from their <role>-monitoring.tf resource, so changing it never restarts a service.
variable "alloy" {
  description = "Grafana Alloy (journal -> Loki) on the DNS, NetBox, proxy, Valkey and ticketing VMs. VMs with a NIC on backend_vlan_id push to loki_vip_url, the others to every loki_mgmt_urls entry. null = don't install it (and leave rsyslog alone)."
  type = object({
    image           = optional(string, "docker.io/grafana/alloy:v1.21.3") # keep in step with monitoring-config images.alloy
    port            = optional(number, 12345)                             # keep in step with modules/services/monitoring logging.tf
    backend_vlan_id = optional(number, 13)
    loki_vip_url    = optional(string, "http://10.13.11.101:3100") # Loki's backend VIP (monitoring-config logging_settings.vips.backend)
    # No Loki VIP on mgmt: every logging VM's own address. monitoring-config lets these VMs through
    # logging-guard (port 3100) by their mgmt address.
    loki_mgmt_urls = optional(list(string), ["http://10.20.11.34:3100", "http://10.20.11.35:3100", "http://10.20.11.36:3100"])
    max_age        = optional(string, "12h") # journal backlog read after an outage, as on monitoring-config's VMs
  })
  default = {}
  validation {
    condition     = var.alloy == null || try(length(var.alloy.loki_mgmt_urls) > 0 && alltrue([for u in concat([var.alloy.loki_vip_url], var.alloy.loki_mgmt_urls) : can(regex("^https?://[A-Za-z0-9.:-]+$", u))]), false)
    error_message = "alloy.loki_vip_url and loki_mgmt_urls are base URLs (http://host:port, no path), loki_mgmt_urls not empty."
  }
}

locals {
  alloy_vms = merge(local.dns_vms, local.netbox_vms, local.proxy_vms, local.valkey_vms, local.ticketing_vms)

  # VM name => the install script (templates/alloy.sh.tftpl); empty when var.alloy is null.
  alloy_scripts = var.alloy == null ? {} : {
    for name, vm in local.alloy_vms : name => templatefile("${path.module}/templates/alloy.sh.tftpl", {
      image  = var.alloy.image
      listen = "${split("/", vm.management_address)[0]}:${var.alloy.port}"
      unit_b64 = base64encode(templatefile("${path.module}/templates/alloy.container.tftpl", {
        image  = var.alloy.image
        listen = "${split("/", vm.management_address)[0]}:${var.alloy.port}"
      }))
      config_b64 = base64encode(templatefile("${path.module}/templates/alloy.config.alloy.tftpl", {
        host    = name
        max_age = var.alloy.max_age
        loki_urls = anytrue([
          for nic in(vm.network_devices == null ? [] : vm.network_devices) : nic.vlan_id == var.alloy.backend_vlan_id && nic.ipv4_address != null
        ]) ? [var.alloy.loki_vip_url] : var.alloy.loki_mgmt_urls
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
