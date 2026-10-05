resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  node_name       = var.vm.node
  vm_id           = var.vm.vm_id
  description     = var.vm_config.description
  tags            = var.vm.tags != null ? var.vm.tags : var.vm_config.tags
  started         = coalesce(var.vm.started, var.vm_config.started)
  keyboard_layout = var.vm_config.keyboard_layout
  migrate         = var.vm_config.migrate
  on_boot         = var.vm_config.on_boot
  reboot          = var.vm_config.reboot
  stop_on_destroy = var.vm_config.stop_on_destroy
  boot_order      = var.vm_config.boot_order

  agent {
    enabled = var.vm_config.agent_enabled
  }

  cpu {
    cores      = coalesce(var.vm.cores, var.vm_config.cpu_cores)
    type       = var.vm_config.cpu_type
    flags      = var.vm_config.cpu_flags
    hotplugged = var.vm_config.cpu_hotplugged
    limit      = var.vm_config.cpu_limit
    numa       = var.vm_config.cpu_numa
    sockets    = var.vm_config.cpu_sockets
    units      = var.vm_config.cpu_units
  }

  memory {
    dedicated      = coalesce(var.vm.memory_mb, var.vm_config.memory_mb)
    floating       = var.vm_config.memory_floating_mb
    keep_hugepages = var.vm_config.memory_keep_hugepages
    shared         = var.vm_config.memory_shared_mb
  }

  disk {
    datastore_id = var.vm_config.datastore_id
    import_from  = var.vm_config.import_image
    interface    = var.vm_config.disk_interface
    iothread     = var.vm_config.disk_iothread
    size         = var.vm_config.disk_size_gb
  }

  dynamic "initialization" {
    for_each = var.vm_config.cloud_init ? [true] : []
    content {
      interface         = var.vm_config.cloud_init_interface
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
    disconnected = var.vm_config.network_disconnected
    bridge       = coalesce(var.vm.bridge, var.vm_config.management_bridge)
    model        = var.vm_config.network_model
    mtu          = var.vm_config.management_mtu
  }

  dynamic "network_device" {
    for_each = var.vm.network_devices
    content {
      disconnected = coalesce(network_device.value.disconnected, var.vm_config.network_disconnected)
      bridge       = network_device.value.bridge
      vlan_id      = network_device.value.vlan_id
      mac_address  = network_device.value.mac_address
      model        = coalesce(network_device.value.model, var.vm_config.network_model)
      mtu          = coalesce(network_device.value.mtu, var.vm_config.underlay_mtu)
    }
  }

  dynamic "serial_device" {
    for_each = var.vm_config.serial_device ? [true] : []
    content {}
  }

  operating_system {
    type = var.vm_config.operating_system_type
  }

  vga {
    memory = var.vm_config.vga_memory
    type   = var.vm_config.vga_type
  }

  timeout_clone       = var.vm_config.timeout_clone
  timeout_create      = var.vm_config.timeout_create
  timeout_migrate     = var.vm_config.timeout_migrate
  timeout_reboot      = var.vm_config.timeout_reboot
  timeout_shutdown_vm = var.vm_config.timeout_shutdown_vm
  timeout_start_vm    = var.vm_config.timeout_start_vm
  timeout_stop_vm     = var.vm_config.timeout_stop_vm

  lifecycle {
    # Match the reference: do not reconcile the provider-generated user account.
    ignore_changes = [initialization[0].user_account]
  }
}
