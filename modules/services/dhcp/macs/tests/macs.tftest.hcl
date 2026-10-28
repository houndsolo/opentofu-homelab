# DHCP is enabled on VLANs 12, 2 and 8; VLAN 9 has no dhcp block.
variables {
  vms = { dhcp01 = { vm_id = 6701 }, dhcp02 = { vm_id = 6702 } }
  vnis = [{
    roles     = ["proxmox"]
    vni       = 10000
    vrf       = "services"
    vrf_table = 10000
    vlan_id   = 1000
    l2 = {
      v12 = { vni = 9012, vlan_id = 12, anycast_gw_ip = "10.12.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:0c", dhcp = {} }
      v2  = { vni = 9002, vlan_id = 2, anycast_gw_ip = "10.2.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:02", dhcp = {} }
      v8  = { vni = 9008, vlan_id = 8, anycast_gw_ip = "10.8.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:08", dhcp = {} }
      v9  = { vni = 9009, vlan_id = 9, anycast_gw_ip = "10.9.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:09" }
    }
  }]
}

run "dhcp_mac_identity_and_order" {
  command = plan
  assert {
    condition = (
      length(output.network_devices.dhcp01) == 3 &&
      output.network_devices.dhcp01[0].vlan_id == 2 &&
      output.network_devices.dhcp01[1].bridge == "vmbr4000" &&
      output.interface_macs.dhcp01.eth2 == "02:00:00:67:01:08" &&
      output.interface_macs.dhcp02.eth2 == "02:00:00:67:02:08" &&
      output.interface_macs.dhcp01.eth3 == "02:00:00:67:01:12" &&
      !contains(keys(output.interface_macs.dhcp01), "eth0")
    )
    error_message = "Use sorted DHCP-enabled VLAN NICs, distinct peer octets, decimal-looking VLANs, and no eth0 binding."
  }
}

run "new_vlan_preserves_existing_vlan_mac" {
  command = plan
  variables {
    vnis = [{
      roles     = ["proxmox"]
      vni       = 10000
      vrf       = "services"
      vrf_table = 10000
      vlan_id   = 1000
      l2 = {
        v12 = { vni = 9012, vlan_id = 12, anycast_gw_ip = "10.12.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:0c", dhcp = {} }
        v2  = { vni = 9002, vlan_id = 2, anycast_gw_ip = "10.2.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:02", dhcp = {} }
        v6  = { vni = 9006, vlan_id = 6, anycast_gw_ip = "10.6.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:06", dhcp = {} }
        v8  = { vni = 9008, vlan_id = 8, anycast_gw_ip = "10.8.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:08", dhcp = {} }
      }
    }]
  }
  assert {
    condition     = output.interface_macs.dhcp01.eth3 == "02:00:00:67:01:08"
    error_message = "Adding VLAN 6 changes eth indices but must preserve VLAN 8's MAC."
  }
}

run "reject_vlan_over_one_decimal_octet" {
  command = plan
  variables {
    vnis = [{
      roles     = ["proxmox"]
      vni       = 10000
      vrf       = "services"
      vrf_table = 10000
      vlan_id   = 1000
      l2 = {
        v100 = { vni = 9100, vlan_id = 100, anycast_gw_ip = "10.100.0.1", anycast_gw_cidr = 16, anycast_mac = "00:00:5e:00:01:64", dhcp = {} }
      }
    }]
  }
  expect_failures = [output.network_devices]
}

run "reject_duplicate_peer_ids" {
  command = plan
  variables { vms = { one = { vm_id = 6701 }, two = { vm_id = 6701 } } }
  expect_failures = [var.vms]
}
