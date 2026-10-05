# Shared Proxmox interface inventory

This pure OpenTofu module owns the existing stable MAC calculation. Both
`roots/fabric-vms` and `roots/fabric-leaves` call it with the same shared node IDs,
underlay bridge list and AS base from the inventory. It creates no resources and
requires no remote-state dependency between the roots.

Outputs:

- `network_devices[node]`: ordered bridge/MAC objects for VM creation.
- `fabric_macs[node]["ethN"]`: the corresponding VyOS interface MACs.

The management NIC is created first by the VM module. Additional NICs therefore
map to `eth1`, `eth2`, etc. The list order is preserved, including when there are
more than nine NICs; it is not reconstructed by sorting interface names.

For node `fichina`, ID `11`, AS base `700`, and the three default bridges:

| Guest interface | VM bridge | MAC |
| --- | --- | --- |
| eth1 | vmbr4001 | 02:07:11:00:11:01 |
| eth2 | vmbr4002 | 02:07:11:00:11:02 |
| eth3 | vmbr4000 | 02:07:11:00:11:03 |

The decimal zero-padded reference formula is preserved, so existing VM MACs do
not change. Keep IDs/AS values within the four-digit format and interface indexes
within two digits. Changing node IDs, AS base or bridge order changes the shared
mapping; review both VM creation and VyOS configuration plans together.
