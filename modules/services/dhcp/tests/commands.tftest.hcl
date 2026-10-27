mock_provider "vyoscmd" {}

variables {
  ha_subnet = "10.6.67.0/24"
  ha = {
    role                = "primary"
    address_slot        = 1
    peer_slot           = 2
    peer_name           = "dhcp02"
    local_management_ip = "10.20.67.1"
    peer_management_ip  = "10.20.67.2"
  }
  name          = "dhcp01"
  management_ip = "10.20.67.1"
  fabric_macs = {
    eth1 = "02:00:00:67:01:02"
    eth2 = "02:00:00:67:01:06"
  }
}

run "bind_only_data_interfaces" {
  command = plan
  assert {
    condition = (
      contains(vyoscmd_commands.this.commands, "set interfaces ethernet eth1 hw-id 02:00:00:67:01:02") &&
      contains(vyoscmd_commands.this.commands, "set interfaces ethernet eth2 hw-id 02:00:00:67:01:06") &&
      alltrue([for command in vyoscmd_commands.this.commands : !strcontains(command, "ethernet eth0 ")]) &&
      vyoscmd_commands.this.endpoint == "https://10.20.67.1"
    )
    error_message = "Bind data NICs using shared MACs; never change the OOB management interface."
  }
}

run "configure_data_addresses" {
  command = plan
  variables {
    interface_addresses = { eth1 = "10.2.67.1/16", eth2 = "10.6.67.1/16" }
  }
  assert {
    condition = (
      contains(vyoscmd_commands.this.commands, "set interfaces ethernet eth1 address '10.2.67.1/16'") &&
      contains(vyoscmd_commands.this.commands, "set interfaces ethernet eth2 address '10.6.67.1/16'") &&
      alltrue([for command in vyoscmd_commands.this.commands : !strcontains(command, "ethernet eth0 ")])
    )
    error_message = "Set the derived VLAN addresses while leaving management untouched."
  }
}

run "scope_options_override_defaults" {
  command = plan
  variables {
    vnis = [{
      roles     = ["proxmox"]
      vni       = 6200
      vrf       = "test"
      vrf_table = 6200
      vlan_id   = 62
      l2 = {
        "2" = {
          vni             = 9002
          vlan_id         = 2
          anycast_gw_ip   = "10.2.0.5"
          anycast_gw_cidr = 16
          anycast_mac     = "bc:24:11:00:62:00"
          dhcp = {
            scope = {
              ranges        = { "0" = { start = "10.2.5.1", stop = "10.2.5.99" } }
              authoritative = false
              lease_seconds = 3600
              domain_name   = "lab.example"
              domain_search = []
              name_servers  = ["9.9.9.9"]
            }
          }
        }
      }
    }]
  }
  assert {
    condition = (
      contains(output.commands, "set service dhcp-server shared-network-name l2vni9002 subnet 10.2.0.0/16 lease '3600'") &&
      contains(output.commands, "set service dhcp-server shared-network-name l2vni9002 subnet 10.2.0.0/16 option name-server '9.9.9.9'") &&
      !contains(output.commands, "set service dhcp-server shared-network-name l2vni9002 authoritative") &&
      !strcontains(join("\n", output.commands), "option domain-search")
    )
    error_message = "Respect explicit scope overrides, including false authoritative and an empty search list."
  }
}
