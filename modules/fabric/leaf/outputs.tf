output "specification" {
  description = "Intended leaf settings, including the shared MAC map."
  value       = local.specification
}

output "interface_binding_commands" {
  description = "VyOS commands managed for this leaf's interface bindings."
  value       = length(var.fabric_macs) > 0 ? vyoscmd_commands.interface_bindings[0].commands : toset([])
}
