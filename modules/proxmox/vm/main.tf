resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  node_name       = var.vm.node
  vm_id           = var.vm.vm_id
  description     = "Managed by OpenTofu"
  tags            = var.vm.tags
  started         = var.vm.started
  on_boot         = true
  stop_on_destroy = true
  boot_order      = ["virtio0"]

  agent {
    enabled = var.vm_config.agent_enabled
  }

  cpu {
    cores = coalesce(var.vm.cores, var.vm_config.cpu_cores)
    type  = var.vm_config.cpu_type
  }

  memory {
    dedicated = coalesce(var.vm.memory_mb, var.vm_config.memory_mb)
  }

  disk {
    datastore_id = var.vm_config.datastore_id
    import_from  = var.vm_config.import_image
    interface    = "virtio0"
    size         = var.vm_config.disk_size_gb
    iothread     = true
  }

  dynamic "initialization" {
    for_each = var.vm_config.cloud_init ? [true] : []
    content {
      interface         = "scsi0"
      datastore_id      = coalesce(var.vm_config.cloud_init_datastore_id, var.vm_config.datastore_id)
      user_data_file_id = var.vm_config.user_data_file_id

      ip_config {
        ipv4 {
          address = var.vm.management_address
          gateway = var.vm.gateway
        }
      }
    }
  }

  network_device {
    bridge = coalesce(var.vm.bridge, var.vm_config.management_bridge)
    model  = "virtio"
  }

  dynamic "network_device" {
    for_each = var.vm.network_devices
    content {
      bridge      = network_device.value.bridge
      vlan_id     = network_device.value.vlan_id
      mac_address = network_device.value.mac_address
      model       = "virtio"
    }
  }

  serial_device {}
}
