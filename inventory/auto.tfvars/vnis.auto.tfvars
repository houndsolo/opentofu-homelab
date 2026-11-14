vnis = [
  {
    vlan_id   = 1000
    vni       = 6666
    roles     = ["external_l3"]
    vrf       = "lylat-external"
    vrf_table = 6666
    ext_l3    = true
    ext_l3_peer = {
      remote_as   = 420 # fw-wan (VXLAN_Border_Spine in its lylat-external VRF)
      description = "lylat-external L3 external connectivity"
    }
    ipv4_rt_imports = "700:6900 700:6700 700:5100 700:5200 700:5300 700:5400 700:5600"
    ipv4_rt_exports = "700:6666"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:6666",
      "700:6900",
      "700:6700",
      "700:5100",
      "700:5200",
      "700:5300",
      "700:5400",
      "700:5600",
    ]
    evpn_rt_exports = [
      "700:6666",
    ]
  },
  {
    vlan_id         = 69
    vni             = 6900
    roles           = ["proxmox", "external_l2"]
    vrf             = "lylat-lan"
    vrf_table       = 1337
    ipv4_rt_imports = "700:6700 700:5100 700:5300"
    ipv4_rt_exports = "700:6900"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    #redistribute_ipv4 = {
    #  connected = {}
    #}
    evpn_rt_imports = [
      "700:6900",
      "700:6700",
      "700:6666",
      "700:5100",
      "700:5300",
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
        anycast_mac          = "02:00:00:00:09:01"
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
        anycast_mac          = "02:00:00:00:10:01"
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
        anycast_mac          = "02:00:00:00:11:01"
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
    }
  },

  # lylat-edge (zone design, DT-090): VLAN 2 / VNI 9002 / 10.2.0.0/16 kept as it was (moved from lylat_infra):
  # the nginx front end (proxy-vip 10.2.11.107) and other VLAN 2 hosts. 10.51.0.0/16 stays reserved, unused.
  {
    vlan_id         = 1100
    vni             = 5100
    roles           = ["proxmox"]
    vrf             = "lylat-edge"
    vrf_table       = 5100
    ipv4_rt_imports = "700:6900 700:6700 700:6666 700:5300"
    ipv4_rt_exports = "700:5100"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:5100",
      "700:6900",
      "700:6700",
      "700:6666",
      "700:5300",
    ]
    evpn_rt_exports = [
      "700:5100",
    ]

    l2 = {
      2 = {
        vni                  = 9002
        vlan_id              = 2
        anycast_gw_ip        = "10.2.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:00:02:01"
        anycast_gw_ipv6      = "fd69:9002::1/64"
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

  # lylat-app: Grafana, NetBox, dark-triage and their VIPs, the proxy's upstream leg. 10.52.0.0/16.
  {
    vlan_id         = 1200
    vni             = 5200
    roles           = ["proxmox"]
    vrf             = "lylat-app"
    vrf_table       = 5200
    ipv4_rt_imports = "700:5300 700:5400 700:5600 700:6666"
    ipv4_rt_exports = "700:5200"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:5200",
      "700:5300",
      "700:5400",
      "700:5600",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:5200",
    ]

    l2 = {
      1201 = {
        vni                  = 5201
        vlan_id              = 1201
        anycast_gw_ip        = "10.52.0.1"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:12:01:01"
        anycast_gw_ipv6      = "fd69:5201::1/64"
        router_advert        = true
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
    }
  },

  # lylat-dns: dns01/02, VIP 10.53.53.53 on 1301 and the kept VLAN 8 / 9008 / 10.8.0.0/16 (VIP 10.8.53.53,
  # gateway 10.8.0.5) moved from lylat_service. Imports every zone and client VRF it answers.
  {
    vlan_id         = 1300
    vni             = 5300
    roles           = ["proxmox"]
    vrf             = "lylat-dns"
    vrf_table       = 5300
    ipv4_rt_imports = "700:5100 700:5200 700:5400 700:5600 700:6900 700:6700 700:6666"
    ipv4_rt_exports = "700:5300"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:5300",
      "700:5100",
      "700:5200",
      "700:5400",
      "700:5600",
      "700:6900",
      "700:6700",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:5300",
    ]

    l2 = {
      1301 = {
        vni                  = 5301
        vlan_id              = 1301
        anycast_gw_ip        = "10.53.0.1"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:13:01:01"
        anycast_gw_ipv6      = "fd69:5301::1/64"
        router_advert        = true
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
      8 = {
        vni                  = 9008
        vlan_id              = 8
        anycast_gw_ip        = "10.8.0.5"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:00:08:01"
        anycast_gw_ipv6      = "fd69:9008::1/64"
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

  # lylat-obs: Prometheus/Alertmanager, Mimir, Loki query side (VIPs 10.54.16.102, .17.103, .18.101). 10.54.0.0/16.
  {
    vlan_id         = 1400
    vni             = 5400
    roles           = ["proxmox"]
    vrf             = "lylat-obs"
    vrf_table       = 5400
    ipv4_rt_imports = "700:5200 700:5300 700:6666"
    ipv4_rt_exports = "700:5400"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:5400",
      "700:5200",
      "700:5300",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:5400",
    ]

    l2 = {
      1401 = {
        vni                  = 5401
        vlan_id              = 1401
        anycast_gw_ip        = "10.54.0.1"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:14:01:01"
        anycast_gw_ipv6      = "fd69:5401::1/64"
        router_advert        = true
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
    }
  },

  # lylat-data: Postgres (VIP 10.56.14.104) and Valkey/Sentinel. 10.56.0.0/16.
  {
    vlan_id         = 1600
    vni             = 5600
    roles           = ["proxmox"]
    vrf             = "lylat-data"
    vrf_table       = 5600
    ipv4_rt_imports = "700:5200 700:5300 700:6666"
    ipv4_rt_exports = "700:5600"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:5600",
      "700:5200",
      "700:5300",
      "700:6666",
    ]
    evpn_rt_exports = [
      "700:5600",
    ]

    l2 = {
      1601 = {
        vni                  = 5601
        vlan_id              = 1601
        anycast_gw_ip        = "10.56.0.1"
        anycast_gw_cidr      = 16
        anycast_mac          = "02:00:00:16:01:01"
        anycast_gw_ipv6      = "fd69:5601::1/64"
        router_advert        = true
        advertise_default_gw = false
        advertise_svi_ip     = false
        export_ipv4_unicast  = true
      }
    }
  },

  # lylat-telemetry (zone design, Obsidian homelab-docs/evpn-fabric/zone-design.md): scrapes and log
  # pushes from every service VM, one flat /16 segment, gateway .0.1. Isolated: no
  # ipv4 VPN leaking, EVPN RTs only its own, no DHCP. Numbering: L3VNI/table Z00, L3 VLAN Z00-4000,
  # segment L2VNI Z01, VLAN = VNI - 4000, 10.Z.0.0/16 (Z = 55).
  {
    vlan_id         = 1500
    vni             = 5500
    roles           = ["proxmox"]
    vrf             = "lylat-telemetry"
    vrf_table       = 5500
    import_ipv4_vpn = false
    export_vpn_ipv4 = false
    evpn_rt_imports = [
      "700:5500",
    ]
    evpn_rt_exports = [
      "700:5500",
    ]

    l2 = {
      1501 = {
        vni             = 5501
        vlan_id         = 1501
        anycast_gw_ip   = "10.55.0.1"
        anycast_gw_cidr = 16
        anycast_mac     = "02:00:00:15:01:01"
        anycast_gw_ipv6 = "fd69:5501::1/64"
      }
    }
  },

  {
    vlan_id         = 67
    vni             = 6700
    roles           = ["proxmox", "external_l2"]
    vrf             = "lylat-ai"
    vrf_table       = 6700
    ipv4_rt_imports = "700:6900 700:5100 700:5300"
    ipv4_rt_exports = "700:6700"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true
    evpn_rt_imports = [
      "700:6700",
      "700:6900",
      "700:6666",
      "700:5100",
      "700:5300",
    ]
    evpn_rt_exports = [
      "700:6700",
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
        anycast_mac          = "02:00:00:00:12:01"
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
