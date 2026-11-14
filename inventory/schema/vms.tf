variable "vms" {
  description = "VM definitions and overrides. owner selects the deploying root."
  type = map(object({
    image              = optional(string)
    owner              = string           # fabric-vms, services-vms or workloads.
    role               = optional(string) # services-vms only: dns, dhcp, monitoring, grafana, logging, metrics, postgres or ticketing.
    node               = optional(string)
    vm_id              = optional(number)
    management_address = optional(string)
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
      # Static IPv6 (cloud-init ip_config ipv6), e.g. fd69:5501::12:45/64. No SLAAC/DHCPv6 on these NICs.
      ipv6_address = optional(string)
      ipv6_gateway = optional(string)
    })))
  }))
  validation {
    condition = alltrue([
      for vm in values(var.vms) :
      contains(["fabric-vms", "services-vms", "workloads"], vm.owner) &&
      (vm.role == null || (vm.owner == "services-vms" && contains(["dns", "dhcp", "monitoring", "grafana", "logging", "metrics", "postgres", "ticketing", "netbox", "valkey", "proxy"], vm.role)))
    ])
    error_message = "owner must be fabric-vms, services-vms or workloads; role (dns, dhcp, monitoring, grafana, logging, metrics, postgres, ticketing, netbox, valkey or proxy) applies only to services-vms."
  }

  validation {
    condition = alltrue([
      for vm in values(var.vms) : vm.ha == null || try(
        vm.owner == "services-vms" && vm.node != null &&
        (vm.ha.group == null || can(regex("^[a-z][a-z0-9-]{0,40}$", vm.ha.group))) &&
        contains(["started", "stopped", "disabled", "ignored"], vm.ha.state) &&
        vm.ha.max_restart >= 0 && vm.ha.max_restart <= 10 &&
        vm.ha.max_relocate >= 0 && vm.ha.max_relocate <= 10, false
      )
    ])
    error_message = "ha applies only to services-vms VMs with a node; group (optional) is lowercase [a-z][a-z0-9-], state started|stopped|disabled|ignored, max_restart/max_relocate 0..10."
  }
  validation {
    condition = alltrue([
      for vm in values(var.vms) :
      vm.owner == "fabric-vms" || (vm.node != null && vm.vm_id != null)
    ])
    error_message = "Service and workload VMs require node and vm_id. Generated fabric VM overrides may omit them."
  }
  validation {
    condition = alltrue([
      for vm in values(var.vms) :
      vm.role != "dns" || length([
        for nic in(vm.network_devices == null ? [] : vm.network_devices) : nic if nic.ipv4_address != null && nic.ipv4_gateway != null
      ]) == 1
    ])
    error_message = "DNS VMs need exactly one network device with ipv4_address and ipv4_gateway; BIND listens on it (other NICs, such as the HA L2VNI, have no gateway)."
  }
  validation {
    condition = length([for vm in values(var.vms) : vm if vm.role == "dhcp"]) == 0 || (
      length([for vm in values(var.vms) : vm if vm.role == "dhcp"]) == 2 &&
      length(distinct([for vm in values(var.vms) : vm.vm_id if vm.role == "dhcp"])) == 2
    )
    error_message = "Define either no DHCP VMs or exactly two DHCP VMs with distinct VM IDs for the HA pair."
  }
}
