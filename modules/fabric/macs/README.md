# Shared Proxmox leaf MACs

This pure module is called by both `roots/fabric-vms` and `roots/fabric-leaves`.
It calculates the same mapping independently in each root, without remote state.
It creates no resources.

The format is `02:00:00:<node ID>:<bridge digits split in two pairs>`:

| Node ID | Interface | Bridge | MAC |
| --- | --- | --- | --- |
| 11 | eth1 | vmbr4001 | 02:00:00:11:40:01 |
| 11 | eth2 | vmbr4002 | 02:00:00:11:40:02 |
| 11 | eth3 | vmbr4000 | 02:00:00:11:40:00 |

Octets are formatted as decimal-looking digits, not converted to hexadecimal:
node 17 uses `17`, not `11`. IDs must be unique integers in 1..99. Bridges must
be unique canonical `vmbr<number>` names in 0..9999, padded to four digits for
MAC encoding. This requested human-readable scheme is deliberately limited.
The old AS-based MAC seed is no longer used by this module.

Outputs:

- `network_devices[node]`: ordered bridge/MAC objects used by the Proxmox VM.
- `fabric_macs[node]["ethN"]`: identical MACs used for VyOS `hw-id` bindings.

The VM module creates management first. Only the additional NIC list is assigned
static MACs, so eth0/vmbr0 is untouched. eth1 onwards follows the supplied bridge
list order. Reordering bridges changes the ethN mapping but not the MAC belonging
to a node/bridge pair. Both callers include the cluster and the Greatfox leaf.
Do not independently override a VM's extra NICs without updating its bindings.

These MACs intentionally differ from the previous formula. Review VM creation
and VyOS configuration plans together when migrating existing leaves. NIC MAC
updates and guest bindings must be applied as a pair; data connectivity may be
interrupted during the change. No infrastructure is applied by this module.
