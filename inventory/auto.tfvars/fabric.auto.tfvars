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
  #physical leaves. Virtual leaves are generated per var.nodes.proxmox
  leaves = {
    external_l2_01 = {
      role = "external_l2"
      id   = 42
      access_interface = "eth3"
      spine_uplink = "ether10"
    }
    external_l3_01 = {
      role = "external_l3"
      id   = 18
      access_interface = "eth3"
    }
    external_l3_02 = {
      role = "external_l3"
      id   = 19
      access_interface = "eth3"
    }
  }
  spines = {
    m326-1 = {
      management_ip = "10.20.0.5"
      id     = 1
    }
    m326-2 = {
      management_ip = "10.20.0.6"
      id     = 2
    }
  }
}
