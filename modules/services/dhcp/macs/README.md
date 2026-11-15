# services/dhcp/macs: DHCP VM MAC calculator

Works out the VLAN NICs of the two DHCP VMs and a fixed MAC for each. Creates nothing. Called with
the same inputs by:

- [services-vms](../../../../roots/services-vms/README.md): Proxmox NICs (`network_devices`).
- [services-config](../../../../roots/services-config/README.md): VyOS `hw-id` bindings
  (`interface_macs`), and the same order for each interface's address.

## What it produces

One NIC per DHCP-enabled VLAN (every L2VNI in `vnis` with a `dhcp` block), plus the Kea HA NIC:

- **Order**: sorted numerically by VLAN (2 before 12) → `eth1`, `eth2`, ...; the HA NIC
  (`ha_vlan_id`, from `l2vnis.ha_dhcp`) always last.
- **Bridge**: `bridge` input (default `vmbr4000`), tagged with the VLAN.
- **MAC**: `02:00:00:67:<VM ID % 100>:<VLAN>`, both as two decimal digits; HA NIC last octet `ff`.
  `67` = DHCP (UDP 67) throughout the lab: VM IDs 67xx, addresses `10.<VLAN>.67.x`.
- No IP addresses, no `eth0` (created separately).

Today (DHCP VLANs 2, 8, 9, 10, 12; HA VLAN 1009):

| Interface | VLAN | `dhcp01` (6701) | `dhcp02` (6702) |
| --- | --- | --- | --- |
| eth1 | 2 | `02:00:00:67:01:02` | `02:00:00:67:02:02` |
| eth2 | 8 | `02:00:00:67:01:08` | `02:00:00:67:02:08` |
| eth3 | 9 | `02:00:00:67:01:09` | `02:00:00:67:02:09` |
| eth4 | 10 | `02:00:00:67:01:10` | `02:00:00:67:02:10` |
| eth5 | 12 | `02:00:00:67:01:12` | `02:00:00:67:02:12` |
| eth6 | 1009 (Kea HA) | `02:00:00:67:01:ff` | `02:00:00:67:02:ff` |

Outputs: `network_devices` (all NICs), `data_network_devices` (DHCP NICs only), `interface_macs`,
`ha_interfaces` (the HA NIC's `ethN`).

Checked at plan: DHCP VM IDs unique integers 6701-6799 (`vms` validation); DHCP VLANs unique
integers 1-99 and the HA VLAN not one of them (precondition on `network_devices`).

## Inputs

```hcl
module "dhcp_macs" {
  source     = "../../modules/services/dhcp/macs"
  vms        = { ... }                       # the DHCP VMs; only vm_id is used
  vnis       = var.vnis                      # the module picks the DHCP VLANs
  ha_vlan_id = var.l2vnis.ha_dhcp.vlan_id    # optional; null = no HA NIC
  # bridge   = "vmbr4000"                    # default
}
# network_devices["dhcp01"][0] = { bridge = "vmbr4000", vlan_id = 2, mac_address = "02:00:00:67:01:02" }
# interface_macs["dhcp01"]     = { eth1 = "02:00:00:67:01:02", eth2 = "02:00:00:67:01:08", ... }
```

## Adding or removing a DHCP VLAN

Each VLAN keeps its MAC, but `ethN` numbers shift (adding VLAN 4 moves VLAN 8 from `eth2` to
`eth3`, and everything above up one). VyOS binds by MAC, so interfaces follow, but plan and apply
`services-vms` and `services-config` together and check for stale interface addresses afterwards
([services-config](../../../../roots/services-config/README.md#things-to-know)). HA settings and
pools live in the parent [services/dhcp](../../../README.md#servicesdhcp) module.

## Tests

`tests/macs.tftest.hcl` (no providers): sorted VLANs, distinct peer octets, no `eth0`; a new VLAN
keeps existing MACs; VLAN 100 rejected; duplicate VM IDs rejected; HA NIC last with `ff`, moving no
data NIC; an HA VLAN that also serves DHCP rejected.

```sh
tofu -chdir=modules/services/dhcp/macs init
tofu -chdir=modules/services/dhcp/macs test
```
