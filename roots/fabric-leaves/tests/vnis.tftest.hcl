mock_provider "vyoscmd" {}

run "role_vni_selection_and_commands" {
  command = plan

  assert {
    condition = (
      toset(keys(output.vni_specifications.fichina.vrfs)) == toset(["lylat_infra", "lylat_lan", "lylat_service"]) &&
      toset(keys(output.vni_specifications.fichina.l2vnis)) == toset(["9002", "9006", "9008", "9009", "9010", "9011"]) &&
      length(output.vni_specifications.fichina.all_vnis) == 9
    )
    error_message = "Proxmox leaves must receive only their three VRFs and six nested L2VNIs."
  }

  assert {
    condition = (
      toset(keys(output.vni_specifications.external_l2_01.vrfs)) == toset(["lylat_ai", "lylat_lan"]) &&
      length(output.vni_specifications.external_l2_01.all_vnis) == 6 &&
      toset(keys(output.vni_specifications.external_l3_01.vrfs)) == toset(["lylat_external"]) &&
      length(output.vni_specifications.external_l3_01.l2vnis) == 0
    )
    error_message = "External L2 and border leaves must receive the VNIs assigned to their roles."
  }

  assert {
    condition = alltrue([
      for command in [
        "set interfaces vxlan vxlan0 vlan-to-vni 11 vni '9011'",
        "set interfaces vxlan vxlan0 vlan-to-vni 69 vni '6900'",
        "set interfaces pseudo-ethernet peth9011 address '10.11.0.5/16'",
        "set interfaces pseudo-ethernet peth9011 vrf 'lylat_lan'",
        "set protocols bgp address-family l2vpn-evpn vni 9011 rd '10.255.240.11:9011'",
        "set vrf name lylat_lan protocols bgp address-family l2vpn-evpn route-target export '700:6900'",
        "set policy prefix-list PL-LYLAT_LAN-L2VNI-SUBNETS rule 110 prefix '10.11.0.0/16'",
        "set interfaces dummy dum240 address 'fd69:255:240::11/128'",
      ] : contains(output.commands.fichina, command)
    ])
    error_message = "The resource must include VLAN mappings, gateways, EVPN RDs/RTs, subnet policies and VTEP addressing."
  }

  assert {
    condition = (
      contains(output.commands.external_l3_01, "set vrf name lylat_external protocols bgp address-family ipv4-unicast route-target vpn export '700:6666'") &&
      contains(output.commands.external_l3_01, "set vrf name lylat_external protocols bgp address-family ipv4-unicast route-target vpn import '700:6900 700:6600 700:6200'") &&
      !contains(output.commands.external_l3_01, "set policy route-map RM-LYLAT_EXTERNAL-CONNECTED-TO-BGP rule 10 match ip address prefix-list 'PL-LYLAT_EXTERNAL-L2VNI-SUBNETS'")
    )
    error_message = "Border VRFs need their border RTs and must not reference a nonexistent L2 subnet prefix-list."
  }
}

run "empty_inventory_preserves_system_and_bindings" {
  command = plan
  variables {
    vnis = []
  }
  assert {
    condition = (
      length(output.vni_specifications.fichina.all_vnis) == 0 &&
      length(output.commands.fichina) == 7 &&
      length(output.commands.external_l3_01) == 4
    )
    error_message = "Empty VNI inventory must add no overlay configuration."
  }
}

run "reject_duplicate_vni" {
  command = plan
  variables {
    vnis = concat(var.vnis, [merge(var.vnis[0], {
      vrf       = "duplicate"
      vrf_table = 6667
      vlan_id   = 1001
    })])
  }
  expect_failures = [var.vnis]
}
