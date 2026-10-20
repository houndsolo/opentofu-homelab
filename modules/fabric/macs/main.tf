locals {
  network_devices = {
    for name, node in var.nodes : name => [
      for index, bridge in var.underlay_bridges : {
        bridge = bridge
        # Decimal-looking octets: node 11 / vmbr4001 -> 02:00:00:11:40:01.
        mac_address = format(
          "02:00:00:%02d:%02d:%02d",
          node.id,
          floor(tonumber(trimprefix(bridge, "vmbr")) / 100),
          tonumber(trimprefix(bridge, "vmbr")) % 100,
        )
      }
    ]
  }
}

output "network_devices" {
  description = "Ordered extra VM NICs, after the management NIC."
  value       = local.network_devices
}

output "fabric_macs" {
  description = "Node -> VyOS ethN -> MAC, matching the extra VM NIC order."
  value = {
    for name, devices in local.network_devices : name => {
      for index, device in devices : "eth${index + 1}" => device.mac_address
    }
  }
}
