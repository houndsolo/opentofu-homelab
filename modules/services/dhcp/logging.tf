locals {
  # Remote syslog to the Loki/Alloy receiver. include-timezone makes VyOS's rsyslog
  # send RFC 5424 (RSYSLOG_SyslogProtocol23Format); over TCP, octet-counted framing
  # keeps multi-line messages intact. Every host in `hosts` gets the same
  # stream (one per logging VM; Loki drops the identical copies).
  syslog_commands = var.syslog == null ? [] : flatten([
    for host in var.syslog.hosts : concat(
      [
        "set system syslog remote ${host} facility ${var.syslog.facility} level '${var.syslog.level}'",
        "set system syslog remote ${host} port '${var.syslog.port}'",
        "set system syslog remote ${host} protocol '${var.syslog.protocol}'",
        "set system syslog remote ${host} format include-timezone",
      ],
      var.syslog.protocol == "tcp" ? [
        "set system syslog remote ${host} format octet-counted",
      ] : [],
      var.syslog.vrf == null ? [] : [
        "set system syslog remote ${host} vrf '${var.syslog.vrf}'",
      ],
    )
  ])
}
