# fabric-vms

This root creates **one VyOS VM on every Proxmox host**. Each VM is that host's
leaf switch and VTEP. It bridges and routes the host's VM VLANs into the
EVPN/VXLAN fabric. This root only builds the VMs; their routing configuration
comes later, from [fabric-leaves](../fabric-leaves/README.md).

## What gets built

There's one VM for every host in `nodes.proxmox`. VMs on cluster hosts are
created through the cluster API. The standalone host's VM (`greatfox`) goes
through the separate `proxmox.greatfox` provider, because that host isn't a
cluster member. That's why `main.tf` has two module blocks: a provider alias
can't be chosen per instance. Here's the VM on venom (ID 17):

| Setting | Value | From |
| --- | --- | --- |
| Name | `vtep-venom` | `fabric_vms.hostname_prefix` + node name |
| VM ID | `717` | node ID + `fabric_vms.vm_id_offset` (700) |
| Image | VyOS 1.5 rolling qcow2 + cloud-init snippet `cephfs:snippets/vyos_api.yml` | `vm_images.vyos` |
| `eth0` (net0) | `vmbr0`, `10.20.10.17/16` (set by cloud-init) | `fabric.settings.management_prefix` + `management_prefix_length` (the same setting fabric-leaves uses to reach the leaf) |
| `eth1` | `vmbr4001` (link to spine 1), MAC `02:00:00:17:00:01` | `underlay_bridges[0]` |
| `eth2` | `vmbr4002` (link to spine 2), MAC `02:00:00:17:00:02` | `underlay_bridges[1]` |
| `eth3` | `vmbr4000` (trunk to the host's VMs), MAC `02:00:00:17:00:03` | `underlay_bridges[2]` |
| Started | yes | a `config` default set by this root |
| Tags | `opentofu, vyos, vtep` | a `config` default set by this root (`locals.tf`) |
| CPU, memory, disk, ... | 4 cores, 4096 MB, 10 GB with today's inventory | `vm_config` and the schema defaults |

The data NICs use `vm_config.underlay_mtu`, which defaults to `1`. That's
Proxmox's way of saying "use the bridge's MTU", so the leaf gets 9189 on its
spine links and 9119 on the access trunk.

## Why the MACs are fixed

VyOS ties each interface name to a MAC address (its `hw-id`). If Proxmox picked
random MACs, a recreated NIC could come back with a different interface number,
and your spine link might suddenly be `eth3`. To prevent that, the shared
[MAC calculator](../../modules/fabric/macs/README.md) picks fixed MACs from the
node ID and the NIC position:

- This root gives those MACs to the Proxmox NICs.
- `fabric-leaves` uses the **same** calculator to bind each VyOS interface to its
  MAC (`set interfaces ethernet eth1 hw-id 02:00:00:17:00:01`).

## Before you run it

- **The VyOS image** must be at the `vm_images.vyos.import_image` path on
  `cephfs`.
- **The snippet** `cephfs:snippets/vyos_api.yml` must exist. It's your own
  cloud-init user-data, and it should turn on the VyOS HTTPS API with the same
  key you put in `vyos_api_key`, because `fabric-leaves` uses that API. The repo
  doesn't include a copy.
- **The bridges** `vmbr0`, `vmbr4000`, `vmbr4001` and `vmbr4002` must exist on
  every host. [proxmox-network](../proxmox-network/README.md) creates them on the
  cluster nodes. Set up `greatfox` yourself.
- **`proxmox.secret.auto.tfvars`** (both Proxmox API tokens) must be linked
  into this root; see [Secrets](../../inventory/README.md#secrets).

```sh
tooling/walk-roots.sh fabric-vms
```

## Overriding one leaf VM

To change one leaf VM without changing the others, add an entry to
[`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars) that uses the
generated name:

```hcl
vms = {
  # The key is the generated VM name: hostname_prefix + node name.
  vtep-venom = {
    owner = "fabric-vms" # marks this entry as an override for a generated fabric VM
    config = {
      cpu_cores = 4      # settings in config are merged on top of the generated ones...
      memory_mb = 8192   # ...so anything you leave out keeps its generated or default value
    }
    # node, vm_id, image, management_address and network_devices are generated.
    # Setting one of them here replaces the generated value.
  }
}
```

- **Hardware and lifecycle settings go in `config`** (`cpu_cores`, `memory_mb`,
  `started`, `tags`, and the rest). They're merged over this root's defaults
  (`started = true` and the tags), and all of that sits on top of `vm_config`
  and the image.
- **Top-level fields replace the generated ones.** Setting `image`,
  `management_address` or `network_devices` here replaces what this root would
  generate, so leave those out unless you mean it.
- **`owner = "fabric-vms"` is what makes it an override.** With any other owner,
  the entry would be a separate VM, created by another root, and it would need its
  own `node` and `vm_id`.

## Outputs

`leaf_vms` lists every leaf VM, including the one on `greatfox`: its name, VM ID,
node, management address and NICs. Node IDs are checked for uniqueness in `nodes`
itself, since the VM IDs are built from them.

## After applying

Give the VMs a minute to boot, then check that each leaf's API answers before
running `fabric-leaves`:

```sh
# Ask the VyOS HTTPS API for the running config. Any JSON reply means the API works.
# -k skips TLS verification, because VyOS uses a self-signed certificate.
curl -k -X POST https://10.20.10.17/retrieve \
  -F data='{"op": "showConfig", "path": []}' \
  -F key="$VYOS_API_KEY"
```
