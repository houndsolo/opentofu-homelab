output "specification" {
  value = merge(var.leaf, {
    fabric_macs = var.fabric_macs
    router_id   = local.router_id
    vtep_ipv6   = local.vtep_ipv6
  })
}

output "interface_binding_commands" {
  value = toset(local.interface_binding_commands)
}

output "vni_specification" {
  value = {
    vrfs     = local.role_vrfs
    l2vnis   = local.l2vnis
    all_vnis = local.all_vnis
  }
}

output "commands" {
  description = "Desired VyOS commands for inspection and mocked plan tests."
  value       = vyoscmd_commands.this.commands
}
