# fabric/macs: leaf VM MAC calculator

This module calculates fixed MAC addresses for the data NICs of the leaf VMs
(`vtep-<node>`). It creates nothing; it only does arithmetic. It's used by two
roots, so both sides agree on the MACs:

- **[fabric-vms](../../../roots/fabric-vms/README.md)** gives these MACs to the
  Proxmox NICs (the `network_devices` output).
- **[fabric-leaves](../../../roots/fabric-leaves/README.md)** binds each VyOS
  interface to its MAC with `hw-id` (the `fabric_macs` output).

## Why fixed MACs?

VyOS ties interface names to MAC addresses. If Proxmox picked random MACs, a
recreated NIC could come back as a different `ethN`, and the spine link might
suddenly be `eth3`. With fixed MACs and matching `hw-id` bindings, `eth1` is
always the link to spine 1.

## The format

```text
02:00:00:<node ID>:00:<interface number>
```

- **`02`** sets the "locally administered" bit (and keeps the address unicast),
  so it can never clash with a real vendor MAC.
- **The node ID** is written digit for digit, so node 17 is `17`, not `11` (17 in
  hex).
- **The interface number** is the bridge's position in `underlay_bridges` plus
  one, which gives `eth1`, `eth2`, ... The management NIC (`eth0`) isn't
  included; Proxmox gives it a MAC of its own.

With `underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"]`:

| Node | Interface | Bridge | MAC |
| --- | --- | --- | --- |
| fichina (11) | eth1 | vmbr4001 | `02:00:00:11:00:01` |
| fichina (11) | eth2 | vmbr4002 | `02:00:00:11:00:02` |
| fichina (11) | eth3 | vmbr4000 | `02:00:00:11:00:03` |
| venom (17) | eth1 | vmbr4001 | `02:00:00:17:00:01` |
| venom (17) | eth2 | vmbr4002 | `02:00:00:17:00:02` |
| venom (17) | eth3 | vmbr4000 | `02:00:00:17:00:03` |

**Limits** (checked during `plan`):

- Node IDs must be unique whole numbers from 1 to 99.
- There can be at most 99 bridges, with no duplicates.
- Each bridge must be named `vmbr<0–9999>`, with no leading zeros.

The bridge number itself never affects the MAC.

## Inputs and outputs

How the roots call it:

```hcl
module "proxmox_fabric_macs" {
  source           = "../../modules/fabric/macs"
  nodes            = var.nodes.proxmox                # every Proxmox host; only `id` is used
  underlay_bridges = var.fabric_vms.underlay_bridges  # ["vmbr4001", "vmbr4002", "vmbr4000"]
}
```

What it returns, for venom:

```hcl
# network_devices: used by fabric-vms as the VM's extra NICs, in order.
network_devices["venom"] = [
  { bridge = "vmbr4001", mac_address = "02:00:00:17:00:01" }, # -> eth1
  { bridge = "vmbr4002", mac_address = "02:00:00:17:00:02" }, # -> eth2
  { bridge = "vmbr4000", mac_address = "02:00:00:17:00:03" }, # -> eth3
]

# fabric_macs: used by fabric-leaves to write "set interfaces ethernet ethN hw-id <MAC>".
fabric_macs["venom"] = {
  eth1 = "02:00:00:17:00:01"
  eth2 = "02:00:00:17:00:02"
  eth3 = "02:00:00:17:00:03"
}
```

## Reordering the bridges

The MAC follows the **position**, not the bridge. If you reorder
`underlay_bridges`, `eth1` keeps `...:00:01`, but it gets plugged into a
different bridge. The leaf config expects `eth1` and `eth2` to be the spine links
and `eth3` to be the access trunk, so keep the order consistent with that.

## Switching from bridge-derived MACs

Older versions of this repo derived the MACs from the bridge number. To move a
running lab to this scheme:

1. **Apply `fabric-vms` first**, so the Proxmox NICs get the new MACs.
2. **Then apply `fabric-leaves`**, so the VyOS `hw-id` bindings are updated to
   match.

Both roots must use the same node IDs and bridge order. If VyOS still reports a
conflict after the NIC change, look at the guest's existing bindings
(`show configuration commands | match hw-id`) and delete any stale ones.

## Tests

`tests/macs.tftest.hcl` checks three things:

- The MACs are sequential and `eth0` is excluded.
- Reordering the bridges keeps the MAC on each interface position.
- A node ID of 100 is rejected.

No providers are needed:

```sh
tofu -chdir=modules/fabric/macs init
tofu -chdir=modules/fabric/macs test
```
