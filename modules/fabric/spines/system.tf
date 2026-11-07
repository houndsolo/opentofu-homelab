resource "routeros_system_ntp_client" "main" {
  count   = length(var.fabric.settings.ntp_servers) > 0 ? 1 : 0
  enabled = true
  mode    = "unicast"
  servers = var.fabric.settings.ntp_servers
}

# The provider updates the built-in memory action by name on creation.
resource "routeros_system_logging_action" "memory" {
  name                = "memory"
  target              = "memory"
  memory_lines        = 10000
  memory_stop_on_full = false
}
