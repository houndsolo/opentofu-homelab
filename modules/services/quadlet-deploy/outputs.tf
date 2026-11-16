output "script" {
  description = "The deploy script for this VM (run as root). Sensitive: file contents are embedded."
  value       = local.script
  sensitive   = true
}
