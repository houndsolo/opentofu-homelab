resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  node_name       = var.vm.node
  vm_id           = var.vm.vm_id
  description     = local.config.description
  tags            = local.config.tags
  started         = local.config.started
  keyboard_layout = local.config.keyboard_layout
  migrate         = local.config.migrate
  on_boot         = local.config.on_boot
  reboot          = local.config.reboot
  stop_on_destroy = local.config.stop_on_destroy
  boot_order      = local.config.boot_order

  agent {
    enabled = local.config.agent_enabled
  }

  cpu {
    cores      = local.config.cpu_cores
    type       = local.config.cpu_type
    flags      = local.config.cpu_flags
    hotplugged = local.config.cpu_hotplugged
    limit      = local.config.cpu_limit
    numa       = local.config.cpu_numa
    sockets    = local.config.cpu_sockets
    units      = local.config.cpu_units
  }

  memory {
    dedicated      = local.config.memory_mb
    floating       = local.config.memory_floating_mb
    keep_hugepages = local.config.memory_keep_hugepages
    shared         = local.config.memory_shared_mb
  }

  disk {
    datastore_id = local.config.datastore_id
    import_from  = local.config.import_image
    interface    = local.config.disk_interface
    iothread     = local.config.disk_iothread
    size         = local.config.disk_size_gb
  }

  dynamic "initialization" {
    for_each = local.config.cloud_init ? [true] : []
    content {
      interface         = local.config.cloud_init_interface
      datastore_id      = coalesce(local.config.cloud_init_datastore_id, local.config.datastore_id)
      user_data_file_id = local.config.user_data_file_id

      ip_config {
        ipv4 {
          address = var.vm.management_address
          gateway = var.vm.gateway
        }
      }
    }
  }

  network_device {
    disconnected = local.config.network_disconnected
    bridge       = local.config.management_bridge
    model        = local.config.network_model
    mtu          = local.config.management_mtu
  }

  dynamic "network_device" {
    for_each = var.vm.network_devices
    content {
      disconnected = coalesce(network_device.value.disconnected, local.config.network_disconnected)
      bridge       = network_device.value.bridge
      vlan_id      = network_device.value.vlan_id
      mac_address  = network_device.value.mac_address
      model        = coalesce(network_device.value.model, local.config.network_model)
      mtu          = coalesce(network_device.value.mtu, local.config.underlay_mtu)
    }
  }

  dynamic "serial_device" {
    for_each = local.config.serial_device ? [true] : []
    content {}
  }

  operating_system {
    type = local.config.operating_system_type
  }

  vga {
    memory = local.config.vga_memory
    type   = local.config.vga_type
  }

  timeout_clone       = local.config.timeout_clone
  timeout_create      = local.config.timeout_create
  timeout_migrate     = local.config.timeout_migrate
  timeout_reboot      = local.config.timeout_reboot
  timeout_shutdown_vm = local.config.timeout_shutdown_vm
  timeout_start_vm    = local.config.timeout_start_vm
  timeout_stop_vm     = local.config.timeout_stop_vm

  lifecycle {
    # Match the reference: do not reconcile the provider-generated user account.
    ignore_changes = [initialization[0].user_account]
  }
}
