locals {
  network_devices = {
    for name, node in var.nodes : name => [
      for index, bridge in var.underlay_bridges : {
        bridge = bridge
        # Match guest ethN by list position; management eth0 is separate.
        mac_address = format("02:00:00:%02d:00:%02d", node.id, index + 1)
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
