# Example values. Replace these with your intended topology.
fabric = {
  settings = {
    bgp_system_as        = 700
    spine_as             = 810
    loopback_ipv4_prefix = "10.255.240.0/24"
    loopback_ipv6_prefix = "fd69:255:240::/64"
    loopback_interface   = "dum240"
    vyos_mgmt_prefix     = "10.20.10.0/24"
    vyos_mgmt_cidr       = 16
    l2_vni_base          = 9000
  }
  overlay_as = 700
  leaves = {
    fichina = {
      role          = "proxmox"
      management_ip = "10.20.10.11"
      router_id     = "10.255.240.11"
      vtep_ipv6     = "fd69:255:240::11"
    }
  }
  spines = {
    spine01 = {
      management_ip = "192.0.2.1"
      router_id     = "10.255.241.1"
      loopback_ipv6 = "fd69:255:240::1"
    }
  }
}
