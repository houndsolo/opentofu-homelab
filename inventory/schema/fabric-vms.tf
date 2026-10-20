variable "fabric_vms" {
  description = "Naming, addressing and NIC generation for VTEP VMs. Hardware defaults use vm_config."
  type = object({
    hostname_prefix          = optional(string, "vtep-")
    vm_id_offset             = optional(number, 700)
    management_prefix        = string
    management_cidr          = number
    default_underlay_bridges = list(string)
  })
}
