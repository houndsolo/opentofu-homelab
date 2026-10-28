variable "fabric" {
  description = "Fabric addressing, AS numbers and members."
  type = object({
    settings = object({
      leaf_underlay_as_base    = number # Leaf underlay AS = base + leaf id.
      spine_as                 = number
      overlay_as               = number # iBGP EVPN AS shared by leaves and spines.
      loopback_ipv4_prefix     = string
      loopback_ipv6_prefix     = string
      loopback_interface       = string
      management_prefix        = string
      management_prefix_length = number
      l2_vni_base              = number
      vxlan_mtu                = optional(number, 9119)
      outer_mtu                = optional(number, 9189)
    })
    leaves = map(object({
      role             = string
      id               = number
      proxmox_node     = optional(string)
      access_interface = string
      spine_uplink     = optional(string)
    }))
    spines = map(object({
      management_ip    = string
      id               = number
      uplink_interface = optional(string)
      as               = optional(number) # Overrides settings.spine_as.
    }))
  })
}
