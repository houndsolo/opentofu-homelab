# Fabric leaves

Configures VyOS using one `vyoscmd_commands` resource per leaf.
Separate module files generate interfaces, system settings, BGP, VXLAN,
VRFs and route policies.

Edit these shared files under `inventory/auto.tfvars/`:

- `nodes.auto.tfvars`: Proxmox nodes; each generates a `proxmox` leaf.
- `fabric.auto.tfvars`: physical leaves, spines, addressing and MTUs.
- `pve-leaf.auto.tfvars`: bridge order and AS base for shared VM MACs.
- `vnis.auto.tfvars`: L3VNIs, nested L2VNIs, role selection and route targets.

The tenant interface on generated Proxmox leaves is
`eth${length(fabric.spines) + 1}`; physical leaves specify `access_interface`.
This assumes spine-facing NICs occupy the preceding interface numbers.
Spine uplinks default to `eth${spine.id}`, unless `uplink_if` is set.
Leaf ID 15 produces IPv6 suffix `::15` and VTEP MAC suffix `00:15`.

Route targets are explicit inventory values. DHCP metadata does not create
DHCP services. External L3 peer configuration is not implemented.
VRFs without L2 subnets have unrestricted connected/VPN export policies.
The generated `RM-EVPN-SPINE-EXPORT` policy is not attached to the spine peer group.

Set `VYOS_API_KEY` or `TF_VAR_vyos_api_key`.
The API endpoint uses `vyos_mgmt_prefix` and the leaf ID.
The current provider disables TLS verification, and the resource uses `save = false`.

After [provider setup](../../providers/README.md), run from the repository directory:

```sh
tofu -chdir=roots/fabric-leaves init
tofu -chdir=roots/fabric-leaves validate
tofu -chdir=roots/fabric-leaves plan
```
