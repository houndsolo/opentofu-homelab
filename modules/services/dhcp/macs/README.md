# services/dhcp/macs: DHCP VM MAC calculator

This module works out the VLAN NICs of the two DHCP VMs, and a fixed MAC for each
one. It creates nothing; it only does arithmetic. It's used by two roots, with
the same inputs, so both sides agree:

- **[services-vms](../../../../roots/services-vms/README.md)** creates the
  Proxmox NICs from it (the `network_devices` output).
- **[services-config](../../../../roots/services-config/README.md)** binds each
  VyOS interface to its MAC with `hw-id` (the `interface_macs` output). It also
  uses the same order to work out each interface's address.

## What it produces

The module reads `vnis` itself and picks out the DHCP-enabled VLANs: every L2VNI
that has a `dhcp` block. There's one NIC per DHCP-enabled VLAN:

- **Order.** The NICs are sorted by VLAN number and become `eth1`, `eth2`, ...
  The sort is numeric, so VLAN 2 comes before VLAN 12.
- **Bridge.** They're all on the `bridge` input (default `vmbr4000`), tagged
  with their VLAN.
- **MAC.** `02:00:00:67:<VM ID % 100>:<VLAN>`, with both numbers written as two
  decimal digits. `67` is the DHCP number used throughout the lab: in the VM IDs
  (67xx) and the addresses (`10.<VLAN>.67.x`). To remember it, think of UDP
  port 67, the DHCP server port, just as the DNS VMs use 53.
- **No addresses.** This module assigns no IP addresses.
- **No management NIC.** `eth0` is created separately and isn't included here.

With today's DHCP VLANs (2, 8, 9, 10, 12) and the Kea HA NIC (`ha_vlan_id` 211):

| Interface | VLAN | `dhcp01` (VM 6701) | `dhcp02` (VM 6702) |
| --- | --- | --- | --- |
| eth1 | 2 | `02:00:00:67:01:02` | `02:00:00:67:02:02` |
| eth2 | 8 | `02:00:00:67:01:08` | `02:00:00:67:02:08` |
| eth3 | 9 | `02:00:00:67:01:09` | `02:00:00:67:02:09` |
| eth4 | 10 | `02:00:00:67:01:10` | `02:00:00:67:02:10` |
| eth5 | 12 | `02:00:00:67:01:12` | `02:00:00:67:02:12` |
| eth6 | 211 (Kea HA) | `02:00:00:67:01:ff` | `02:00:00:67:02:ff` |

The Kea HA NIC (`ha_vlan_id`, from `l2vnis.ha_dhcp`) always comes last, with the
MAC last octet `ff`. Outputs: `network_devices` (all NICs, for services-vms),
`data_network_devices` (DHCP NICs only), `interface_macs` and `ha_interfaces`.

**Limits** (checked during `plan`):

- DHCP VM IDs must be unique whole numbers from 6701 to 6799. This is a
  validation on the `vms` input.
- DHCP-enabled VLANs must be unique whole numbers from 1 to 99. This is a
  precondition on the `network_devices` output, because the VLANs are picked out
  inside the module.

## Inputs and outputs

```hcl
module "dhcp_macs" {
  source = "../../modules/services/dhcp/macs"

  # The DHCP VMs (only vm_id is used).
  vms = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "dhcp" }

  # The whole VNI inventory; the module picks out the DHCP-enabled VLANs.
  vnis = var.vnis

  # bridge = "vmbr4000"   # optional: the VLAN-aware bridge for the NICs (this is the default)
}

# Outputs, for dhcp01:
#   network_devices["dhcp01"][0] = { bridge = "vmbr4000", vlan_id = 2, mac_address = "02:00:00:67:01:02" }
#   interface_macs["dhcp01"]     = { eth1 = "02:00:00:67:01:02", eth2 = "02:00:00:67:01:06", ... }
```

## Adding or removing a VLAN

Each VLAN keeps its MAC forever, but the `ethN` numbers can shift. For example,
adding VLAN 4 makes VLAN 8 move from `eth2` to `eth3`, and every VLAN above it
moves up one as well. Because VyOS binds by MAC, the interfaces follow correctly.
But plan and apply `services-vms` and `services-config` together, and check for
old interface addresses afterwards. See
[services-config](../../../../roots/services-config/README.md#things-to-know).

The HA settings and the pools aren't in this module. They live in the parent
[services/dhcp](../../../README.md#servicesdhcp) module.

## Tests

`tests/macs.tftest.hcl` checks four things:

- The VLANs are sorted, each peer gets a distinct octet, and `eth0` is excluded.
- A new VLAN doesn't change an existing VLAN's MAC.
- VLAN 100 is rejected.
- Duplicate VM IDs are rejected.

No providers are needed:

```sh
tofu -chdir=modules/services/dhcp/macs init
tofu -chdir=modules/services/dhcp/macs test
```
