locals {
  # Remote syslog to the Loki/Alloy receiver. include-timezone makes VyOS's rsyslog
  # send RFC 5424 (RSYSLOG_SyslogProtocol23Format); over TCP, octet-counted framing
  # keeps multi-line messages intact.
  syslog = var.fabric.settings.leaf_syslog

  syslog_commands = local.syslog == null ? [] : concat(
    [
      "set system syslog remote ${local.syslog.host} facility ${local.syslog.facility} level '${local.syslog.level}'",
      "set system syslog remote ${local.syslog.host} port '${local.syslog.port}'",
      "set system syslog remote ${local.syslog.host} protocol '${local.syslog.protocol}'",
      "set system syslog remote ${local.syslog.host} format include-timezone",
    ],
    local.syslog.protocol == "tcp" ? [
      "set system syslog remote ${local.syslog.host} format octet-counted",
    ] : [],
    local.syslog.vrf == null ? [] : [
      "set system syslog remote ${local.syslog.host} vrf '${local.syslog.vrf}'",
    ],
  )
}
