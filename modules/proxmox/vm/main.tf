resource "proxmox_virtual_environment_vm" "this" {
  name            = var.name
  node_name       = var.vm.node
  vm_id           = var.vm.vm_id
  description     = local.config.description
  tags            = local.config.tags
  started         = local.config.started
  keyboard_layout = local.config.keyboard_layout
  # HA VMs migrate (HA-aware in the provider) rather than being replaced if node_name ever
  # changes. node_name itself is ignored after creation (lifecycle below).
  migrate         = local.config.migrate || var.vm.ha != null
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
      interface           = local.config.cloud_init_interface
      datastore_id        = coalesce(local.config.cloud_init_datastore_id, local.config.datastore_id)
      user_data_file_id   = local.config.user_data_file_id
      upgrade             = false
      vendor_data_file_id = var.vendor_data_file_id

      ip_config {
        ipv4 {
          address = var.vm.management_address
          gateway = var.vm.gateway
        }
      }

      # One ip_config per addressed NIC, in NIC order (Proxmox maps ipconfigN to netN by position, so a NIC
      # without any address must not sit before addressed ones).
      dynamic "ip_config" {
        for_each = var.configure_data_ips ? [
          for device in var.vm.network_devices :
          device if device.ipv4_address != null || device.ipv6_address != null
        ] : []
        content {
          dynamic "ipv4" {
            for_each = ip_config.value.ipv4_address != null ? [true] : []
            content {
              address = ip_config.value.ipv4_address
              gateway = ip_config.value.ipv4_gateway
            }
          }
          dynamic "ipv6" {
            for_each = ip_config.value.ipv6_address != null ? [true] : []
            content {
              address = ip_config.value.ipv6_address
              gateway = ip_config.value.ipv6_gateway
            }
          }
        }
      }

      # Only when set: roots that don't set dns_servers/dns_domain see no change.
      dynamic "dns" {
        for_each = local.config.dns_servers != null || local.config.dns_domain != null ? [true] : []
        content {
          domain  = local.config.dns_domain
          servers = local.config.dns_servers
        }
      }

      dynamic "user_account" {
        for_each = length(var.vm.config.ssh_pubkeys) > 0 ? [true] : []
        content {
          username = var.vm.config.ssh_username
          keys     = [for name in var.vm.config.ssh_pubkeys : var.ssh_pubkeys[name]]
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
    # var.vm.node only places a new VM. Afterwards the VM may run anywhere (Proxmox HA recovery,
    # load balancing, maintenance, a manual migration) without a plan diff; changing `node` in
    # the inventory doesn't move an existing VM either (migrate it in Proxmox).
    ignore_changes = [node_name]

    precondition {
      condition     = length(var.vm.config.ssh_pubkeys) == 0 || (local.config.cloud_init && local.config.user_data_file_id == null)
      error_message = "config.ssh_pubkeys requires cloud-init enabled and no custom user_data_file_id."
    }
  }
}
