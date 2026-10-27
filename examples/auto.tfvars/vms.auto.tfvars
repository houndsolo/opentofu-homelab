# Edit inventory/auto.tfvars/vms.auto.tfvars using these entries as a guide.
# Node names must match your PVE hosts. VM IDs and IPs must be unique.
# One vms map contains all owners; merge entries into your existing map.
vms = {
  dns01 = {
    owner              = "services-vms-dns"
    node               = "fichina"
    vm_id              = 5301
    image              = "debian13"      # Key in vm_images.
    management_address = "10.20.53.1/16" # eth0 on vmbr0; no OOB gateway.
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.1/16" # eth1; PVE applies the VLAN tag.
      ipv4_gateway = "10.8.0.1"     # Optional data default route for off-subnet access.
    }]
    config = {
      ssh_username = "debian"
      ssh_pubkeys  = ["laptop", "desktop"] # Names in inventory/ssh_pubkeys.tf.
      cpu_cores    = 2
      memory_mb    = 1024
    }
  }
  dns02 = {
    owner              = "services-vms-dns"
    node               = "macbeth"
    vm_id              = 5302
    image              = "debian13"
    management_address = "10.20.53.2/16"
    network_devices = [{
      bridge       = "vmbr4000"
      vlan_id      = 8
      ipv4_address = "10.8.53.2/16"
      ipv4_gateway = "10.8.0.1"
    }]
    config = {
      ssh_username = "debian"
      ssh_pubkeys  = ["laptop", "desktop"]
      cpu_cores    = 2
      memory_mb    = 1024
    }
  }

  # Exactly two DHCP VMs (or none). Lower VM ID is primary; higher is secondary.
  # Data NICs come from DHCP-enabled VNIs, and VyOS assigns their IPs.
  # Do not add network_devices or per-VM HA roles here.
  dhcp01 = {
    owner              = "services-vms-dhcp"
    node               = "fichina"
    vm_id              = 6701
    image              = "vyos"
    management_address = "10.20.67.1/16"
  }
  dhcp02 = {
    owner              = "services-vms-dhcp"
    node               = "macbeth"
    vm_id              = 6702
    image              = "vyos"
    management_address = "10.20.67.2/16"
  }

  # Optional ordinary VM: managed by roots/workloads, not services-vms.
  app01 = {
    owner              = "workloads"
    node               = "fichina"
    vm_id              = 8001
    image              = "debian13"
    management_address = "10.20.80.1/16"
    config = {
      ssh_username = "debian"
      ssh_pubkeys  = ["laptop"]
      disk_size_gb = 20
    }
  }
}
