variable "name" {
  description = "DHCP VM name from inventory."
  type        = string
}

variable "management_ip" {
  description = "DHCP VM OOB IPv4 address, without the CIDR prefix."
  type        = string
}

variable "fabric_macs" {
  description = "Shared ethN -> MAC map from the same calculator used by VM creation. Excludes eth0."
  type        = map(string)
  default     = {}
}

variable "ha" {
  description = "Pair identity derived from numeric VM-ID order; active-active mode is separate from identity."
  type = object({
    role                = string
    address_slot        = number
    peer_slot           = number
    peer_name           = string
    local_management_ip = string
    peer_management_ip  = string
  })
  default = null
}

variable "interface_addresses" {
  description = "VyOS data ethN -> static IPv4 CIDR. Management eth0 is excluded."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for interface, address in var.interface_addresses :
      can(regex("^eth[1-9][0-9]*$", interface)) && can(cidrnetmask(address))
    ])
    error_message = "Assign valid IPv4 CIDRs only to data ethN interfaces; eth0 is excluded."
  }
}
