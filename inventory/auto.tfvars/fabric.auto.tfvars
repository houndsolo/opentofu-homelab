# Example values. Replace these with your intended topology.
fabric = {
  overlay_as = 700
  leaves = {
    leaf01 = {
      management_ip = "192.0.2.11"
      router_id = "10.255.240.11"
      vtep_ipv6 = "fd69:255:240::11"
    }
  }
  spines = {
    spine01 = {
      management_ip = "192.0.2.1"
      router_id = "10.255.241.1"
      loopback_ipv6 = "fd69:255:240::1"
    }
  }
}
