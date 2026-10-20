mock_provider "vyoscmd" {}

variables {
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
