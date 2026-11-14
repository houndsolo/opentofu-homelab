vms = {
  dns01 = {
    owner              = "services-vms"
    role               = "dns"
    ha                 = { group = "dns" } # Proxmox HA; never on a node with another dns VM
    node               = "venom"
    vm_id              = 5301
    image              = "debian13"
    management_address = "10.20.53.1/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        bridge       = "vmbr4000"
        vlan_id      = 8
        ipv4_address = "10.8.53.1/16"
        ipv4_gateway = "10.8.0.5"
      },
      {
        # lylat-dns (VNI 5301): BIND + the VIP 10.53.53.53; VLAN 8 above stays the default route (same VRF).
        bridge       = "vmbr4000"
        vlan_id      = 1301
        ipv4_address = "10.53.53.51/16"
        ipv6_address = "fd69:5301::53:51/64"
      },
      {
        # HA L2VNI 9212 (l2vnis.ha_dns): keepalived adverts for the DNS VIP 10.8.53.53.
        bridge       = "vmbr4000"
        vlan_id      = 1053
        ipv4_address = "10.50.53.51/24"
        ipv6_address = "fd69:5053::51/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.53.51/16"
        ipv6_address = "fd69:5501::53:51/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "dns"]
      cpu_cores    = 2
      memory_mb    = 3072
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  dns02 = {
    owner              = "services-vms"
    role               = "dns"
    ha                 = { group = "dns" } # Proxmox HA; never on a node with another dns VM
    node               = "eldarad"
    vm_id              = 5302
    image              = "debian13"
    management_address = "10.20.53.2/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        bridge       = "vmbr4000"
        vlan_id      = 8
        ipv4_address = "10.8.53.2/16"
        ipv4_gateway = "10.8.0.5"
      },
      {
        # lylat-dns (VNI 5301): BIND + the VIP 10.53.53.53; VLAN 8 above stays the default route (same VRF).
        bridge       = "vmbr4000"
        vlan_id      = 1301
        ipv4_address = "10.53.53.52/16"
        ipv6_address = "fd69:5301::53:52/64"
      },
      {
        # HA L2VNI 9212 (l2vnis.ha_dns): keepalived adverts for the DNS VIP 10.8.53.53.
        bridge       = "vmbr4000"
        vlan_id      = 1053
        ipv4_address = "10.50.53.52/24"
        ipv6_address = "fd69:5053::52/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.53.52/16"
        ipv6_address = "fd69:5501::53:52/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "dns"]
      cpu_cores    = 2
      memory_mb    = 3072
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  dhcp01 = {
    owner              = "services-vms"
    role               = "dhcp"
    ha                 = { group = "dhcp" } # Proxmox HA; never on a node with another dhcp VM
    node               = "venom"
    vm_id              = 6701
    image              = "vyos"
    management_address = "10.20.67.1/16"
    config = {
      tags      = ["opentofu", "vyos", "dhcp"]
      cpu_cores = 2
      memory_mb = 2048
    }
  }
  dhcp02 = {
    owner              = "services-vms"
    role               = "dhcp"
    ha                 = { group = "dhcp" } # Proxmox HA; never on a node with another dhcp VM
    node               = "eldarad"
    vm_id              = 6702
    image              = "vyos"
    management_address = "10.20.67.2/16"
    config = {
      tags      = ["opentofu", "vyos", "dhcp"]
      cpu_cores = 2
      memory_mb = 2048
    }
  }
  mon01 = {
    owner              = "services-vms"
    role               = "monitoring"
    ha                 = { group = "monitoring" } # Proxmox HA; never on a node with another monitoring VM
    node               = "zoness"
    vm_id              = 1130
    image              = "debian13"
    management_address = "10.20.11.30/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.16.30/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::16:30/64"
      },
      {
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.30/16"
      },
      {
        # HA L2VNI 9215 (l2vnis.ha_monitor): keepalived (VIPs 10.5.11.102, 10.54.16.102) and Alertmanager gossip.
        bridge       = "vmbr4000"
        vlan_id      = 1016
        ipv4_address = "10.50.16.30/24"
        ipv6_address = "fd69:5016::30/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.16.30/16"
        ipv6_address = "fd69:5501::16:30/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 200 # Prometheus TSDB + Grafana Postgres (+ the retired InfluxDB's data until it's removed).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  triage01 = {
    # dark-triage helpdesk (github.com/houndsolo/vc-ticketing-system), HA pair with triage02:
    # Podman Quadlet + keepalived (VIP 10.52.13.105) deployed by services-config (ticketing.tf),
    # data in Postgres (Patroni). Same last octet everywhere (.43), like the monitoring VMs.
    owner              = "services-vms"
    role               = "ticketing"
    ha                 = { group = "ticketing" } # Proxmox HA; never on a node with another ticketing VM
    node               = "fichina"
    vm_id              = 1143
    image              = "debian13"
    management_address = "10.20.11.43/16"
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.13.43/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::13:43/64"
      },
      {
        # HA L2VNI ha_triage: keepalived adverts for the VIP 10.52.13.105.
        bridge       = "vmbr4000"
        vlan_id      = 1013
        ipv4_address = "10.50.13.43/24"
        ipv6_address = "fd69:5013::43/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.13.43/16"
        ipv6_address = "fd69:5501::13:43/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "ticketing"]
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  triage02 = {
    # dark-triage helpdesk (github.com/houndsolo/vc-ticketing-system), HA pair with triage01:
    # Podman Quadlet + keepalived (VIP 10.52.13.105) deployed by services-config (ticketing.tf),
    # data in Postgres (Patroni). Same last octet everywhere (.44), like the monitoring VMs.
    owner              = "services-vms"
    role               = "ticketing"
    ha                 = { group = "ticketing" } # Proxmox HA; never on a node with another ticketing VM
    node               = "titania"
    vm_id              = 1144
    image              = "debian13"
    management_address = "10.20.11.44/16"
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.13.44/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::13:44/64"
      },
      {
        # HA L2VNI ha_triage: keepalived adverts for the VIP 10.52.13.105.
        bridge       = "vmbr4000"
        vlan_id      = 1013
        ipv4_address = "10.50.13.44/24"
        ipv6_address = "fd69:5013::44/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.13.44/16"
        ipv6_address = "fd69:5501::13:44/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "ticketing"]
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  netbox01 = {
    # NetBox (IPAM/DCIM), HA pair with netbox02: netbox + netbox-worker as Podman Quadlets and keepalived
    # (VIP 10.52.12.106, netbox.lylat.space) deployed by services-config (netbox.tf). Data in Postgres
    # (Patroni, database "netbox"), cache and task queue in Valkey via Sentinel (valkey01-03).
    owner              = "services-vms"
    role               = "netbox"
    ha                 = { group = "netbox" } # Proxmox HA; never on a node with another netbox VM
    node               = "macbeth"
    vm_id              = 1145
    image              = "debian13"
    management_address = "10.20.11.45/16"
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.12.45/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::12:45/64"
      },
      {
        # Ceph public network: CephFS (/netbox) mounted at /var/lib/netbox, NetBox's media,
        # scripts and reports shared by both nodes.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.45/16"
      },
      {
        # HA L2VNI ha_netbox: keepalived adverts for the VIP 10.52.12.106.
        bridge       = "vmbr4000"
        vlan_id      = 1012
        ipv4_address = "10.50.12.45/24"
        ipv6_address = "fd69:5012::45/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.12.45/16"
        ipv6_address = "fd69:5501::12:45/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "netbox"]
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 20
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  netbox02 = {
    # NetBox (IPAM/DCIM), HA pair with netbox01: netbox + netbox-worker as Podman Quadlets and keepalived
    # (VIP 10.52.12.106, netbox.lylat.space) deployed by services-config (netbox.tf). Data in Postgres
    # (Patroni, database "netbox"), cache and task queue in Valkey via Sentinel (valkey01-03).
    owner              = "services-vms"
    role               = "netbox"
    ha                 = { group = "netbox" } # Proxmox HA; never on a node with another netbox VM
    node               = "venom"
    vm_id              = 1146
    image              = "debian13"
    management_address = "10.20.11.46/16"
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.12.46/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::12:46/64"
      },
      {
        # Ceph public network: CephFS (/netbox) mounted at /var/lib/netbox, NetBox's media,
        # scripts and reports shared by both nodes.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.46/16"
      },
      {
        # HA L2VNI ha_netbox: keepalived adverts for the VIP 10.52.12.106.
        bridge       = "vmbr4000"
        vlan_id      = 1012
        ipv4_address = "10.50.12.46/24"
        ipv6_address = "fd69:5012::46/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.12.46/16"
        ipv6_address = "fd69:5501::12:46/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "netbox"]
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 20
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  valkey01 = {
    # Valkey + Sentinel for NetBox (cache and task queue), trio valkey01-03: valkey01 starts as the
    # primary, the others replicate; the three Sentinels (quorum 2) promote a replica if the primary
    # dies. Deployed by services-config (valkey.tf). No VIP: NetBox asks the Sentinels for the primary.
    owner              = "services-vms"
    role               = "valkey"
    ha                 = { group = "valkey" } # Proxmox HA; never on a node with another valkey VM
    node               = "fichina"
    vm_id              = 1147
    image              = "debian13"
    management_address = "10.20.11.47/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.15.47/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::15:47/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.15.47/16"
        ipv6_address = "fd69:5501::15:47/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "valkey"]
      cpu_cores    = 1
      memory_mb    = 1024
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  valkey02 = {
    # Valkey + Sentinel for NetBox (cache and task queue), trio valkey01-03: valkey01 starts as the
    # primary, the others replicate; the three Sentinels (quorum 2) promote a replica if the primary
    # dies. Deployed by services-config (valkey.tf). No VIP: NetBox asks the Sentinels for the primary.
    owner              = "services-vms"
    role               = "valkey"
    ha                 = { group = "valkey" } # Proxmox HA; never on a node with another valkey VM
    node               = "titania"
    vm_id              = 1148
    image              = "debian13"
    management_address = "10.20.11.48/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.15.48/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::15:48/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.15.48/16"
        ipv6_address = "fd69:5501::15:48/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "valkey"]
      cpu_cores    = 1
      memory_mb    = 1024
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  valkey03 = {
    # Valkey + Sentinel for NetBox (cache and task queue), trio valkey01-03: valkey01 starts as the
    # primary, the others replicate; the three Sentinels (quorum 2) promote a replica if the primary
    # dies. Deployed by services-config (valkey.tf). No VIP: NetBox asks the Sentinels for the primary.
    owner              = "services-vms"
    role               = "valkey"
    ha                 = { group = "valkey" } # Proxmox HA; never on a node with another valkey VM
    node               = "fortuna"
    vm_id              = 1149
    image              = "debian13"
    management_address = "10.20.11.49/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.15.49/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::15:49/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.15.49/16"
        ipv6_address = "fd69:5501::15:49/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "valkey"]
      cpu_cores    = 1
      memory_mb    = 1024
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  proxy01 = {
    # nginx reverse proxy, HA pair with proxy02: HTTPS front end for the VLAN 2 web UIs (https://<name>.lylat.space,
    # Let's Encrypt wildcard from roots/certs via Cloudflare DNS-01), keepalived VIP 10.2.11.107.
    # Same last octet everywhere (.50), like the other service VMs.
    owner              = "services-vms"
    role               = "proxy"
    ha                 = { group = "proxy" } # Proxmox HA; never on a node with another proxy VM
    node               = "macbeth"
    vm_id              = 1150
    image              = "debian13"
    management_address = "10.20.11.50/16"
    network_devices = [
      {
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.50/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # lylat-app (VNI 5201): upstream leg to the Grafana/NetBox/dark-triage VIPs in 10.52.0.0/16, on-link.
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.10.50/16"
        ipv6_address = "fd69:5201::10:50/64"
      },
      {
        bridge       = "vmbr4000"
        vlan_id      = 1010
        ipv4_address = "10.50.10.50/24"
        ipv6_address = "fd69:5010::50/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.10.50/16"
        ipv6_address = "fd69:5501::10:50/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "proxy"]
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  proxy02 = {
    # nginx reverse proxy, HA pair with proxy01: HTTPS front end for the VLAN 2 web UIs (https://<name>.lylat.space,
    # Let's Encrypt wildcard from roots/certs via Cloudflare DNS-01), keepalived VIP 10.2.11.107.
    # Same last octet everywhere (.51), like the other service VMs.
    owner              = "services-vms"
    role               = "proxy"
    ha                 = { group = "proxy" } # Proxmox HA; never on a node with another proxy VM
    node               = "fichina"
    vm_id              = 1151
    image              = "debian13"
    management_address = "10.20.11.51/16"
    network_devices = [
      {
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.51/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # lylat-app (VNI 5201): upstream leg to the Grafana/NetBox/dark-triage VIPs in 10.52.0.0/16, on-link.
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.10.51/16"
        ipv6_address = "fd69:5201::10:51/64"
      },
      {
        bridge       = "vmbr4000"
        vlan_id      = 1010
        ipv4_address = "10.50.10.51/24"
        ipv6_address = "fd69:5010::51/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.10.51/16"
        ipv6_address = "fd69:5501::10:51/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "proxy"]
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 10
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  mon02 = {
    # Prometheus/Alertmanager replica of mon01 (Postgres stays on mon01 only).
    owner              = "services-vms"
    role               = "monitoring"
    ha                 = { group = "monitoring" } # Proxmox HA; never on a node with another monitoring VM
    node               = "macbeth"
    vm_id              = 1131
    image              = "debian13"
    management_address = "10.20.11.31/16"
    # No OOB default gateway is configured here. Same NIC order as mon01.
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.16.31/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::16:31/64"
      },
      {
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.31/16"
      },
      {
        # HA L2VNI 9215 (l2vnis.ha_monitor): keepalived (VIPs 10.5.11.102, 10.54.16.102) and Alertmanager gossip.
        bridge       = "vmbr4000"
        vlan_id      = 1016
        ipv4_address = "10.50.16.31/24"
        ipv6_address = "fd69:5016::31/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.16.31/16"
        ipv6_address = "fd69:5501::16:31/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 200 # Prometheus TSDB (+ the retired InfluxDB's data until it's removed).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  graf01 = {
    owner              = "services-vms"
    role               = "grafana"
    ha                 = { group = "grafana" } # Proxmox HA; never on a node with another grafana VM
    node               = "venom"
    vm_id              = 1132
    image              = "debian13"
    management_address = "10.20.11.32/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.11.32/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::11:32/64"
      },
      {
        # HA L2VNI 9213 (l2vnis.ha_grafana): keepalived (VIP 10.52.11.100) and alerting HA (9094).
        bridge       = "vmbr4000"
        vlan_id      = 1011
        ipv4_address = "10.50.11.32/24"
        ipv6_address = "fd69:5011::32/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.11.32/16"
        ipv6_address = "fd69:5501::11:32/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 2
      memory_mb    = 4096
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  graf02 = {
    owner              = "services-vms"
    role               = "grafana"
    ha                 = { group = "grafana" } # Proxmox HA; never on a node with another grafana VM
    node               = "eldarad"
    vm_id              = 1133
    image              = "debian13"
    management_address = "10.20.11.33/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        # lylat-app (VNI 5201): Grafana/NetBox/dark-triage and its VIP; reaches Postgres/Valkey (lylat-data) and obs over the zone imports.
        # Flat 10.52.0.0/16, default route via the anycast gateway 10.52.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1201
        ipv4_address = "10.52.11.33/16"
        ipv4_gateway = "10.52.0.1"
        ipv6_address = "fd69:5201::11:33/64"
      },
      {
        # HA L2VNI 9213 (l2vnis.ha_grafana): keepalived (VIP 10.52.11.100) and alerting HA (9094).
        bridge       = "vmbr4000"
        vlan_id      = 1011
        ipv4_address = "10.50.11.33/24"
        ipv6_address = "fd69:5011::33/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.11.33/16"
        ipv6_address = "fd69:5501::11:33/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 2
      memory_mb    = 4096
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  loki01 = {
    owner              = "services-vms"
    role               = "logging"
    ha                 = { group = "logging" } # Proxmox HA; never on a node with another logging VM
    node               = "zoness"
    vm_id              = 1134
    image              = "debian13"
    management_address = "10.20.11.34/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.18.34/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::18:34/64"
      },
      {
        # Monitoring network: syslog and log pushes from devices and PVE nodes.
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.34/16"
      },
      {
        # Ceph public network: the local RGW (S3 for Loki) talks to the mons and OSDs.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.34/16"
      },
      {
        # HA L2VNI 9214 (l2vnis.ha_logging): Loki memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1018
        ipv4_address = "10.50.18.34/24"
        ipv6_address = "fd69:5018::34/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.18.34/16"
        ipv6_address = "fd69:5501::18:34/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "logging"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Loki WAL and caches; chunks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  loki02 = {
    owner              = "services-vms"
    role               = "logging"
    ha                 = { group = "logging" } # Proxmox HA; never on a node with another logging VM
    node               = "titania"
    vm_id              = 1135
    image              = "debian13"
    management_address = "10.20.11.35/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.18.35/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::18:35/64"
      },
      {
        # Monitoring network: syslog and log pushes from devices and PVE nodes.
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.35/16"
      },
      {
        # Ceph public network: the local RGW (S3 for Loki) talks to the mons and OSDs.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.35/16"
      },
      {
        # HA L2VNI 9214 (l2vnis.ha_logging): Loki memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1018
        ipv4_address = "10.50.18.35/24"
        ipv6_address = "fd69:5018::35/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.18.35/16"
        ipv6_address = "fd69:5501::18:35/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "logging"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Loki WAL and caches; chunks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  loki03 = {
    owner              = "services-vms"
    role               = "logging"
    ha                 = { group = "logging" } # Proxmox HA; never on a node with another logging VM
    node               = "fortuna"
    vm_id              = 1136
    image              = "debian13"
    management_address = "10.20.11.36/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.18.36/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::18:36/64"
      },
      {
        # Monitoring network: syslog and log pushes from devices and PVE nodes.
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.36/16"
      },
      {
        # Ceph public network: the local RGW (S3 for Loki) talks to the mons and OSDs.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.36/16"
      },
      {
        # HA L2VNI 9214 (l2vnis.ha_logging): Loki memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1018
        ipv4_address = "10.50.18.36/24"
        ipv6_address = "fd69:5018::36/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.18.36/16"
        ipv6_address = "fd69:5501::18:36/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "logging"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Loki WAL and caches; chunks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }

  mim01 = {
    owner              = "services-vms"
    role               = "metrics"
    ha                 = { group = "metrics" } # Proxmox HA; never on a node with another metrics VM
    node               = "fichina"
    vm_id              = 1137
    image              = "debian13"
    management_address = "10.20.11.37/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.17.37/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::17:37/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.37/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1017
        ipv4_address = "10.50.17.37/24"
        ipv6_address = "fd69:5017::37/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.17.37/16"
        ipv6_address = "fd69:5501::17:37/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "metrics"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Mimir WAL, recent blocks and index headers; blocks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  mim02 = {
    owner              = "services-vms"
    role               = "metrics"
    ha                 = { group = "metrics" } # Proxmox HA; never on a node with another metrics VM
    node               = "venom"
    vm_id              = 1138
    image              = "debian13"
    management_address = "10.20.11.38/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.17.38/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::17:38/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.38/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1017
        ipv4_address = "10.50.17.38/24"
        ipv6_address = "fd69:5017::38/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.17.38/16"
        ipv6_address = "fd69:5501::17:38/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "metrics"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Mimir WAL, recent blocks and index headers; blocks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  mim03 = {
    owner              = "services-vms"
    role               = "metrics"
    ha                 = { group = "metrics" } # Proxmox HA; never on a node with another metrics VM
    node               = "eldarad"
    vm_id              = 1139
    image              = "debian13"
    management_address = "10.20.11.39/16"
    network_devices = [
      {
        # lylat-obs (VNI 5401): Prometheus/Alertmanager, Mimir, Loki query side and their VIPs; Grafana (lylat-app) queries it.
        # Flat 10.54.0.0/16, default route via the anycast gateway 10.54.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1401
        ipv4_address = "10.54.17.39/16"
        ipv4_gateway = "10.54.0.1"
        ipv6_address = "fd69:5401::17:39/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.39/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1017
        ipv4_address = "10.50.17.39/24"
        ipv6_address = "fd69:5017::39/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.17.39/16"
        ipv6_address = "fd69:5501::17:39/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "metrics"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 60 # Mimir WAL, recent blocks and index headers; blocks live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }

  pg01 = {
    # Patroni member (Postgres 17 + etcd + pgBackRest): Grafana's HA database.
    owner              = "services-vms"
    role               = "postgres"
    ha                 = { group = "postgres" } # Proxmox HA; never on a node with another postgres VM
    node               = "titania"
    vm_id              = 1140
    image              = "debian13"
    management_address = "10.20.11.40/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.14.40/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::14:40/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.40/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1014
        ipv4_address = "10.50.14.40/24"
        ipv6_address = "fd69:5014::40/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.14.40/16"
        ipv6_address = "fd69:5501::14:40/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "postgres"]
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 40 # Postgres data dir (POSIX filesystem); backups and WAL archive live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  pg02 = {
    # Patroni member (Postgres 17 + etcd + pgBackRest): Grafana's HA database.
    owner              = "services-vms"
    role               = "postgres"
    ha                 = { group = "postgres" } # Proxmox HA; never on a node with another postgres VM
    node               = "fortuna"
    vm_id              = 1141
    image              = "debian13"
    management_address = "10.20.11.41/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.14.41/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::14:41/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.41/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1014
        ipv4_address = "10.50.14.41/24"
        ipv6_address = "fd69:5014::41/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.14.41/16"
        ipv6_address = "fd69:5501::14:41/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "postgres"]
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 40 # Postgres data dir (POSIX filesystem); backups and WAL archive live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  pg03 = {
    # Patroni member (Postgres 17 + etcd + pgBackRest): Grafana's HA database.
    owner              = "services-vms"
    role               = "postgres"
    ha                 = { group = "postgres" } # Proxmox HA; never on a node with another postgres VM
    node               = "venom"
    vm_id              = 1142
    image              = "debian13"
    management_address = "10.20.11.42/16"
    network_devices = [
      {
        # lylat-data (VNI 5601): Postgres (VIP 10.56.14.104) / Valkey + Sentinel for the apps in lylat-app.
        # Flat 10.56.0.0/16, default route via the anycast gateway 10.56.0.1 (zone design, Obsidian zone-design.md).
        bridge       = "vmbr4000"
        vlan_id      = 1601
        ipv4_address = "10.56.14.42/16"
        ipv4_gateway = "10.56.0.1"
        ipv6_address = "fd69:5601::14:42/64"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.42/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 1014
        ipv4_address = "10.50.14.42/24"
        ipv6_address = "fd69:5014::42/64"
      },
      {
        # lylat-telemetry (VNI 5501): scrapes and log pushes. Flat 10.55.0.0/16, gateway 10.55.0.1 (no default
        # route here, none needed: everything in the zone is on-link). Zone design: Obsidian zone-design.md.
        bridge       = "vmbr4000"
        vlan_id      = 1501
        ipv4_address = "10.55.14.42/16"
        ipv6_address = "fd69:5501::14:42/64"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "postgres"]
      cpu_cores    = 2
      memory_mb    = 4096
      disk_size_gb = 40 # Postgres data dir (POSIX filesystem); backups and WAL archive live in Ceph (RGW).
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
}
