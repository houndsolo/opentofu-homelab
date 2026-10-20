# Fabric VM names, OOB addresses and ordered data bridges.
# Keep addressing consistent with fabric.settings.management_*.
fabric_vms = {
  hostname_prefix          = "vtep-"         # Node fichina -> vtep-fichina.
  vm_id_offset             = 700             # Node ID 11 -> VM ID 711.
  management_prefix        = "10.20.10.0/24" # cidrhost(prefix, node.id).
  management_prefix_length = 24              # Prefix length applied in guest.
  underlay_bridges         = ["vmbr4001", "vmbr4002", "vmbr4000"]
  # eth1 -> spine 1, eth2 -> spine 2, eth3 -> VLAN-aware access bridge.
  # eth0 management is added separately. Bridge order determines ethN bindings.
}
