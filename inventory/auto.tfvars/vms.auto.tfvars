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
        # HA L2VNI 9212 (l2vnis.ha_dns): keepalived adverts for the DNS VIP 10.8.53.53.
        bridge       = "vmbr4000"
        vlan_id      = 212
        ipv4_address = "10.21.53.1/24"
      },
      {
        # Isolated monitoring backend: Alloy pushes the journal to Loki's backend VIP 10.13.11.101.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.53.1/16"
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
        # HA L2VNI 9212 (l2vnis.ha_dns): keepalived adverts for the DNS VIP 10.8.53.53.
        bridge       = "vmbr4000"
        vlan_id      = 212
        ipv4_address = "10.21.53.2/24"
      },
      {
        # Isolated monitoring backend: Alloy pushes the journal to Loki's backend VIP 10.13.11.101.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.53.2/16"
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
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.30/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.30/16"
      },
      {
        # Isolated monitoring backend (lylat_monitor VRF): Grafana <-> mon01.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.30/16"
      },
      {
        # HA L2VNI 9215 (l2vnis.ha_monitor): keepalived (VIPs 10.5.11.102, 10.13.11.102) and Alertmanager gossip.
        bridge       = "vmbr4000"
        vlan_id      = 215
        ipv4_address = "10.21.13.30/24"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 200 # Prometheus TSDB + InfluxDB + Grafana Postgres.
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  triage01 = {
    # dark-triage helpdesk (github.com/houndsolo/vc-ticketing-system), HA pair with triage02:
    # Podman Quadlet + keepalived (VIP 10.2.11.105) deployed by services-config (ticketing.tf),
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
        # VLAN 2, static, outside the DHCP pool 10.2.5.1-10.2.5.99. Default route via the anycast gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.43/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Postgres (Patroni VIP 10.13.11.104) for the app's database.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.43/16"
      },
      {
        # HA L2VNI ha_triage: keepalived adverts for the VIP 10.2.11.105.
        bridge       = "vmbr4000"
        vlan_id      = 218
        ipv4_address = "10.21.16.43/24"
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
    # Podman Quadlet + keepalived (VIP 10.2.11.105) deployed by services-config (ticketing.tf),
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
        # VLAN 2, static, outside the DHCP pool 10.2.5.1-10.2.5.99. Default route via the anycast gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.44/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Postgres (Patroni VIP 10.13.11.104) for the app's database.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.44/16"
      },
      {
        # HA L2VNI ha_triage: keepalived adverts for the VIP 10.2.11.105.
        bridge       = "vmbr4000"
        vlan_id      = 218
        ipv4_address = "10.21.16.44/24"
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
    # (VIP 10.2.11.106, netbox.lylat.space) deployed by services-config (netbox.tf). Data in Postgres
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
        # VLAN 2, static, outside the DHCP pool 10.2.5.1-10.2.5.99. Default route via the anycast gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.45/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Postgres (Patroni VIP 10.13.11.104) and the Valkey Sentinels.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.45/16"
      },
      {
        # Ceph public network: CephFS (/netbox) mounted at /var/lib/netbox, NetBox's media,
        # scripts and reports shared by both nodes.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.45/16"
      },
      {
        # HA L2VNI ha_netbox: keepalived adverts for the VIP 10.2.11.106.
        bridge       = "vmbr4000"
        vlan_id      = 219
        ipv4_address = "10.21.17.45/24"
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
    # (VIP 10.2.11.106, netbox.lylat.space) deployed by services-config (netbox.tf). Data in Postgres
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
        # VLAN 2, static, outside the DHCP pool 10.2.5.1-10.2.5.99. Default route via the anycast gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.46/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Postgres (Patroni VIP 10.13.11.104) and the Valkey Sentinels.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.46/16"
      },
      {
        # Ceph public network: CephFS (/netbox) mounted at /var/lib/netbox, NetBox's media,
        # scripts and reports shared by both nodes.
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.46/16"
      },
      {
        # HA L2VNI ha_netbox: keepalived adverts for the VIP 10.2.11.106.
        bridge       = "vmbr4000"
        vlan_id      = 219
        ipv4_address = "10.21.17.46/24"
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
        # VLAN 2, static, outside the DHCP pool. Default route via the anycast gateway (apt).
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.47/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Valkey (6379) and Sentinel (26379) for NetBox, replication between the trio.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.47/16"
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
        # VLAN 2, static, outside the DHCP pool. Default route via the anycast gateway (apt).
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.48/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Valkey (6379) and Sentinel (26379) for NetBox, replication between the trio.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.48/16"
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
        # VLAN 2, static, outside the DHCP pool. Default route via the anycast gateway (apt).
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.49/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Backend VLAN 13: Valkey (6379) and Sentinel (26379) for NetBox, replication between the trio.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.49/16"
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
        bridge       = "vmbr4000"
        vlan_id      = 220
        ipv4_address = "10.21.18.50/24"
      },
      {
        # Isolated monitoring backend: Alloy pushes the journal to Loki's backend VIP 10.13.11.101.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.50/16"
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
        bridge       = "vmbr4000"
        vlan_id      = 220
        ipv4_address = "10.21.18.51/24"
      },
      {
        # Isolated monitoring backend: Alloy pushes the journal to Loki's backend VIP 10.13.11.101.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.51/16"
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
    # Prometheus/Alertmanager/InfluxDB replica of mon01 (Postgres stays on mon01 only).
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
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.31/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        bridge       = "vmbr100"
        ipv4_address = "10.5.11.31/16"
      },
      {
        # Isolated monitoring backend (lylat_monitor VRF): Grafana and Mimir.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.31/16"
      },
      {
        # HA L2VNI 9215 (l2vnis.ha_monitor): keepalived (VIPs 10.5.11.102, 10.13.11.102) and Alertmanager gossip.
        bridge       = "vmbr4000"
        vlan_id      = 215
        ipv4_address = "10.21.13.31/24"
      },
    ]
    config = {
      tags         = ["opentofu", "debian", "monitoring"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 200 # Prometheus TSDB + InfluxDB.
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
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.32/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend (lylat_monitor VRF): mon01 + Grafana HA.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.32/16"
      },
      {
        # HA L2VNI 9213 (l2vnis.ha_grafana): keepalived (VIP 10.2.11.100) and alerting HA (9094).
        bridge       = "vmbr4000"
        vlan_id      = 213
        ipv4_address = "10.21.11.32/24"
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
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.33/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend (lylat_monitor VRF): mon01 + Grafana HA.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.33/16"
      },
      {
        # HA L2VNI 9213 (l2vnis.ha_grafana): keepalived (VIP 10.2.11.100) and alerting HA (9094).
        bridge       = "vmbr4000"
        vlan_id      = 213
        ipv4_address = "10.21.11.33/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.34/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Loki ring (memberlist) and Grafana queries.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.34/16"
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
        vlan_id      = 214
        ipv4_address = "10.21.12.34/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.35/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Loki ring (memberlist) and Grafana queries.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.35/16"
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
        vlan_id      = 214
        ipv4_address = "10.21.12.35/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.36/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Loki ring (memberlist) and Grafana queries.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.36/16"
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
        vlan_id      = 214
        ipv4_address = "10.21.12.36/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.37/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: remote_write from mon01/mon02, Grafana queries, VIP 10.13.11.103.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.37/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.37/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 216
        ipv4_address = "10.21.14.37/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.38/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: remote_write from mon01/mon02, Grafana queries, VIP 10.13.11.103.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.38/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.38/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 216
        ipv4_address = "10.21.14.38/24"
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
        # Internet (image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.39/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: remote_write from mon01/mon02, Grafana queries, VIP 10.13.11.103.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.39/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (S3 for Mimir blocks).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.39/16"
      },
      {
        # HA L2VNI 9216 (l2vnis.ha_mimir): Mimir memberlist/gRPC and keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 216
        ipv4_address = "10.21.14.39/24"
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
        # Internet (Debian packages, image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.40/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Grafana -> Postgres on the VIP 10.13.11.104, scrapes.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.40/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.40/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 217
        ipv4_address = "10.21.15.40/24"
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
        # Internet (Debian packages, image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.41/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Grafana -> Postgres on the VIP 10.13.11.104, scrapes.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.41/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.41/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 217
        ipv4_address = "10.21.15.41/24"
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
        # Internet (Debian packages, image pulls) via the lylat_infra gateway.
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.42/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend: Grafana -> Postgres on the VIP 10.13.11.104, scrapes.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.42/16"
      },
      {
        # Ceph public network: haproxy to the RGWs (pgBackRest WAL archive and base backups in S3).
        bridge       = "vmbr27"
        ipv4_address = "10.27.11.42/16"
      },
      {
        # HA L2VNI 9217 (l2vnis.ha_postgres): streaming replication, etcd, Patroni REST, keepalived adverts.
        bridge       = "vmbr4000"
        vlan_id      = 217
        ipv4_address = "10.21.15.42/24"
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
