variable "vms" {
  description = "DHCP VM IDs: 6701 -> peer octet 01, 6702 -> 02; IDs keep MACs stable."
  type        = map(object({ vm_id = number }))
  validation {
    condition = alltrue([
      for vm in values(var.vms) : vm.vm_id >= 6701 && vm.vm_id <= 6799 && vm.vm_id == floor(vm.vm_id)
    ]) && length(distinct([for vm in values(var.vms) : vm.vm_id])) == length(var.vms)
    error_message = "DHCP VM IDs must be unique integers in 6701..6799 for the 67:peer:VLAN MAC format."
  }
}

variable "bridge" {
  description = "VLAN-aware Proxmox bridge carrying the DHCP data VLANs."
  type        = string
  default     = "vmbr4000"
}

variable "ha_vlan_id" {
  description = "VLAN of the Kea HA L2VNI (l2vnis.ha_dhcp.vlan_id). Adds one NIC after the data NICs; null = none."
  type        = number
  default     = null
  validation {
    condition     = var.ha_vlan_id == null || try(var.ha_vlan_id >= 1 && var.ha_vlan_id <= 4094 && var.ha_vlan_id == floor(var.ha_vlan_id), false)
    error_message = "ha_vlan_id must be an integer VLAN 1..4094."
  }
}
