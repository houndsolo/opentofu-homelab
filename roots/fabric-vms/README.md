# fabric-vms

One VyOS VM on every Proxmox host (`nodes.proxmox`, greatfox included): the host's leaf/VTEP. This
root only builds the VMs; [fabric-leaves](../fabric-leaves/README.md) configures them. Cluster hosts
go through the cluster API, greatfox through the `proxmox.greatfox` provider alias, hence two module
blocks in `main.tf` (a provider alias can't be chosen per instance).

## The VM on venom (ID 17)

| Setting | Value | From |
| --- | --- | --- |
| Name | `vtep-venom` | `fabric_vms.hostname_prefix` + node name |
| VM ID | `717` | node ID + `fabric_vms.vm_id_offset` (700) |
| Image | VyOS 1.5 rolling + cloud-init snippet `cephfs:snippets/vyos_api.yml` | `vm_images.vyos` |
| `eth0` | `vmbr0`, `10.20.10.17/16` (cloud-init) | `fabric.settings.management_prefix` + `management_prefix_length`; fabric-leaves reaches the API there |
| `eth1` / `eth2` | `vmbr4001` / `vmbr4002` (spine 1 / 2), MAC `02:00:00:17:00:01` / `:02` | `fabric_vms.underlay_bridges[0..1]` |
| `eth3` | `vmbr4000` (trunk to the host's VMs), MAC `02:00:00:17:00:03` | `underlay_bridges[2]` |
| Started, tags | yes, `opentofu, vyos, vtep` | `config` defaults in `locals.tf` |
| CPU, memory, disk | 4 cores, 4096 MB, 10 GB | `vm_config` / schema defaults |

The data NICs use `vm_config.underlay_mtu` (default `1` = the bridge's MTU: 9189 on the spine
links, 9119 on the trunk).

**Why fixed MACs:** VyOS binds interface names to MACs (`hw-id`). The shared
[MAC calculator](../../modules/fabric/macs/README.md) derives them from node ID and NIC position
(`02:00:00:<id>:00:<n>`); this root puts them on the Proxmox NICs, fabric-leaves binds the same
MACs (`set interfaces ethernet eth1 hw-id ...`), so a recreated NIC never comes back as another
`ethN`.

## Before you run it

- The VyOS image at `vm_images.vyos.import_image` on cephfs, and the snippet
  `cephfs:snippets/vyos_api.yml` (your cloud-init user-data, not in the repo; it must enable the
  VyOS HTTPS API with the key in `vyos_api_key`).
- Bridges `vmbr0`, `vmbr4000`, `vmbr4001`, `vmbr4002` on every host:
  [proxmox-network](../proxmox-network/README.md) for cluster nodes, by hand on greatfox.
- `proxmox.secret.auto.tfvars` (both API tokens) linked in; see
  [Secrets](../../inventory/README.md#secrets).

```sh
tooling/walk-roots.sh fabric-vms
```

After an apply, check each leaf's API answers before running fabric-leaves:

```sh
curl -k -X POST https://10.20.10.17/retrieve -F data='{"op": "showConfig", "path": []}' -F key="$VYOS_API_KEY"
```

Output `leaf_vms`: name, VM ID, node, management address and NICs of every leaf VM.

## Overriding one leaf VM

Add a `vms` entry named after the generated VM with `owner = "fabric-vms"` (any other owner makes it
a separate VM of another root):

```hcl
vms = {
  vtep-venom = {
    owner  = "fabric-vms"
    config = { cpu_cores = 4, memory_mb = 8192 } # merged over this root's defaults, vm_config and the image
    # image, node, vm_id, management_address, network_devices: top-level fields REPLACE the generated ones
  }
}
```

None exist today.
