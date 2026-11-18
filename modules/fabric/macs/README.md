# fabric/macs: leaf VM MAC calculator

Fixed MACs for the data NICs of the leaf VMs (`vtep-<node>`). Creates nothing. Called by
[fabric-vms](../../../roots/fabric-vms/README.md) for the Proxmox NICs (`network_devices`).

Why: a recreated NIC keeps its MAC, so a leaf port always shows the same address. The interface
*name* no longer depends on it: current VyOS (2026-11 rolling) dropped `hw-id` and names `ethN` by
slot at boot, and the Proxmox NIC order (net1..net3) is fixed.

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
```

## Changing NIC order or MACs

The MAC follows the **position**, not the bridge: reordering `underlay_bridges` plugs `eth1`
(`...:00:01`) into a different bridge. The leaf config expects `eth1`/`eth2` = spine links and
`eth3` = access trunk.

## Tests

`tests/macs.tftest.hcl` (no providers): sequential MACs without `eth0`; bridge reordering keeps
the MAC per position; node ID 100 rejected.

```sh
tofu -chdir=modules/fabric/macs init
tofu -chdir=modules/fabric/macs test
```
