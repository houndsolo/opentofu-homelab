locals {
  # Prometheus exporters bound to the management address, inside the management VRF.
  monitoring_commands = var.prometheus_exporters == null ? [] : concat(
    [
      for exporter in ["node-exporter", "frr-exporter"] :
      "set service monitoring prometheus ${exporter} listen-address '${var.management_ip}'"
    ],
    var.prometheus_exporters.vrf == null ? [] : [
      for exporter in ["node-exporter", "frr-exporter"] :
      "set service monitoring prometheus ${exporter} vrf '${var.prometheus_exporters.vrf}'"
    ],
  )
}
