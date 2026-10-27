# Leaf MACs

Pure calculator shared by `fabric-vms` and `fabric-leaves`; no remote state.
Format: `02:00:00:<node ID>:00:<interface number>`.

| Node | Interface | Bridge | MAC |
| --- | --- | --- | --- |
| 11 | eth1 | vmbr4001 | 02:00:00:11:00:01 |
| 11 | eth2 | vmbr4002 | 02:00:00:11:00:02 |
| 11 | eth3 | vmbr4000 | 02:00:00:11:00:03 |

Digits are decimal-looking: node 17 uses `17`, not hex `11`. Unique node IDs
must be 1..99. Up to 99 ordered bridges map to eth1 onwards; bridge numbers do
not enter the MAC calculation.

`network_devices[node]` supplies VM NICs; `fabric_macs[node]["ethN"]` supplies
matching VyOS hw-id bindings. Management eth0 is excluded. Reordering bridges
preserves each interface position's MAC but changes its bridge attachment.

When switching from bridge-derived MACs, apply `fabric-vms` first so PVE NICs
have the new MACs, then `fabric-leaves` to update VyOS hw-id bindings. Both roots
must use the same node IDs and bridge order. Inspect existing guest interface
bindings if VyOS still reports a conflict after the NIC change.
