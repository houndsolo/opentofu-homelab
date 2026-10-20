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
