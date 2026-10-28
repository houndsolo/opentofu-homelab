variable "fabric_vms" {
  description = "Naming and NIC generation for VTEP VMs. Addressing uses fabric.settings.management_*; hardware defaults use vm_config."
  type = object({
    hostname_prefix  = optional(string, "vtep-")
    vm_id_offset     = optional(number, 700)
    underlay_bridges = list(string)
  })
}
