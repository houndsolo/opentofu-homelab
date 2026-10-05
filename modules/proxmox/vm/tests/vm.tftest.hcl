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

run "resource_settings_are_configurable" {
  command = plan
  variables {
    vm = { node = "venom", vm_id = 711, tags = [] }
    vm_config = {
      datastore_id            = "local-lvm"
      import_image            = "local:import/test.qcow2"
      description             = "Custom VM"
      started                 = true
      keyboard_layout         = "de"
      migrate                 = true
      on_boot                 = false
      reboot                  = true
      stop_on_destroy         = false
      boot_order              = ["scsi0"]
      disk_interface          = "scsi0"
      disk_iothread           = false
      disk_size_gb            = 32
      cloud_init_interface    = "ide2"
      cloud_init_datastore_id = "local"
      network_model           = "e1000"
      network_disconnected    = true
      management_mtu          = 1500
      serial_device           = false
      cpu_cores               = 8
      cpu_type                = "host"
      cpu_flags               = ["+aes"]
      cpu_sockets             = 2
      cpu_units               = 2048
      memory_mb               = 8192
      memory_floating_mb      = 4096
      vga_type                = "serial0"
      timeout_create          = 900
      timeout_stop_vm         = 120
    }
  }
  assert {
    condition = (
      proxmox_virtual_environment_vm.this.description == "Custom VM" &&
      proxmox_virtual_environment_vm.this.started &&
      !proxmox_virtual_environment_vm.this.on_boot &&
      proxmox_virtual_environment_vm.this.keyboard_layout == "de" &&
      length(proxmox_virtual_environment_vm.this.tags) == 0
    )
    error_message = "Shared lifecycle settings and an explicit empty tag list must be respected."
  }
  assert {
    condition = (
      proxmox_virtual_environment_vm.this.disk[0].interface == "scsi0" &&
      proxmox_virtual_environment_vm.this.disk[0].size == 32 &&
      !proxmox_virtual_environment_vm.this.disk[0].iothread &&
      proxmox_virtual_environment_vm.this.initialization[0].interface == "ide2" &&
      proxmox_virtual_environment_vm.this.initialization[0].datastore_id == "local"
    )
    error_message = "Disk and cloud-init settings must come from vm_config."
  }
  assert {
    condition = (
      proxmox_virtual_environment_vm.this.cpu[0].cores == 8 &&
      proxmox_virtual_environment_vm.this.cpu[0].type == "host" &&
      proxmox_virtual_environment_vm.this.cpu[0].sockets == 2 &&
      proxmox_virtual_environment_vm.this.memory[0].floating == 4096 &&
      proxmox_virtual_environment_vm.this.network_device[0].model == "e1000" &&
      proxmox_virtual_environment_vm.this.network_device[0].disconnected &&
      length(proxmox_virtual_environment_vm.this.serial_device) == 0 &&
      proxmox_virtual_environment_vm.this.timeout_create == 900 &&
      proxmox_virtual_environment_vm.this.timeout_stop_vm == 120
    )
    error_message = "Hardware, network and timeout settings must be templated."
  }
}
