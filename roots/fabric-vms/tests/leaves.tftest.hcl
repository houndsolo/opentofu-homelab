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

run "shared_settings_and_node_inventory" {
  command = plan
  variables {
    nodes = {
      proxmox = {
        first  = { id = 21, cpu_cores = 8 }
        second = { id = 22, cpu_cores = 12 }
      }
      proxmox_cluster = { pve = { endpoint_node = "first" } }
    }
    pve_leaf = merge(var.pve_leaf, {
      vm_config = merge(var.pve_leaf.vm_config, {
        hostname_prefix          = "leaf-"
        vm_id_offset             = 900
        management_prefix        = "10.30.0.0/24"
        management_cidr          = 24
        default_underlay_bridges = ["vmbr100"]
      })
    })
  }
  assert {
    condition     = length(output.leaf_vms) == 2 && output.leaf_vms.first.vm_id == 921 && output.leaf_vms.second.vm_id == 922
    error_message = "Each Proxmox node must get exactly one VM with the shared ID offset."
  }
  assert {
    condition     = output.leaf_vms.first.name == "leaf-first" && output.leaf_vms.first.node_name == "first" && output.leaf_vms.first.management_address == "10.30.0.21/24"
    error_message = "Shared naming and addressing settings must combine with the node identity."
  }
  assert {
    condition     = length(output.leaf_vms.first.network_devices) == 1 && output.leaf_vms.first.network_devices[0].bridge == "vmbr100"
    error_message = "All nodes must use the configured shared underlay bridges."
  }
}

run "reject_duplicate_node_ids" {
  command = plan
  variables {
    nodes = {
      proxmox = {
        first  = { id = 11, cpu_cores = 8 }
        second = { id = 11, cpu_cores = 12 }
      }
      proxmox_cluster = { pve = { endpoint_node = "first" } }
    }
  }
  expect_failures = [output.leaf_vms]
}
