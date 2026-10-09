vms = {
  dns01 = {
    owner     = "services-vms"
    node      = "pve01"
    vm_id     = 301
    cores     = 2
    memory_mb = 2048
    bridge    = "vmbr0"
  }
  lab01 = {
    owner     = "workloads"
    node      = "pve01"
    vm_id     = 401
    cores     = 4
    memory_mb = 4096
    bridge    = "vmbr0"
  }
}
