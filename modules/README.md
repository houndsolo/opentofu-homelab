# Modules

Roots supply inventory and providers to these modules. Run deployments from a root.

| Module | Purpose |
| --- | --- |
| proxmox/network | Host Ethernet, bonds, bridges and VLANs |
| proxmox/vm | Image-backed VM, defaults, cloud-init and selected SSH keys |
| proxmox/settings | Incomplete Proxmox settings configuration |
| fabric/leaf | VyOS interfaces, BGP, VXLAN, VRFs and policies |
| fabric/spines | RouterOS BGP/EVPN configuration |
| fabric/leaves | Physical leaves plus one virtual leaf per Proxmox host |
| fabric/macs | Shared leaf NIC and VyOS binding MACs |
| services/dhcp | Combined VyOS interfaces, HA, listen and pool commands |
| services/dhcp/macs | Shared DHCP NIC and VyOS binding MACs |

The leaves module and MAC calculators create no resources. VM and configuration roots use the same
ordered mappings; keep their inventory consistent. VyOS modules combine command
locals into one `vyoscmd_commands` resource per device.
