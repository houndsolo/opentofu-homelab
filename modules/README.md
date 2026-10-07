# Modules

Reusable configuration called by the roots.

| Module | Purpose |
| --- | --- |
| proxmox/network | Ethernet interfaces, bonds, bridges and VLANs |
| proxmox/vm | One image-backed VM |
| proxmox/settings | Proxmox settings; incomplete |
| fabric/leaf | VyOS system, interfaces, BGP, VXLAN, VRFs and policies |
| fabric/macs | Shared MAC calculation for VM NICs and VyOS bindings |

Modules receive their inputs from the calling root.
Run deployment commands against a root, not a module.

The leaf module combines command lists from separate files into one
`vyoscmd_commands` resource.

The MAC module preserves NIC list order. Changes to node IDs, AS base or bridge
order can change MAC assignments.
