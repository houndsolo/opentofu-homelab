locals {
  # Prometheus exporters bound to the management address, inside the management VRF.
  # frr-exporter always has the bgp6 collector (VyOS default); bgp-l2-vpn adds the
  # EVPN overlay sessions, and peer-hostname labels peers by their hostname.
  exporters = var.fabric.settings.leaf_prometheus_exporters

  monitoring_commands = local.exporters == null ? [] : concat(
    [
      for exporter in ["node-exporter", "frr-exporter"] :
      "set service monitoring prometheus ${exporter} listen-address '${local.management_ip}'"
    ],
    local.exporters.vrf == null ? [] : [
      for exporter in ["node-exporter", "frr-exporter"] :
      "set service monitoring prometheus ${exporter} vrf '${local.exporters.vrf}'"
    ],
    [
      "set service monitoring prometheus frr-exporter collector bgp-l2-vpn",
      "set service monitoring prometheus frr-exporter collector bgp peer-hostname",
    ],
  )
}
