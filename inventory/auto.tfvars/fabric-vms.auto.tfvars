fabric_vms = {
  hostname_prefix          = "vtep-"
  vm_id_offset             = 700
  management_prefix        = "10.20.10.0/24"
  management_cidr          = 16
  default_underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"]
}
