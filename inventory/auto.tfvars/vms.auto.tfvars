vms = {
  dns01 = {
    owner     = "services-vms"
    node      = "venom"
    vm_id     = 301
    image     = "debian13"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
  }
  dhcp01 = {
    owner     = "services-vms"
    node      = "venom"
    vm_id     = 302
    image     = "vyos"
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
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
