output "commands" {
  description = "Combined VyOS commands for plan review and tests."
  value       = vyoscmd_commands.this.commands
}
