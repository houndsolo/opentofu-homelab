# DHCP MACs

Pure calculator shared by `services-vms` and `services-config`. It uses the same
DHCP VM inventory and DHCP-enabled VLAN list in both roots.

Format: `02:00:00:67:<vm_id % 100>:<VLAN>`, with decimal-looking two-digit octets.
VM 6701 on VLAN 8 is `02:00:00:67:01:08`; VM 6702 is `02:00:00:67:02:08`.
Supported unique VM IDs are 6701..6799 and unique VLAN IDs are 1..99.

VLANs sort numerically onto eth1 onwards. `network_devices[vm]` supplies VM NICs;
`fabric_macs[vm]` supplies VyOS hw-id bindings. Management eth0 is excluded.
The calculator assigns no IPs.

Adding a lower VLAN shifts later ethN indices but preserves each VLAN's MAC.
Review/apply VM NICs and VyOS bindings together; HA and pools live in the parent
DHCP module.
