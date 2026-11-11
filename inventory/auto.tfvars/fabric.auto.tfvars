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
    ntp_servers              = ["10.20.10.255"] # fw-wan, mgmt network
    leaf_ntp_vrf             = "mgmt"
    # Scraped by monitoring-config (jobs vyos-node / vyos-frr).
    leaf_prometheus_exporters = { vrf = "mgmt" }
    # Syslog (TCP 514, RFC 5424) to every logging VM's own mgmt address (loki01-03,
    # monitoring-config). No VIP on mgmt: each Alloy forwards to Loki, which drops the
    # identical copies (same stream, timestamp and line).
    leaf_syslog = { hosts = ["10.20.11.34", "10.20.11.35", "10.20.11.36"], vrf = "mgmt" }
    # Spines: UDP 514 (RFC 3164) to the Loki/Alloy VIP on the monitoring network, sent
    # from their VLAN 5 address (10.5.0.<n>).
    spine_syslog = { host = "10.5.11.101" }
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
