variable "vnis" {
  description = "L3VNIs with nested L2VNIs, selected by leaf role."
  default     = []
  type = list(object({
    roles            = set(string)
    vni              = number
    vrf              = string
    vrf_table        = number
    vlan_id          = number
    ipv4_rt_imports  = optional(string, null)
    ipv4_rt_exports  = optional(string, null)
    import_ipv4_vpn  = optional(bool, false)
    import_ipv4_vrfs = optional(list(string), null)
    evpn_rt_imports  = optional(list(string), [])
    evpn_rt_exports  = optional(list(string), [])
    ext_l3           = optional(bool, false)
    # BGP to the external router (fw-wan) on external_l3 leaves: an unnumbered (v6only)
    # session on <access_interface>.<vlan_id> in this VRF. Needs ext_l3 = true.
    ext_l3_peer = optional(object({
      remote_as   = number
      peer_group  = optional(string, "FW_L3_out")
      bfd         = optional(bool, true)
      description = optional(string, "external L3 connectivity")
    }))
    export_vpn_ipv4 = optional(bool, false)
    anycast_mac     = optional(string, null)
    redistribute_ipv4 = optional(object({
      connected = optional(object({ route_map = optional(string) }), null)
      static    = optional(object({}), null)
    }))
    l2 = optional(map(object({
      vni                  = number
      vlan_id              = number
      anycast_gw_ip        = string
      anycast_gw_cidr      = number
      anycast_mac          = string
      advertise_default_gw = optional(bool, false)
      advertise_svi_ip     = optional(bool, false)
      export_ipv4_unicast  = optional(bool, false)
      # IPv6 anycast gateway (CIDR, e.g. "fd69:5201::1/64", zone design step 8) and router advertisements on it
      # (default route + on-link prefix, no SLAAC: hosts keep their static addresses). null = IPv4 only.
      anycast_gw_ipv6 = optional(string)
      router_advert   = optional(bool, false)
      dhcp = optional(object({
        scope = optional(object({
          ranges = map(object({
            start = string
            stop  = string
          }))
          name_servers  = optional(list(string))
          domain_name   = optional(string)
          domain_search = optional(list(string))
          lease_seconds = optional(number)
          authoritative = optional(bool)
        }))
      }))
    })), {})
  }))

  validation {
    condition = alltrue([
      for l3 in var.vnis :
      length(l3.roles) > 0 && alltrue([
        for role in l3.roles : contains(["proxmox", "external_l2", "external_l3"], role)
      ])
    ])
    error_message = "Every L3VNI needs a nonempty set of valid leaf roles."
  }

  validation {
    condition = alltrue(flatten([
      for l3 in var.vnis : concat(
        [l3.vni >= 1 && l3.vni <= 16777215, l3.vrf_table >= 1 && l3.vrf_table <= 4294967295, trimspace(l3.vrf) != ""],
        [for l2 in values(l3.l2) :
          l2.vni >= 1 && l2.vni <= 16777215 &&
          l2.vlan_id >= 1 && l2.vlan_id <= 4094 &&
          l2.anycast_gw_cidr >= 0 && l2.anycast_gw_cidr <= 32 &&
          can(cidrhost("${l2.anycast_gw_ip}/${l2.anycast_gw_cidr}", 0)) &&
          !strcontains(l2.anycast_gw_ip, ":") &&
          (l2.anycast_gw_ipv6 == null || (strcontains(coalesce(l2.anycast_gw_ipv6, "x"), ":") && can(cidrhost(l2.anycast_gw_ipv6, 0)))) &&
          (!l2.router_advert || l2.anycast_gw_ipv6 != null) &&
          can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", l2.anycast_mac))
        ]
      )
    ]))
    error_message = "VNIs must be 1..16777215, tables 1..4294967295, VRF names non-empty, VLANs 1..4094, and every L2 gateway/MAC must be valid IPv4/CIDR and six-octet MAC syntax."
  }

  validation {
    condition     = alltrue([for l3 in var.vnis : l3.ext_l3_peer == null || (l3.ext_l3 && contains(l3.roles, "external_l3"))])
    error_message = "ext_l3_peer needs ext_l3 = true and the external_l3 role."
  }

  validation {
    # VyOS rejects longer VRF names at commit time ("15 characters or less").
    condition     = alltrue([for l3 in var.vnis : can(regex("^[A-Za-z][A-Za-z0-9_-]{0,14}$", l3.vrf))])
    error_message = "VRF names must start with a letter and be at most 15 characters (VyOS limit)."
  }

  validation {
    condition = alltrue([
      for l3 in var.vnis :
      (!l3.import_ipv4_vpn || l3.ipv4_rt_imports != null) && (!l3.export_vpn_ipv4 || l3.ipv4_rt_exports != null)
    ])
    error_message = "Set ipv4_rt_imports when import_ipv4_vpn is true, and ipv4_rt_exports when export_vpn_ipv4 is true."
  }

  validation {
    condition = (
      length(distinct([for vrf in var.vnis : vrf.vrf])) == length(var.vnis) &&
      length(distinct([for vrf in var.vnis : vrf.vrf_table])) == length(var.vnis) &&
      length(distinct(concat(
        [for vrf in var.vnis : vrf.vlan_id],
        flatten([for vrf in var.vnis : [for l2 in values(vrf.l2) : l2.vlan_id]]),
        ))) == length(concat(
        [for vrf in var.vnis : vrf.vlan_id],
        flatten([for vrf in var.vnis : [for l2 in values(vrf.l2) : l2.vlan_id]]),
      ))
    )
    error_message = "VRF names, VRF tables, and bridge VLAN IDs must be unique."
  }

  validation {
    condition = alltrue([
      for vrf in var.vnis :
      vrf.vni == floor(vrf.vni) && vrf.vrf_table == floor(vrf.vrf_table) &&
      vrf.vlan_id == floor(vrf.vlan_id) && vrf.vlan_id >= 1 && vrf.vlan_id <= 4094 &&
      alltrue([for l2 in values(vrf.l2) :
        l2.vni == floor(l2.vni) && l2.vlan_id == floor(l2.vlan_id) &&
        l2.anycast_gw_cidr == floor(l2.anycast_gw_cidr)
      ])
    ])
    error_message = "VNI, table, VLAN and prefix length values must be integers; L3 VLAN IDs must be 1..4094."
  }

  validation {
    condition = length(distinct(concat(
      [for l3 in var.vnis : l3.vni],
      flatten([for l3 in var.vnis : [for l2 in values(l3.l2) : l2.vni]]),
      ))) == length(concat(
      [for l3 in var.vnis : l3.vni],
      flatten([for l3 in var.vnis : [for l2 in values(l3.l2) : l2.vni]]),
    ))
    error_message = "Every L2VNI and L3VNI must be unique."
  }
}
