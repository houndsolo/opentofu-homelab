# Fabric VM names and ordered data bridges. OOB addresses come from
# fabric.settings.management_prefix (cidrhost(prefix, node.id)) and
# management_prefix_length, shared with the leaf configuration.
fabric_vms = {
  hostname_prefix  = "vtep-" # Node fichina -> vtep-fichina.
  vm_id_offset     = 700     # Node ID 11 -> VM ID 711.
  underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"]
  # eth1 -> spine 1, eth2 -> spine 2, eth3 -> VLAN-aware access bridge.
  # eth0 management is added separately. Bridge order determines ethN bindings.
}
