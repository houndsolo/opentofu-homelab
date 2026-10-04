variable "pve_network" {
  description = "Proxmox cluster network profiles"
  type = object({
    eths = map(object({
      mtu         = number
      description = string
    }))
    bonds = map(object({
      mtu                   = number
      slaves                = list(string)
      bond_mode             = string
      bond_xmit_hash_policy = string
      description           = optional(string)
    }))
    bridges = map(object({
      mtu         = number
      description = string
      vlan_aware  = optional(bool)
      gateway     = optional(string)
      ports       = optional(list(string))
      ipv4 = optional(object({
        cidrhost_prefix = string
        cidr            = number
      }))
    }))
    vlans = map(object({
      port        = string
      mtu         = number
      description = string
      gateway     = optional(string)
      ipv4 = optional(object({
        cidrhost_prefix = string
        cidr            = number
      }))
    }))
  })
}
