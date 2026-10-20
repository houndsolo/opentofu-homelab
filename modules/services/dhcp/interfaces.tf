locals {
  # Add VyOS interface commands here. eth0 is management; generated data NICs
  # follow the VLAN order in roots/services-vms. Addresses are configured in VyOS.
  interface_commands = []
}
