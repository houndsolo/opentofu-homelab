# fabric/macs: leaf VM MAC calculator

Fixed MACs for the data NICs of the leaf VMs (`vtep-<node>`). Creates nothing. Called by two roots
so both agree:

- [fabric-vms](../../../roots/fabric-vms/README.md): Proxmox NICs (`network_devices`).
- [fabric-leaves](../../../roots/fabric-leaves/README.md): VyOS `hw-id` bindings (`fabric_macs`).

Why: VyOS binds interface names to MACs. With random MACs a recreated NIC could come back as a
different `ethN` (the spine link as `eth3`); fixed MACs + `hw-id` keep `eth1` = spine 1.

## Format

```text
02:00:00:<node ID>:00:<interface number>
```

- `02`: locally administered unicast; never clashes with a vendor MAC.
- Node ID as decimal digits (`%02d`): node 17 is `17`, not `11`.
- Interface number = position in `underlay_bridges` + 1 (`eth1`, `eth2`, ...). `eth0`
  (management) isn't included; Proxmox assigns its MAC. The bridge number never affects the MAC.

| Node | eth1 (vmbr4001) | eth2 (vmbr4002) | eth3 (vmbr4000) |
| --- | --- | --- | --- |
| fichina (11) | `02:00:00:11:00:01` | `02:00:00:11:00:02` | `02:00:00:11:00:03` |
| venom (17) | `02:00:00:17:00:01` | `02:00:00:17:00:02` | `02:00:00:17:00:03` |

Checked at plan: node IDs unique integers 1-99; at most 99 unique bridges named `vmbr<0-9999>`
without leading zeros.

## Inputs and outputs

```hcl
module "proxmox_fabric_macs" {
  source           = "../../modules/fabric/macs"
  nodes            = var.nodes.proxmox               # only `id` is used
  underlay_bridges = var.fabric_vms.underlay_bridges # ["vmbr4001", "vmbr4002", "vmbr4000"]
}

# network_devices["venom"] = [
#   { bridge = "vmbr4001", mac_address = "02:00:00:17:00:01" },  # eth1
#   { bridge = "vmbr4002", mac_address = "02:00:00:17:00:02" },  # eth2
#   { bridge = "vmbr4000", mac_address = "02:00:00:17:00:03" },  # eth3
# ]
# fabric_macs["venom"] = { eth1 = "02:00:00:17:00:01", eth2 = "...:02", eth3 = "...:03" }
```

## Changing NIC order or MACs

The MAC follows the **position**, not the bridge: reordering `underlay_bridges` plugs `eth1`
(`...:00:01`) into a different bridge. The leaf config expects `eth1`/`eth2` = spine links and
`eth3` = access trunk.

When NIC MACs change on a running leaf: apply `fabric-vms` first (Proxmox NICs), then
`fabric-leaves` (`hw-id`). If VyOS still reports a conflict, check
`show configuration commands | match hw-id` and delete stale bindings.

## Tests

`tests/macs.tftest.hcl` (no providers): sequential MACs without `eth0`; bridge reordering keeps
the MAC per position; node ID 100 rejected.

```sh
tofu -chdir=modules/fabric/macs init
tofu -chdir=modules/fabric/macs test
```
