# Shared DHCP data-interface MACs

Both `roots/services-vms` and `roots/services-config` call this pure module with
the same DHCP VM inventory and the VLANs of L2VNIs having a `dhcp` block. No
remote state is needed. Management is not part of the mapping.

Format: `02:00:00:67:<peer>:<VLAN>`, with decimal-looking two-digit octets.
The peer comes from `vm_id % 100`: VM 6701 uses 01, VM 6702 uses 02. This does
not depend on map iteration order, VM hostname or how many DHCP VMs exist.
VLANs are sorted numerically and mapped to eth1 onwards.

With VLANs 2, 6, 8, 9, 10 and 12:

| Interface | VLAN | dhcp01 (6701) | dhcp02 (6702) |
| --- | --- | --- | --- |
| eth1 | 2 | 02:00:00:67:01:02 | 02:00:00:67:02:02 |
| eth2 | 6 | 02:00:00:67:01:06 | 02:00:00:67:02:06 |
| eth3 | 8 | 02:00:00:67:01:08 | 02:00:00:67:02:08 |
| eth4 | 9 | 02:00:00:67:01:09 | 02:00:00:67:02:09 |
| eth5 | 10 | 02:00:00:67:01:10 | 02:00:00:67:02:10 |
| eth6 | 12 | 02:00:00:67:01:12 | 02:00:00:67:02:12 |

`network_devices[vm]` feeds the Proxmox NIC definitions. `fabric_macs[vm]` feeds
VyOS commands such as:

```text
set interfaces ethernet eth3 hw-id 02:00:00:67:01:08
```

The module assigns no IP configuration. eth0/vmbr0 keeps its Proxmox-generated
MAC and existing management configuration. The requested format supports unique
VM IDs 6701..6799 and unique VLAN IDs 1..99; larger VLAN IDs require a different
format and fail validation rather than producing invalid/duplicate MACs.
Adding a lower-numbered VLAN changes later ethN indices but preserves each
VLAN's MAC. Update VyOS address/pool bindings to match that new interface order.

Review and apply the VM NIC changes in services-vms and matching VyOS bindings
in services-config together. Existing data connectivity may be interrupted while
MACs/bindings change. The existing HA/pool scaffold must still be completed
before applying services-config; this module only adds NIC identity.
