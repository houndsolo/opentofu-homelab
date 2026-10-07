variable "network_services" {
  description = "DHCP/DNS VM creation only; no application configuration."
  type = object({
    dhcp = map(object({
      node               = string
      vm_id              = number
      management_address = string
    }))
    dns = map(object({
      node               = string
      vm_id              = number
      management_address = string
      service_address    = string
    }))
    dns_network = optional(object({
      bridge  = optional(string, "vmbr4000")
      vlan_id = optional(number, 8)
      gateway = optional(string, "10.8.0.5")
    }), {})
    dhcp_user_data_file_id = optional(string, "cephfs:snippets/vyos_api.yml")
    dns_bootstrap = optional(object({
      node         = optional(string, "fichina")
      datastore_id = optional(string, "cephfs")
      username     = optional(string, "mechanic")
    }), {})
  })
  validation {
    condition = alltrue([
      for id in concat([for vm in values(var.network_services.dhcp) : vm.vm_id], [for vm in values(var.network_services.dns) : vm.vm_id]) : id >= 100 && floor(id) == id
    ])
    error_message = "Service VM IDs must be integers of at least 100."
  }
  validation {
    condition = (
      length(distinct(concat([for vm in values(var.network_services.dhcp) : vm.vm_id], [for vm in values(var.network_services.dns) : vm.vm_id]))) ==
      length(var.network_services.dhcp) + length(var.network_services.dns)
    )
    error_message = "All service VM IDs must be unique."
  }
  validation {
    condition = length(distinct(concat(
      [for vm in values(var.network_services.dhcp) : split("/", vm.management_address)[0]],
      [for vm in values(var.network_services.dns) : split("/", vm.management_address)[0]],
      [for vm in values(var.network_services.dns) : split("/", vm.service_address)[0]],
    ))) == length(var.network_services.dhcp) + 2 * length(var.network_services.dns)
    error_message = "Service VM management and service IPv4 addresses must be unique."
  }
  validation {
    condition = alltrue(concat(
      [for vm in values(var.network_services.dhcp) : !strcontains(vm.management_address, ":") && can(cidrhost(vm.management_address, 0))],
      [for vm in values(var.network_services.dns) : !strcontains(vm.management_address, ":") && can(cidrhost(vm.management_address, 0)) && !strcontains(vm.service_address, ":") && can(cidrhost(vm.service_address, 0))],
    ))
    error_message = "Service VM addresses must include valid CIDR prefixes."
  }
}

variable "debian_image" {
  description = "Verified Debian 13 image pin; obtain URL/filename/SHA512 from Debian's dated image catalog."
  type = object({
    url          = string
    file_name    = string
    checksum     = string
    node         = optional(string, "fichina")
    datastore_id = optional(string, "cephfs")
  })
  validation {
    condition     = startswith(var.debian_image.url, "https://") && !strcontains(var.debian_image.url, "/latest/") && can(regex("^[0-9a-fA-F]{128}$", var.debian_image.checksum))
    error_message = "Provide a pinned HTTPS Debian image URL and its published SHA512 checksum."
  }
}
