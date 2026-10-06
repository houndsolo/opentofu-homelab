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
    external_l2_01 = {
      role = "external_l2"
      id   = 42
    }
    external_l3_01 = {
      role = "external_l3"
      id   = 18
    }
    external_l3_02 = {
      role = "external_l3"
      id   = 19
    }
  }
  spines = {
    spine01 = {
      management_ip = "192.0.2.1"
      id     = 1
    }
  }
}
