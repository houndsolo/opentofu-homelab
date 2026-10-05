variable "pve_leaf" {
  description = "Proxmox leaf VM inventory, naming/address defaults and shared resource settings."
  type = object({
    proxmox = object({
      endpoint     = string
      insecure     = optional(bool, false)
      ssh_username = optional(string, "root")
      ssh_agent    = optional(bool, true)
    })
    defaults = object({
      hostname_prefix          = optional(string, "vtep-")
      vm_id_offset             = optional(number, 700)
      management_prefix        = string
      management_cidr          = number
      underlay_local_as_base   = optional(number, 700)
      default_underlay_bridges = list(string)
    })
    vm_config = object({
      datastore_id            = string
      import_image            = string
      description             = optional(string, "managed by opentofu")
      tags                    = optional(list(string), ["opentofu", "debian", "vyos", "vxlan"])
      started                 = optional(bool, false)
      keyboard_layout         = optional(string, "en-us")
      migrate                 = optional(bool, false)
      on_boot                 = optional(bool, true)
      reboot                  = optional(bool, false)
      stop_on_destroy         = optional(bool, true)
      agent_enabled           = optional(bool, true)
      boot_order              = optional(list(string), ["virtio0"])
      disk_interface          = optional(string, "virtio0")
      disk_iothread           = optional(bool, true)
      disk_size_gb            = optional(number, 10)
      cloud_init              = optional(bool, true)
      cloud_init_interface    = optional(string, "scsi0")
      cloud_init_datastore_id = optional(string)
      user_data_file_id       = optional(string)
      management_bridge       = optional(string, "vmbr0")
      network_model           = optional(string, "virtio")
      network_disconnected    = optional(bool, false)
      management_mtu          = optional(number, 0)
      underlay_mtu            = optional(number, 1)
      serial_device           = optional(bool, true)
      cpu_cores               = optional(number, 4)
      cpu_type                = optional(string, "x86-64-v2-AES")
      cpu_flags               = optional(list(string), [])
      cpu_hotplugged          = optional(number, 0)
      cpu_limit               = optional(number, 0)
      cpu_numa                = optional(bool, false)
      cpu_sockets             = optional(number, 1)
      cpu_units               = optional(number, 1024)
      memory_mb               = optional(number, 4096)
      memory_floating_mb      = optional(number, 0)
      memory_keep_hugepages   = optional(bool, false)
      memory_shared_mb        = optional(number, 0)
      operating_system_type   = optional(string, "l26")
      vga_memory              = optional(number, 16)
      vga_type                = optional(string, "std")
      timeout_clone           = optional(number, 1800)
      timeout_create          = optional(number, 1800)
      timeout_migrate         = optional(number, 1800)
      timeout_reboot          = optional(number, 1800)
      timeout_shutdown_vm     = optional(number, 1800)
      timeout_start_vm        = optional(number, 1800)
      timeout_stop_vm         = optional(number, 300)
    })
    leaves = map(object({
      id                 = number
      hypervisor_node    = string
      is_vm              = optional(bool, true)
      hostname           = optional(string)
      vm_id              = optional(number)
      management_address = optional(string)
      gateway            = optional(string)
      started            = optional(bool)
      tags               = optional(list(string))
      cores              = optional(number)
      memory_mb          = optional(number)
      management_bridge  = optional(string)
      underlay_bridges   = optional(list(string))
      fabric_macs        = optional(map(string), {})
      network_devices = optional(list(object({
        bridge       = string
        vlan_id      = optional(number)
        mac_address  = optional(string)
        model        = optional(string)
        mtu          = optional(number)
        disconnected = optional(bool)
      })))
    }))
  })

  validation {
    condition = length(distinct([
      for leaf in values(var.pve_leaf.leaves) : coalesce(leaf.vm_id, leaf.id + var.pve_leaf.defaults.vm_id_offset)
      if leaf.is_vm
    ])) == length([for leaf in values(var.pve_leaf.leaves) : leaf if leaf.is_vm])
    error_message = "Each managed leaf must have a unique VM ID."
  }
}
