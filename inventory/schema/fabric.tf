variable "fabric" {
  description = "Example overlay settings and fabric members."
  type = object({
    settings = object({
      bgp_system_as        = number
      spine_as             = number
      loopback_ipv4_prefix = string
      loopback_ipv6_prefix = string
      loopback_interface   = string
      vyos_mgmt_prefix     = string
      vyos_mgmt_cidr       = number
      l2_vni_base          = number
    })
    overlay_as = number
    leaves = map(object({
      role          = optional(string, "generic")
      proxmox_node  = optional(string)
      management_ip = string
      router_id     = string
      vtep_ipv6     = string
    }))
    spines = map(object({
      management_ip = string
      router_id     = string
      loopback_ipv6 = string
    }))
  })
  validation {
    condition     = var.fabric.overlay_as >= 1 && var.fabric.overlay_as <= 4294967295 && floor(var.fabric.overlay_as) == var.fabric.overlay_as
    error_message = "overlay_as must be a valid integer ASN."
  }
}
