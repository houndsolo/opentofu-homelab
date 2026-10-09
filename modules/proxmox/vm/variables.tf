variable "name" {
  description = "VM hostname, derived by the caller."
  type        = string
}

variable "vm" {
  description = "Placement, management addressing and ordered NICs for one VM."
  type = object({
    node               = string
    vm_id              = number
    cores              = optional(number)
    memory_mb          = optional(number)
    bridge             = optional(string)
    started            = optional(bool)
    tags               = optional(list(string))
    management_address = optional(string, "dhcp")
    gateway            = optional(string)
    network_devices = optional(list(object({
      bridge       = string
      vlan_id      = optional(number)
      mac_address  = optional(string)
      model        = optional(string)
      mtu          = optional(number)
      disconnected = optional(bool)
    })), [])
  })
}
