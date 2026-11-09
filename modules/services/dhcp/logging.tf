locals {
  # Remote syslog to the Loki/Alloy receiver. include-timezone makes VyOS's rsyslog
  # send RFC 5424 (RSYSLOG_SyslogProtocol23Format); over TCP, octet-counted framing
  # keeps multi-line messages intact.
  syslog_commands = var.syslog == null ? [] : concat(
    [
      "set system syslog remote ${var.syslog.host} facility ${var.syslog.facility} level '${var.syslog.level}'",
      "set system syslog remote ${var.syslog.host} port '${var.syslog.port}'",
      "set system syslog remote ${var.syslog.host} protocol '${var.syslog.protocol}'",
      "set system syslog remote ${var.syslog.host} format include-timezone",
    ],
    var.syslog.protocol == "tcp" ? [
      "set system syslog remote ${var.syslog.host} format octet-counted",
    ] : [],
    var.syslog.vrf == null ? [] : [
      "set system syslog remote ${var.syslog.host} vrf '${var.syslog.vrf}'",
    ],
  )
}
