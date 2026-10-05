variable "name" {
  description = "VM name, usually the caller's for_each key."
  type        = string
}

variable "vm" {
  description = "Placement and per-VM overrides. Addresses include their CIDR prefix."
  type = object({
    node               = string
    vm_id              = number
    cores              = optional(number)
    memory_mb          = optional(number)
    bridge             = optional(string)
    started            = optional(bool, true)
    tags               = optional(list(string), ["opentofu"])
    management_address = optional(string, "dhcp")
    gateway            = optional(string)
    network_devices = optional(list(object({
      bridge      = string
      vlan_id     = optional(number)
      mac_address = optional(string)
    })), [])
  })
}

variable "vm_config" {
  description = "Shared image and hardware defaults; use separate values for leaves and other VMs."
  type = object({
    datastore_id            = string
    import_image            = string
    disk_size_gb            = optional(number, 10)
    cpu_cores               = optional(number, 2)
    cpu_type                = optional(string, "x86-64-v2-AES")
    memory_mb               = optional(number, 2048)
    management_bridge       = optional(string, "vmbr0")
    cloud_init_datastore_id = optional(string)
    user_data_file_id       = optional(string)
    cloud_init              = optional(bool, true)
    agent_enabled           = optional(bool, true)
  })
}
