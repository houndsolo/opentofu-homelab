# Fabric leaf configuration

This root loads the shared fabric, node, Proxmox leaf and VNI inventory through
relative symlinks. Preserve those links.

## VNI inventory

Edit `inventory/auto.tfvars/vnis.auto.tfvars`. The shared type is in
`inventory/schema/vnis.tf`; both the root and leaf module link to it.

Each entry defines an L3VNI/VRF and its nested L2VNIs. Its `roles` select which
leaves receive that VRF and all its L2VNIs. The migrated inventory contains:

| Role | VRFs |
| --- | --- |
| proxmox | lylat_infra, lylat_service, lylat_lan |
| external_l2 | lylat_lan, lylat_ai |
| external_l3 | lylat_external |

The old `pve` role is now `proxmox`. Explicit route targets were changed from
`800:*` to `700:*` to match this repository's overlay AS. Route targets remain
explicit inventory values; changing the AS later does not rewrite them.
VNI IDs, VLANs, gateways, MACs, DHCP metadata and VRF tables are preserved.

## Generated commands

The leaf module keeps separate files for VNI selection, VXLAN/bridges,
VRFs, BGP, policies, interfaces and system settings. Their command lists
feed the existing single `vyoscmd_commands.this` resource.

Configuration includes:

- IPv6 VTEP and IPv4 router-ID addresses on the loopback interface.
- Spine underlay/EVPN peer groups and per-L2VNI route distinguishers.
- VLAN-to-VNI mappings for both L2VNIs and L3VNIs.
- VRF tables, VPN and EVPN route targets, connected redistribution and policies.
- VLAN trunk membership and pseudo-Ethernet anycast gateways.

IDs keep the old IPv6 convention: ID 18 becomes suffix `::18`.
The router ID uses the ID as a decimal IPv4 host offset.
Spine uplinks default to `eth${spine.id}`; set a spine's `uplink_if` to override.
The tenant trunk defaults to `eth3`; set `access_interface` on a fabric leaf
to override. Generated Proxmox leaves use `eth3`.
MTUs default to 9119 for VXLAN/access and 9189 for outer interfaces, as in
the source repository. Override `fabric.settings.vxlan_mtu` and `outer_mtu`.

Border VRFs use their `border_leaf_ipv4_rt_*` fields for IPv4 VPN route targets.
Missing VPN targets default to `overlay_as:VNI`.
VRFs with no L2VNIs have no L2 subnet prefix-list; their connected and VPN
export policies permit all routes. Review this border behavior before applying.

An empty `vnis` list adds no overlay commands. Unknown/generic roles receive
no VNIs. DHCP metadata is retained for later use; this module does not create
DHCP services or external L3 peers. As in the source module, the
`RM-EVPN-SPINE-EXPORT` policy is generated but is not attached to the spine peer group.

## Shared VM interfaces

Proxmox-role leaves obtain `fabric_macs` from `modules/fabric/macs`, as does
`fabric-vms`. The inventory key identifies the Proxmox node by default.
Use `proxmox_node` when the leaf has a different inventory name.
Missing Proxmox nodes fail the plan.

The module sends the shared MACs as VyOS `hw-id` commands together with
the system and overlay commands. Configure each guest once.

## Check and apply

Configure `VYOS_API_KEY` or the sensitive `TF_VAR_vyos_api_key` securely.
The VyOS API must already be enabled and reachable. The endpoint is derived
from `fabric.settings.vyos_mgmt_prefix` and the leaf ID.
The existing provider configuration uses `insecure = true`.

After installing the local VyOS provider and activating the mirror CLI config:

```sh
tofu -chdir=roots/fabric-leaves init
tofu -chdir=roots/fabric-leaves validate
tofu -chdir=roots/fabric-leaves test
tofu -chdir=roots/fabric-leaves plan
```

Review the plan before applying. The existing resource keeps `save = false`.

Outputs expose `leaf_specifications`, `interface_binding_commands`,
`vni_specifications` and the complete desired `commands`.
Mocked plan tests cover role selection, VNI command generation, border route
targets, empty inventory, duplicate VNI rejection and shared NIC bindings.
They do not apply live device configuration.
