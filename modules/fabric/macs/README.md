# Leaf MACs

Pure calculator shared by `fabric-vms` and `fabric-leaves`; no remote state.
Format: `02:00:00:<node ID>:<four bridge digits split into pairs>`.

| Node | Interface | Bridge | MAC |
| --- | --- | --- | --- |
| 11 | eth1 | vmbr4001 | 02:00:00:11:40:01 |
| 11 | eth2 | vmbr4002 | 02:00:00:11:40:02 |
| 11 | eth3 | vmbr4000 | 02:00:00:11:40:00 |

Digits are decimal-looking: node 17 uses `17`, not hex `11`. Unique node IDs
must be 1..99; bridge numbers 0..9999. Bridge list order determines ethN.

`network_devices[node]` supplies VM NICs; `fabric_macs[node]["ethN"]` supplies
matching VyOS hw-id bindings. Management eth0 is excluded. Apply changes to VM
NICs and guest bindings together. Reordering bridges changes interface indices;
changing node/bridge IDs changes MACs.
