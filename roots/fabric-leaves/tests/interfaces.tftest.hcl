mock_provider "vyoscmd" {}

run "shared_vm_interface_bindings" {
  command = plan
  assert {
    condition = (
      output.leaf_specifications.fichina.fabric_macs.eth1 == "02:07:11:00:11:01" &&
      output.leaf_specifications.fichina.fabric_macs.eth3 == "02:07:11:00:11:03" &&
      output.interface_binding_commands.fichina == toset([
        for interface, mac in module.proxmox_fabric_macs.fabric_macs.fichina : "set interfaces ethernet ${interface} hw-id ${mac}"
      ])
    )
    error_message = "VyOS hw-id commands must use the shared MACs for the VM's ordered extra NICs."
  }
}

run "node_alias_and_generic_role" {
  command = plan
  variables {
    fabric = merge(var.fabric, {
      leaves = {
        guest = {
          role          = "proxmox"
          proxmox_node  = "venom"
          management_ip = "10.20.10.17"
          router_id     = "10.255.240.17"
          vtep_ipv6     = "fd69:255:240::17"
        }
        other = {
          management_ip = "192.0.2.1"
          router_id     = "10.255.240.1"
          vtep_ipv6     = "fd69:255:240::1"
        }
      }
    })
  }
  assert {
    condition     = output.leaf_specifications.guest.fabric_macs.eth1 == "02:07:17:00:17:01" && length(output.interface_binding_commands.guest) == 3
    error_message = "A renamed leaf must resolve its MACs using proxmox_node."
  }
  assert {
    condition     = length(output.leaf_specifications.other.fabric_macs) == 0 && length(output.interface_binding_commands.other) == 0
    error_message = "Other roles must not receive Proxmox NIC bindings."
  }
}

run "reject_unknown_proxmox_node" {
  command = plan
  variables {
    fabric = merge(var.fabric, {
      leaves = {
        missing = {
          role          = "proxmox"
          management_ip = "192.0.2.99"
          router_id     = "10.255.240.99"
          vtep_ipv6     = "fd69:255:240::99"
        }
      }
    })
  }
  expect_failures = [output.leaf_specifications]
}
