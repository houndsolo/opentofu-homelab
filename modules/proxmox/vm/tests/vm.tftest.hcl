mock_provider "proxmox" {}

variables {
  name = "leaf01"
  vm = {
    node               = "venom"
    vm_id              = 711
    management_address = "10.20.7.111/24"
    network_devices    = [{ bridge = "vmbr4001" }, { bridge = "vmbr4002", vlan_id = 22 }]
  }
  vm_config = {
    datastore_id      = "ceph_rbd"
    import_image      = "cephfs:import/vyos.qcow2"
    cpu_cores         = 4
    memory_mb         = 4096
    user_data_file_id = "cephfs:snippets/vyos_api.yml"
  }
}

run "leaf_plan" {
  command = plan
  assert {
    condition     = length(proxmox_virtual_environment_vm.this.network_device) == 3 && proxmox_virtual_environment_vm.this.network_device[2].vlan_id == 22
    error_message = "Leaf NIC order and VLAN must be preserved."
  }
  assert {
    condition     = proxmox_virtual_environment_vm.this.initialization[0].ip_config[0].ipv4[0].address == "10.20.7.111/24" && proxmox_virtual_environment_vm.this.cpu[0].cores == 4
    error_message = "Leaf addressing and shared CPU defaults must be passed to the provider."
  }
}

run "general_vm_plan" {
  command = plan
  variables {
    name      = "app01"
    vm        = { node = "venom", vm_id = 401, cores = 2, memory_mb = 2048, bridge = "vmbr10", started = false }
    vm_config = { datastore_id = "ceph_rbd", import_image = "cephfs:import/debian.qcow2", cloud_init = false, agent_enabled = false }
  }
  assert {
    condition     = length(proxmox_virtual_environment_vm.this.initialization) == 0 && length(proxmox_virtual_environment_vm.this.network_device) == 1
    error_message = "General VM must support disabling cloud-init and omit leaf NICs."
  }
  assert {
    condition     = proxmox_virtual_environment_vm.this.cpu[0].cores == 2 && proxmox_virtual_environment_vm.this.memory[0].dedicated == 2048 && proxmox_virtual_environment_vm.this.network_device[0].bridge == "vmbr10" && !proxmox_virtual_environment_vm.this.started
    error_message = "Per-VM hardware, bridge and startup overrides must be respected."
  }
}
