vnis = [
  {
    vlan_id     = 1000
    vni         = 6666
    roles       = ["external_l3"]
    vrf         = "lylat_external"
    vrf_table   = 6666
    anycast_mac = "bc:24:11:00:66:66"
    #ipv4_rt_imports = "700:6200 700:6900"
    #ipv4_rt_exports = "700:6600"
    #border_leaf_ipv4_rt_imports = "420:1337 420:666"
    #border_leaf_ipv4_vrf_imports = [
    #]
    ext_l3                           = true
    border_leaf_ipv4_rt_imports      = "700:6900 700:6600 700:6200"
    border_leaf_ipv4_rt_exports      = "700:6666"
    border_leaf_ipv4_vpn_import_bool = true
    export_vpn_ipv4                  = true
    evpn_rt_imports = [
      "700:6666",
      "700:6900",
      "700:6600",
      "700:6800",
      "700:6200",
    ]
    evpn_rt_exports = [
      "700:6666",
    ]
  },
  {
    vlan_id         = 66
    vni             = 6600
    roles           = ["proxmox"]
    vrf             = "lylat_service"
    vrf_table       = 1000
    ipv4_rt_imports = "700:6200 700:6900"
    ipv4_rt_exports = "700:6600"
    #border_leaf_ipv4_rt_imports = "420:1337 420:666"
    #border_leaf_ipv4_vrf_imports = [
    #]
    #border_leaf_ipv4_rt_imports      = "700:6666 700:6900 700:6200"
    #border_leaf_ipv4_rt_exports      = "700:6600"
    border_leaf_ipv4_vpn_import_bool = true
    export_vpn_ipv4                  = true
    #anycast_mac          = "bc:24:11:00:66:00"
    evpn_rt_imports = [
      "700:6600",
      "700:6200",
      "700:6900",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:6600",
    ]
    #redistribute_ipv4 = {
    #  connected = {}
    #}

    l2 = {
      6 = {
        vni                  = 9006
        vlan_id              = 6
        anycast_gw_ip        = "10.6.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:66:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.6.5.1", stop = "10.6.5.99" }
            }
          }
        }
      }
      8 = {
        vni                  = 9008
        vlan_id              = 8
        anycast_gw_ip        = "10.8.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:66:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.8.5.1", stop = "10.8.5.99" }
            }
          }
        }
      }
    }
  },
  {
    vlan_id   = 69
    vni       = 6900
    roles     = ["proxmox", "external_l2"]
    vrf       = "lylat_lan"
    vrf_table = 1337
    #anycast_mac          = "bc:24:11:00:69:00"
    ipv4_rt_imports = "700:6600 700:6200 700:6800"
    ipv4_rt_exports = "700:6900"
    #border_leaf_ipv4_vrf_imports = [
    #  "lylat_service",
    #]
    #border_leaf_ipv4_rt_imports      = "700:6666 700:6600 700:6200"
    #border_leaf_ipv4_rt_exports      = "700:6900"
    border_leaf_ipv4_vpn_import_bool = true
    export_vpn_ipv4                  = true
    #redistribute_ipv4 = {
    #  connected = {}
    #}
    evpn_rt_imports = [
      "700:6900",
      "700:6600",
      "700:6200",
      "700:6800",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:6900",
    ]

    l2 = {
      9 = {
        vni                  = 9009
        vlan_id              = 9
        anycast_gw_ip        = "10.9.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:69:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.9.5.1", stop = "10.9.5.99" }
            }
          }
        }
      }
      10 = {
        vni                  = 9010
        vlan_id              = 10
        anycast_gw_ip        = "10.10.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:69:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.10.5.1", stop = "10.10.5.99" }
            }
          }
        }
      }
      11 = {
        vni                  = 9011
        vlan_id              = 11
        anycast_gw_ip        = "10.11.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:69:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
    }
  },

  {
    vlan_id         = 62
    vni             = 6200
    roles           = ["proxmox"]
    vrf             = "lylat_infra"
    vrf_table       = 700
    ipv4_rt_imports = "700:6600 700:6900"
    ipv4_rt_exports = "700:6200"
    #border_leaf_ipv4_vrf_imports = [
    #  "lylat_service",
    #]
    #border_leaf_ipv4_rt_imports      = "700:6666 700:6600 700:6900"
    #border_leaf_ipv4_rt_exports      = "700:6200"
    #anycast_mac          = "bc:24:11:00:62:00"
    border_leaf_ipv4_vpn_import_bool = true
    export_vpn_ipv4                  = true
    evpn_rt_imports = [
      "700:6200",
      "700:6900",
      "700:6600",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:6200",
    ]
    #redistribute_ipv4 = {
    #  connected = {}
    #}

    l2 = {
      2 = {
        vni                  = 9002
        vlan_id              = 2
        anycast_gw_ip        = "10.2.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:62:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.2.5.1", stop = "10.2.5.99" }
            }
          }
        }
      }
    }
  },

  {
    vlan_id                          = 67
    vni                              = 6800
    roles                            = ["external_l2"]
    vrf                              = "lylat_ai"
    vrf_table                        = 6800
    ipv4_rt_imports                  = "700:6600 700:6900"
    ipv4_rt_exports                  = "700:6800"
    border_leaf_ipv4_vpn_import_bool = true
    export_vpn_ipv4                  = true
    evpn_rt_imports = [
      "700:6800",
      "700:6900",
      "700:6600",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:6800",
    ]
    #redistribute_ipv4 = {
    #  connected = {}
    #}

    l2 = {
      12 = {
        vni                  = 9012
        vlan_id              = 12
        anycast_gw_ip        = "10.12.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "bc:24:11:00:67:00"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
        dhcp = {
          scope = {
            ranges = {
              0 = { start = "10.12.5.1", stop = "10.12.5.99" }
            }
          }
        }
      }
    }
  }
]
