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

`fabric/spines` accepts `keepalive_time` (default `"1m"`) and `hold_time`
(default `"3m"`). Both BGP templates and every underlay/overlay connection
receive these values explicitly; keepalive should be at most hold/3.
Leaf IDs must be unique. The spine module also manages the built-in memory
logging action with 10,000 lines and enables the NTP client when
`fabric.settings.ntp_servers` is nonempty.

Both `fabric/spines` and `fabric/leaf` use `fabric.settings.ntp_servers`
(default `["0.pool.ntp.org", "1.pool.ntp.org"]`). The leaf module adds
`set service ntp server` commands in its system configuration and enables BGP
`log-neighbor-changes`. An empty list skips NTP configuration; it does not
remove previously configured servers or disable an existing client.
