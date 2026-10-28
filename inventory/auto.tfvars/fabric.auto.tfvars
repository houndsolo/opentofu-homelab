fabric = {
  settings = {
    leaf_underlay_as_base    = 700
    spine_as                 = 810
    overlay_as               = 700
    loopback_ipv4_prefix     = "10.255.240.0/24"
    loopback_ipv6_prefix     = "fd69:255:240::/64"
    loopback_interface       = "dum240"
    management_prefix        = "10.20.10.0/24"
    management_prefix_length = 16
    l2_vni_base              = 9000
  }
  # Physical leaves. The fabric roots generate virtual Proxmox leaves from var.nodes.
  leaves = {
    external_l2_01 = {
      role             = "external_l2"
      id               = 42
      access_interface = "eth3"
      spine_uplink     = "ether10"
    }
    external_l3_01 = {
      role             = "external_l3"
      id               = 18
      access_interface = "eth3"
    }
    external_l3_02 = {
      role             = "external_l3"
      id               = 19
      access_interface = "eth3"
    }
  }
  spines = {
    m326-1 = {
      management_ip = "10.20.0.5"
      id            = 1
    }
    m326-2 = {
      management_ip = "10.20.0.6"
      id            = 2
    }
  }
}
