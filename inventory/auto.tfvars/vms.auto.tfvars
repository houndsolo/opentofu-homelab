vms = {
  dns01 = {
    owner     = "services-vms"
    node      = "venom"
    vm_id     = 5301
    image     = "debian13"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
    management_address = "10.20.53.1/16"
    # No OOB default gateway is configured here.
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.1/16"
    }]
    config = {
      ssh_username = "debian"
      ssh_pubkeys  = [] # Select names from inventory/ssh_pubkeys.tf, e.g. ["laptop", "desktop"].
    }
  }
  dns02 = {
    owner     = "services-vms"
    node      = "eldarad"
    vm_id     = 5302
    image     = "debian13"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
    management_address = "10.20.53.2/16"
    # No OOB default gateway is configured here.
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.2/16"
    }]
    config = {
      ssh_username = "debian"
      ssh_pubkeys  = [] # Select names from inventory/ssh_pubkeys.tf, e.g. ["laptop", "desktop"].
    }
  }
  dhcp01 = {
    owner     = "services-vms"
    node      = "venom"
    vm_id     = 6701
    image     = "vyos"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
    management_address = "10.20.67.1/16"
  }
  dhcp02 = {
    owner     = "services-vms"
    node      = "eldarad"
    vm_id     = 6702
    image     = "vyos"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
    management_address = "10.20.67.2/16"
  }
  lab01 = {
    owner     = "workloads"
    node      = "venom"
    vm_id     = 401
    image     = "debian13"
    cores     = 4
    memory_mb = 4096
    bridge    = "vmbr0"
  }
}
