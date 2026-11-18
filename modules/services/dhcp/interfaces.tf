locals {
  # Data interface addresses. No hw-id: current VyOS (2026-11 rolling) names ethN by the NIC's slot, and
  # Proxmox adds the NICs in order (net0 = management eth0, net1.. = eth1.., the Kea HA NIC last), so the
  # names already match the MAC calculator's order. Management eth0 is deliberately absent.
  interface_commands = [
    for interface, address in var.interface_addresses :
    "set interfaces ethernet ${interface} address '${address}'"
  ]
}
