locals {
  # Bind the Proxmox-created data NICs to the matching VyOS interface names.
  # Management eth0 is deliberately absent from this map.
  interface_binding_commands = [
    for interface, mac in var.fabric_macs :
    "set interfaces ethernet ${interface} hw-id ${mac}"
  ]

  interface_commands = concat(
    local.interface_binding_commands,
    [for interface, address in var.interface_addresses :
      "set interfaces ethernet ${interface} address '${address}'"
    ],
  )
}
