# Shared fabric MACs

Computes MACs for both `fabric-vms` and `fabric-leaves`. It creates no resources
and needs no remote-state connection.

Inputs are `nodes`, `underlay_bridges` and `underlay_local_as_base`.
Outputs are:

- `network_devices[node]`: ordered bridge/MAC objects for VM NICs.
- `fabric_macs[node]["ethN"]`: matching VyOS interface bindings.

The management NIC is first. Extra NICs map to `eth1`, `eth2`, and so on
in bridge-list order. Decimal digits remain visible in the MAC formula.

Changing node IDs, the AS base or bridge order changes the mapping.
Review both [VM](../../../roots/fabric-vms/README.md) and
[leaf](../../../roots/fabric-leaves/README.md) plans together.
