# Remote syslog to the Loki/Alloy receiver (fabric.settings.spine_syslog). Like the
# memory action in system.tf, the provider updates the built-in "remote" action by name.
# RouterOS's "syslog" format with BSD timestamps parses as RFC 3164; src-address stays
# 0.0.0.0, so the spine sends from the address of the route to the host.
locals {
  syslog = var.fabric.settings.spine_syslog
}

resource "routeros_system_logging_action" "remote" {
  count              = local.syslog == null ? 0 : 1
  name               = "remote"
  target             = "remote"
  remote             = local.syslog.host
  remote_port        = local.syslog.port
  remote_protocol    = "udp"
  remote_log_format  = "syslog"
  syslog_time_format = "bsd-syslog"
  syslog_facility    = local.syslog.facility
}

resource "routeros_system_logging" "remote" {
  for_each = local.syslog == null ? toset([]) : toset(local.syslog.topics)
  action   = routeros_system_logging_action.remote[0].name
  topics   = [each.key]
}
