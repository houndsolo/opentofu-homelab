mock_provider "proxmox" {}

run "reference_leaf_layout" {
  command = plan

  assert {
    condition     = length(output.leaf_vms) == 7 && output.leaf_vms.fichina.vm_id == 711 && output.leaf_vms.venom.vm_id == 717
    error_message = "The inventory must create seven leaves with the reference VM ID offset."
  }
  assert {
    condition     = output.leaf_vms.fichina.name == "vtep-fichina" && output.leaf_vms.fichina.node_name == "fichina" && output.leaf_vms.fichina.management_address == "10.20.10.11/16"
    error_message = "Leaf names, placement and management addresses must match the reference."
  }
  assert {
    condition = (
      join(",", [for nic in output.leaf_vms.fichina.network_devices : nic.bridge]) == "vmbr4001,vmbr4002,vmbr4000" &&
      output.leaf_vms.fichina.network_devices[0].mac_address == "02:07:11:00:11:01" &&
      output.leaf_vms.fichina.network_devices[2].mac_address == "02:07:11:00:11:03"
    )
    error_message = "Underlay NIC order and generated eth1/eth3 MACs must match the reference."
  }
}

run "leaf_overrides_and_physical_filter" {
  command = plan
  variables {
    pve_leaf = merge(var.pve_leaf, {
      leaves = {
        custom = {
          hypervisor_node    = "venom"
          id                 = 42
          hostname           = "custom-leaf"
          vm_id              = 942
          management_address = "10.20.10.142"
          underlay_bridges   = ["vmbr100"]
          fabric_macs        = { eth1 = "02:aa:bb:cc:dd:01" }
        }
        explicit = {
          hypervisor_node = "titania"
          id              = 43
          network_devices = [{ bridge = "vmbr200", vlan_id = 22, mac_address = "02:aa:bb:cc:dd:02", mtu = 9000 }]
        }
        physical = { hypervisor_node = "fortuna", id = 44, is_vm = false }
      }
    })
  }
  assert {
    condition     = length(output.leaf_vms) == 2 && !contains(keys(output.leaf_vms), "physical")
    error_message = "Physical leaves must never get VM resources."
  }
  assert {
    condition     = output.leaf_vms.custom.name == "custom-leaf" && output.leaf_vms.custom.vm_id == 942 && output.leaf_vms.custom.management_address == "10.20.10.142/16"
    error_message = "Explicit identity and address overrides must take precedence over defaults."
  }
  assert {
    condition     = output.leaf_vms.custom.network_devices[0].bridge == "vmbr100" && output.leaf_vms.custom.network_devices[0].mac_address == "02:aa:bb:cc:dd:01" && output.leaf_vms.explicit.network_devices[0].vlan_id == 22 && output.leaf_vms.explicit.network_devices[0].mtu == 9000
    error_message = "Per-leaf bridges, MACs and explicit NIC definitions must override the generated layout."
  }
}

run "reject_duplicate_vm_ids" {
  command = plan
  variables {
    pve_leaf = merge(var.pve_leaf, {
      leaves = {
        first  = { hypervisor_node = "venom", id = 11 }
        second = { hypervisor_node = "titania", id = 12, vm_id = 711 }
      }
    })
  }
  expect_failures = [var.pve_leaf]
}
