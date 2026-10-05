locals {
  network_devices = {
    for name, node in var.nodes : name => [
      for index, bridge in var.underlay_bridges : {
        bridge = bridge
        mac_address = join(":", regexall("..", format(
          "02%04d%04d%02d",
          var.underlay_local_as_base + node.id,
          node.id,
          index + 1,
        )))
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
