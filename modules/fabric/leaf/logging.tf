locals {
  # Remote syslog to the Loki/Alloy receiver. include-timezone makes VyOS's rsyslog
  # send RFC 5424 (RSYSLOG_SyslogProtocol23Format); over TCP, octet-counted framing
  # keeps multi-line messages intact. Every host in `hosts` gets the same
  # stream (one per logging VM; Loki drops the identical copies).
  syslog = var.fabric.settings.leaf_syslog

  syslog_commands = local.syslog == null ? [] : flatten([
    for host in local.syslog.hosts : concat(
      [
        "set system syslog remote ${host} facility ${local.syslog.facility} level '${local.syslog.level}'",
        "set system syslog remote ${host} port '${local.syslog.port}'",
        "set system syslog remote ${host} protocol '${local.syslog.protocol}'",
        "set system syslog remote ${host} format include-timezone",
      ],
      local.syslog.protocol == "tcp" ? [
        "set system syslog remote ${host} format octet-counted",
      ] : [],
      local.syslog.vrf == null ? [] : [
        "set system syslog remote ${host} vrf '${local.syslog.vrf}'",
      ],
    )
  ])
}
