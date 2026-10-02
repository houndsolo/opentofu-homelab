variable "host_networking" {
  description = "Named Proxmox host bridge profiles."
  type = map(object({
    bridge = string
    uplink = string
    mtu = number
    vlan_aware = bool
  }))
  validation {
    condition = alltrue([for profile in values(var.host_networking) : profile.mtu >= 1280 && profile.mtu <= 9216 && floor(profile.mtu) == profile.mtu])
    error_message = "MTU must be an integer from 1280 through 9216."
  }
}
