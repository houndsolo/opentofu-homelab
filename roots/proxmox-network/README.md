# proxmox-network

This root configures the host networking on every Proxmox **cluster** node: NIC
settings, a LACP bond, the Linux bridges (`vmbrN`) and VLAN sub-interfaces. It
applies the one profile in
[`pve-network.auto.tfvars`](../../inventory/auto.tfvars/pve-network.auto.tfvars)
to every cluster host in `nodes.proxmox`, giving each host its own addresses
based on its ID.

The standalone host (`greatfox`, marked `standalone = true`) is **not** managed
here.

## What one node gets

This is what venom (ID 17) ends up with. Every other cluster node gets the same
interfaces, with its own ID in the addresses.

| Interface | Built from | Address | MTU | Purpose (its comment) |
| --- | --- | --- | --- | --- |
| `vmbr0` | `eth0` | `10.20.7.17/16` | 9119 | Management: the Proxmox API, SSH, web UI |
| `vmbr1` | `eth10` (VLAN-aware) | `10.7.1.17/24` | 9119 | lan |
| `vmbr7` | `eth7` | `10.7.0.17/24` | 9000 | Cluster management (`eth7` is the "proxmox cluster network") |
| `bond0` | `eth22` + `eth27`, 802.3ad (LACP), hash `layer3+4` | | 9600 | Ceph |
| `vmbr22` | `bond0.22` | `10.22.0.17/16` | 9600 | Ceph private |
| `vmbr27` | `bond0.27` | `10.27.0.17/16` | 9600 | Ceph public |
| `vmbr100` | `eth1` (VLAN-aware) | `10.5.1.17/16` | 9119 | VXLAN L2 out |
| `vmbr4000` | no physical port (VLAN-aware) | | 9119 | **Fabric access**: VMs ↔ the host's leaf VM, tagged per VLAN |
| `vmbr4001` | `eth4001` (VLAN-aware) | | 9189 | Leaf ↔ spine 1 |
| `vmbr4002` | `eth4002` (VLAN-aware) | | 9189 | Leaf ↔ spine 2 |
| `vmbr4010`–`4012` | no ports | | 9119 / 9189 | TEST copies of 4000–4002 |
| `vmbr4000.2` | VLAN 2 on `vmbr4000` | `10.2.0.17/16`, **default gateway `10.2.0.5`** | 1500 | Puts the host itself on VLAN 2 (`lylat_infra`), so the web UI can be reached through the fabric (its comment is `vxlan-webui`) |

The NICs `eth0`, `eth1`, `eth7`, `eth10`, `eth22`, `eth27`, `eth4001` and
`eth4002` get their MTU and a comment. Those NIC names must already exist on the
host; this repo doesn't rename NICs.

`vmbr4000` is the heart of the VM networking. It has no physical port; it's a
VLAN-aware switch inside the host. A VM's NIC joins it with a VLAN tag (for
example, VLAN 8 for the DNS VMs). The host's leaf VM joins it on `eth3` as a
trunk, and routes and bridges those VLANs into the fabric.

**The hosts' default route goes through the fabric.** `10.2.0.5` is the anycast
gateway of VLAN 2, which is answered by the host's own leaf VM (`vtep-<host>`).
So a host only reaches off-subnet networks, such as the internet, while its leaf
VM is running and the fabric is up. The management network on `vmbr0`
(`10.20.0.0/16`) is directly connected and doesn't depend on it. Keep that in
mind when you rebuild a leaf VM or apply leaf changes.

## How the addresses are calculated

Each bridge or VLAN with an `ipv4` block gets
`cidrhost(cidrhost_prefix, node ID)/cidr`:

```hcl
ipv4 = {
  cidrhost_prefix = "10.20.7.0/24" # choose host number <node ID> in this range -> 10.20.7.17
  cidr            = 16             # configure it with this prefix length    -> 10.20.7.17/16
}
```

## Order of operations

OpenTofu creates the pieces in dependency order:

1. The NICs (`eth*`)
2. The bonds and bridges, which are built on top of the NICs
3. The VLAN interfaces, which are built on top of the bridges and bonds

## Before you run it

> **Careful:** these changes are pushed to live hosts. A mistake on `vmbr0` or
> `eth0` can cut off the very management path OpenTofu (and you) are using. Have
> console or out-of-band access to the hosts, and read the plan line by line.

```sh
tooling/walk-roots.sh proxmox-network
```

## Adopting the existing host config

If the hosts already have these interfaces, import them first. That way OpenTofu
takes them over instead of trying to create them again. The helper script
imports every interface on every node:

```sh
# 1. Open the script and check that its node list and interface lists match your
#    hosts and pve-network.auto.tfvars. They're hard-coded at the top.
$EDITOR tooling/tofu_import_stuff.sh

# 2. Initialize the root, then run the script from the top of the repo.
#    with-secrets supplies the Proxmox API tokens.
tooling/with-secrets tofu -chdir=roots/proxmox-network init
tooling/with-secrets bash tooling/tofu_import_stuff.sh

# 3. Check what's left to change. Ideally almost nothing.
tooling/with-secrets tofu -chdir=roots/proxmox-network plan
```

To import a single interface by hand, use these address and ID formats:

```sh
# Resource address:  module.pve_network["<node>"].<resource type>.this["<map key>"]
# Import ID:         <node>:<interface name>
tooling/with-secrets tofu -chdir=roots/proxmox-network import \
  'module.pve_network["venom"].proxmox_network_linux_bridge.this["4000"]' 'venom:vmbr4000'

# VLAN interfaces use the full name in the import ID:
tooling/with-secrets tofu -chdir=roots/proxmox-network import \
  'module.pve_network["venom"].proxmox_network_linux_vlan.this["2"]' 'venom:vmbr4000.2'
```

The code is in [modules/proxmox/network](../../modules/README.md#proxmoxnetwork).
