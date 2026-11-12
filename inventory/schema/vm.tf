variable "vm" {
  description = "Placement, management addressing and ordered NICs for one VM."
  type = object({
    image              = optional(string)
    node               = string
    vm_id              = number
    management_address = optional(string, "dhcp")
    gateway            = optional(string)
    # Proxmox VE HA (services-vms): the VM becomes an HA resource that the cluster restarts on another
    # node when its node dies, on any node HA picks (no home node). With a `group`, never on a node
    # with another VM of that group (negative resource-affinity rule); `ha = {}` is a plain HA
    # resource with no placement rule. Disks must be on shared storage
    # (ceph_rbd). Stopping it by hand: set state = "stopped" here, or
    # `ha-manager set vm:<id> --state stopped` (the next apply restores this value).
    ha = optional(object({
      group        = optional(string)            # anti-affinity set, e.g. "postgres"; null = no rule
      state        = optional(string, "started") # started | stopped | disabled | ignored
      max_restart  = optional(number, 1)         # restart attempts on the same node
      max_relocate = optional(number, 1)         # relocation attempts to other nodes
    }))
    config = optional(object({
      ssh_pubkeys             = optional(list(string), [])
      ssh_username            = optional(string, "debian")
      datastore_id            = optional(string)
      import_image            = optional(string)
      description             = optional(string)
      tags                    = optional(list(string))
      started                 = optional(bool)
      keyboard_layout         = optional(string)
      migrate                 = optional(bool)
      on_boot                 = optional(bool)
      reboot                  = optional(bool)
      stop_on_destroy         = optional(bool)
      agent_enabled           = optional(bool)
      boot_order              = optional(list(string))
      disk_interface          = optional(string)
      disk_iothread           = optional(bool)
      disk_size_gb            = optional(number)
      cloud_init              = optional(bool)
      cloud_init_interface    = optional(string)
      cloud_init_datastore_id = optional(string)
      user_data_file_id       = optional(string)
      dns_servers             = optional(list(string))
      dns_domain              = optional(string)
      management_bridge       = optional(string)
      network_model           = optional(string)
      network_disconnected    = optional(bool)
      management_mtu          = optional(number)
      underlay_mtu            = optional(number)
      serial_device           = optional(bool)
      cpu_cores               = optional(number)
      cpu_type                = optional(string)
      cpu_flags               = optional(list(string))
      cpu_hotplugged          = optional(number)
      cpu_limit               = optional(number)
      cpu_numa                = optional(bool)
      cpu_sockets             = optional(number)
      cpu_units               = optional(number)
      memory_mb               = optional(number)
      memory_floating_mb      = optional(number)
      memory_keep_hugepages   = optional(bool)
      memory_shared_mb        = optional(number)
      operating_system_type   = optional(string)
      vga_memory              = optional(number)
      vga_type                = optional(string)
      timeout_clone           = optional(number)
      timeout_create          = optional(number)
      timeout_migrate         = optional(number)
      timeout_reboot          = optional(number)
      timeout_shutdown_vm     = optional(number)
      timeout_start_vm        = optional(number)
      timeout_stop_vm         = optional(number)
    }), {})
    network_devices = optional(list(object({
      bridge       = string
      vlan_id      = optional(number)
      mac_address  = optional(string)
      model        = optional(string)
      mtu          = optional(number)
      disconnected = optional(bool)
      ipv4_address = optional(string)
      ipv4_gateway = optional(string)
    })), [])
  })
}
