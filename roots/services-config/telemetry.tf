# lylat-telemetry (VLAN telemetry_vlan_id, VNI 5501, flat 10.55.0.0/16; zone design in the Obsidian vault): every
# service VM's scrape and log-push NIC. The exporters here (node_exporter, bind/nginx/valkey exporters, Alloy) listen
# on scrape_ip: the VM's telemetry address, or its mgmt address while it has no telemetry NIC. monitoring-config
# scrapes the same address (its local.telemetry_address, same rule): change both together.
variable "telemetry_vlan_id" {
  description = "VLAN of lylat-telemetry (every service VM's scrape and log-push NIC)."
  type        = number
  default     = 1501
}

locals {
  telemetry_ip = {
    for name, vm in var.vms : name => try(split("/", one([
      for nic in(vm.network_devices == null ? [] : vm.network_devices) : nic.ipv4_address
      if nic.vlan_id == var.telemetry_vlan_id && nic.ipv4_address != null
    ]))[0], null)
  }
  scrape_ip = {
    for name, vm in var.vms : name => coalesce(local.telemetry_ip[name], try(split("/", vm.management_address)[0], null))
  }
}
