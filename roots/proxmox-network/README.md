# proxmox-network

Host networking on every Proxmox **cluster** node (NICs, the LACP bond, `vmbrN` bridges, VLAN
interfaces): one profile from
[`pve-network.auto.tfvars`](../../inventory/auto.tfvars/pve-network.auto.tfvars), addressed per
node ID. greatfox (`standalone = true`) is not managed here. Code:
[modules/proxmox/network](../../modules/README.md#proxmoxnetwork).

## What one node gets (venom, ID 17)

| Interface | Built from | Address | MTU | Comment / purpose |
| --- | --- | --- | --- | --- |
| `vmbr0` | `eth0` | `10.20.7.17/16` | 9119 | mgmt: API, SSH, web UI |
| `vmbr1` | `eth10` (VLAN-aware) | `10.7.1.17/24` | 9119 | lan |
| `vmbr7` | `eth7` | `10.7.0.17/24` | 9000 | cluster management |
| `bond0` | `eth22` + `eth27`, 802.3ad, `layer3+4` | | 9600 | ceph |
| `vmbr22` | `bond0.22` | `10.22.0.17/16` | 9600 | ceph private |
| `vmbr27` | `bond0.27` | `10.27.0.17/16` | 9600 | ceph public |
| `vmbr100` | `eth1` (VLAN-aware) | `10.5.1.17/16` | 9119 | vxlan l2 out |
| `vmbr4000` | no port (VLAN-aware) | | 9119 | fabric access: VMs ↔ the host's leaf VM (`eth3`, trunk), tagged per VLAN |
| `vmbr4001` / `vmbr4002` | `eth4001` / `eth4002` (VLAN-aware) | | 9189 | leaf ↔ spine 1 / 2 |
| `vmbr4010`–`4012` | no ports | | 9119 / 9189 | TEST copies of 4000–4002 |
| `vmbr4000.2` | VLAN 2 on `vmbr4000` | `10.2.0.17/16`, **gateway `10.2.0.1`** | 1500 | vxlan-webui: the host on VLAN 2 (VRF `lylat-edge`) |

The NICs `eth0`, `eth1`, `eth7`, `eth10`, `eth22`, `eth27`, `eth4001`, `eth4002` get MTU and a
comment; the names must already exist (nothing renames NICs). Addresses are
`cidrhost(cidrhost_prefix, node ID)/cidr`, e.g. `{ cidrhost_prefix = "10.20.7.0/24", cidr = 16 }`
→ `10.20.7.17/16`.

- **The hosts' default route goes through the fabric**: `10.2.0.1` is VLAN 2's anycast gateway on
  the host's own leaf VM, so off-subnet traffic (internet) needs that leaf and the fabric up.
  `vmbr0` (10.20.0.0/16) is directly connected and doesn't. Keep it in mind when rebuilding a leaf
  VM or applying leaf changes.
- **Careful:** changes hit live hosts; a mistake on `vmbr0`/`eth0` cuts the management path
  OpenTofu uses. Have console access and read the plan line by line.
- **Web UI on 443 (not OpenTofu).** [`host-files/`](host-files/): nft table `ip pve_https` (TCP 443
  to the node's own addresses → pveproxy 8006) and `pve-https-redirect.service`, so
  `https://<node>.lylat.space` works without `:8006`. Install by hand on every node incl. greatfox
  with `pve-https-install.sh` (usage at its top). The proxies also publish `https://pve.lylat.space`
  and `https://pve-<node>.lylat.space` (services-config `proxy.tf`).

```sh
tooling/walk-roots.sh proxmox-network
```

## Adopting the existing host config

`tooling/tofu_import_stuff.sh` imports every interface on every node. Its node and interface lists
are hard-coded at the top: check them against your hosts and the tfvars first.

```sh
tofu -chdir=roots/proxmox-network init
bash tooling/tofu_import_stuff.sh          # with the single-file secrets setup: tooling/with-secrets in front
tofu -chdir=roots/proxmox-network plan     # should show almost nothing

# One interface by hand: module.pve_network["<node>"].<type>.this["<key>"]  <node>:<interface>
tofu -chdir=roots/proxmox-network import \
  'module.pve_network["venom"].proxmox_network_linux_bridge.this["4000"]' 'venom:vmbr4000'
tofu -chdir=roots/proxmox-network import \
  'module.pve_network["venom"].proxmox_network_linux_vlan.this["2"]' 'venom:vmbr4000.2'
```
