variables {
  nodes            = { fichina = { id = 11 }, external = { id = 42 } }
  underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"]
}

run "decimal_leaf_macs" {
  command = plan
  assert {
    condition = (
      output.network_devices.fichina[0].mac_address == "02:00:00:11:40:01" &&
      output.network_devices.fichina[1].mac_address == "02:00:00:11:40:02" &&
      output.network_devices.fichina[2].mac_address == "02:00:00:11:40:00" &&
      output.fabric_macs.external.eth1 == "02:00:00:42:40:01" &&
      !contains(keys(output.fabric_macs.fichina), "eth0")
    )
    error_message = "Use decimal-looking node/bridge octets and exclude eth0."
  }
}

run "bridge_reordering_preserves_mac_identity" {
  command = plan
  variables { underlay_bridges = ["vmbr4000", "vmbr4001", "vmbr4002"] }
  assert {
    condition     = output.fabric_macs.fichina.eth1 == "02:00:00:11:40:00" && output.fabric_macs.fichina.eth2 == "02:00:00:11:40:01"
    error_message = "MAC belongs to node/bridge identity, while ethN follows VM NIC order."
  }
}

run "reject_oversized_node_octet" {
  command = plan
  variables { nodes = { invalid = { id = 100 } } }
  expect_failures = [var.nodes]
}
