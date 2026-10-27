variables {
  vms        = { dhcp01 = { vm_id = 6701 }, dhcp02 = { vm_id = 6702 } }
  dhcp_vlans = [12, 2, 8]
}

run "dhcp_mac_identity_and_order" {
  command = plan
  assert {
    condition = (
      output.network_devices.dhcp01[0].vlan_id == 2 &&
      output.network_devices.dhcp01[1].bridge == "vmbr4000" &&
      output.fabric_macs.dhcp01.eth2 == "02:00:00:67:01:08" &&
      output.fabric_macs.dhcp02.eth2 == "02:00:00:67:02:08" &&
      output.fabric_macs.dhcp01.eth3 == "02:00:00:67:01:12" &&
      !contains(keys(output.fabric_macs.dhcp01), "eth0")
    )
    error_message = "Use sorted VLAN NICs, distinct peer octets, decimal-looking VLANs, and no eth0 binding."
  }
}

run "new_vlan_preserves_existing_vlan_mac" {
  command = plan
  variables { dhcp_vlans = [2, 6, 8, 12] }
  assert {
    condition     = output.fabric_macs.dhcp01.eth3 == "02:00:00:67:01:08"
    error_message = "Adding VLAN 6 changes eth indices but must preserve VLAN 8's MAC."
  }
}

run "reject_vlan_over_one_decimal_octet" {
  command = plan
  variables { dhcp_vlans = [100] }
  expect_failures = [var.dhcp_vlans]
}

run "reject_duplicate_peer_ids" {
  command = plan
  variables { vms = { one = { vm_id = 6701 }, two = { vm_id = 6701 } } }
  expect_failures = [var.vms]
}
