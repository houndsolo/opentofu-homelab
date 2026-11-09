vms = {
  dns01 = {
    owner              = "services-vms"
    role               = "dns"
    node               = "venom"
    vm_id              = 5301
    image              = "debian13"
    management_address = "10.20.53.1/16"
    # No OOB default gateway is configured here.
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.1/16"
      ipv4_gateway = "10.8.0.5"
    }]
    config = {
      tags         = ["debian", "dns", "opentofu"]
      cpu_cores    = 2
      memory_mb    = 3072
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  dns02 = {
    owner              = "services-vms"
    role               = "dns"
    node               = "eldarad"
    vm_id              = 5302
    image              = "debian13"
    management_address = "10.20.53.2/16"
    # No OOB default gateway is configured here.
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.2/16"
      ipv4_gateway = "10.8.0.5"
    }]
    config = {
      tags         = ["debian", "dns", "opentofu"]
      cpu_cores    = 2
      memory_mb    = 3072
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  dhcp01 = {
    owner              = "services-vms"
    role               = "dhcp"
    node               = "venom"
    vm_id              = 6701
    image              = "vyos"
    management_address = "10.20.67.1/16"
    config = {
      tags      = ["dhcp", "opentofu", "vyos"]
      cpu_cores = 2
      memory_mb = 2048
    }
  }
  dhcp02 = {
    owner              = "services-vms"
    role               = "dhcp"
    node               = "eldarad"
    vm_id              = 6702
    image              = "vyos"
    management_address = "10.20.67.2/16"
    config = {
      tags      = ["dhcp", "opentofu", "vyos"]
      cpu_cores = 2
      memory_mb = 2048
    }
  }
  mon01 = {
    owner              = "services-vms"
    role               = "monitoring"
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
    ]
    config = {
      tags         = ["debian", "monitoring", "opentofu"]
      cpu_cores    = 4
      memory_mb    = 8192
      disk_size_gb = 200 # Prometheus TSDB + InfluxDB + Grafana Postgres.
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  graf01 = {
    owner              = "services-vms"
    role               = "grafana"
    node               = "venom"
    vm_id              = 1131
    image              = "debian13"
    management_address = "10.20.11.31/16"
    # No OOB default gateway is configured here.
    network_devices = [
      {
        bridge       = "vmbr4000"
        vlan_id      = 2
        ipv4_address = "10.2.11.31/16"
        ipv4_gateway = "10.2.0.5"
      },
      {
        # Isolated monitoring backend (lylat_monitor VRF): mon01 + Grafana HA.
        bridge       = "vmbr4000"
        vlan_id      = 13
        ipv4_address = "10.13.11.31/16"
      },
    ]
    config = {
      tags         = ["debian", "monitoring", "opentofu"]
      cpu_cores    = 2
      memory_mb    = 4096
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  graf02 = {
    owner              = "services-vms"
    role               = "grafana"
    node               = "eldarad"
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
    ]
    config = {
      tags         = ["debian", "monitoring", "opentofu"]
      cpu_cores    = 2
      memory_mb    = 4096
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]
    }
  }
  lab01 = {
    owner = "workloads"
    node  = "venom"
    vm_id = 401
    image = "debian13"
    config = {
      tags      = ["debian", "lab", "opentofu"]
      cpu_cores = 4
      memory_mb = 4096
    }
  }
}
