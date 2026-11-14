# Backend HA (var.backends): every backend runs the same Prometheus/exporters/Telegraf
# stack (main.tf). This file adds what ties them together:
#   - the Alertmanager cluster (gossip on 9094 over the HA VLAN, ha_monitor);
#   - keepalived (backend_vrrp): one VRRP instance, adverts unicast over the HA VLAN, VIPs
#     on the monitoring network (the C9800s' telemetry receiver, telemetry.tf) and the backend
#     VLAN (Grafana's Alertmanager datasource, Prometheus's wlc scrape). The containers publish on
#     the VIPs too, which needs net.ipv4.ip_nonlocal_bind (the VIP is only on one backend at a time);
#   - the alert rules for all of that.
# Postgres (Grafana's database) stays on the primary only: a known single point of failure.
locals {
  # Name order with the primary first: VRRP priority (first election only, nopreempt).
  backend_order_ha = concat([local.primary], [for name in local.backend_names : name if name != local.primary])

  backend_ha_ready = length(var.backends) > 1 && alltrue([for b in values(var.backends) : b.ha_address != null])

  # Alertmanager cluster: gossip over the HA VLAN when every backend has an address there,
  # else over the backend VLAN. A single backend runs without a gossip listener.
  am_cluster_enabled = length(var.backends) > 1
  am_gossip          = { for name, b in var.backends : name => local.backend_ha_ready ? b.ha_address : b.backend_address }
  am_cluster_publish = {
    for name in local.backend_names : name => local.am_cluster_enabled ? [
      "${local.am_gossip[name]}:9094:9094/tcp",
      "${local.am_gossip[name]}:9094:9094/udp",
    ] : []
  }
  am_cluster_args = {
    for name in local.backend_names : name => local.am_cluster_enabled ? concat([
      "--cluster.listen-address=0.0.0.0:9094",
      "--cluster.advertise-address=${local.am_gossip[name]}:9094",
      "--cluster.label=lylat-alertmanager", # ignores gossip from any other cluster
    ], [for peer in local.backend_names : "--cluster.peer=${local.am_gossip[peer]}:9094" if peer != name]) : ["--cluster.listen-address="]
  }
  # Every Prometheus (and the Loki ruler) sends to every Alertmanager; the cluster dedups.
  alertmanager_targets = [for name in local.backend_names : "${var.backends[name].backend_address}:9093"]

  # keepalived.
  backend_vrrp_enabled   = nonsensitive(var.backend_vrrp != null) && local.backend_ha_ready && alltrue([for b in values(var.backends) : b.interfaces != null])
  backend_vip_monitoring = local.backend_vrrp_enabled ? [split("/", nonsensitive(var.backend_vrrp.vips.monitoring))[0]] : []
  backend_vip_backend    = local.backend_vrrp_enabled ? [split("/", nonsensitive(var.backend_vrrp.vips.backend))[0]] : []
  # Where Grafana reaches Alertmanager: the backend VIP, else the primary.
  backend_service_host = local.backend_vrrp_enabled ? local.backend_vip_backend[0] : local.back

  backend_keepalived_conf = {
    for i, name in local.backend_order_ha : name => local.backend_vrrp_enabled ? templatefile("${path.module}/templates/monitoring-keepalived.conf.tftpl", {
      host            = name
      router_id       = try(var.backend_vrrp.router_id, 0)
      priority        = max(150 - 50 * i, 10)
      backend_address = var.backends[name].backend_address
      ha_interface    = try(var.backends[name].interfaces.ha, "none")
      ha_address      = var.backends[name].ha_address
      peers           = [for peer in local.backend_names : var.backends[peer].ha_address if peer != name]
      # The WLC Telegraf (telemetry.tf) receives on the monitoring VIP: keepalived checks it too.
      check_telegraf = local.wlc_enabled && contains(local.wlc_backends, name)
      vips = [
        { cidr = try(var.backend_vrrp.vips.monitoring, ""), interface = try(var.backends[name].interfaces.monitoring, "none") },
        { cidr = try(var.backend_vrrp.vips.backend, ""), interface = try(var.backends[name].interfaces.backend, "none") },
      ]
    }) : null
  }

  backend_sysctl = "# Managed by OpenTofu (monitoring-config). Local edits are overwritten.\n# Podman binds published ports, also on the keepalived VIPs, which only one backend holds.\nnet.ipv4.ip_nonlocal_bind = 1\n"

  backend_ha_packages = local.backend_vrrp_enabled ? ["keepalived"] : []
  backend_ha_dirs     = local.backend_vrrp_enabled ? [{ path = "/etc/keepalived", mode = "0755", owner = "root" }] : []
  backend_ha_files = {
    for name in local.backend_names : name => local.backend_vrrp_enabled ? [
      # Restarting the containers that publish on the VIPs picks up the sysctl (post_install applies it first).
      { path = "/etc/sysctl.d/90-monitoring-vip.conf", mode = "0644", owner = "root", content = local.backend_sysctl, restart = ["telegraf", "alertmanager"], reload = [] },
      { path = "/etc/keepalived/keepalived.conf", mode = "0600", owner = "root", content = local.backend_keepalived_conf[name], restart = [], reload = ["keepalived"] },
    ] : []
  }
  backend_ha_validations = local.backend_vrrp_enabled ? [
    "if command -v keepalived >/dev/null; then keepalived -t -f \"$root/etc/keepalived/keepalived.conf\"; else echo \"keepalived not installed yet: config test skipped\"; fi",
  ] : []
  backend_ha_post_install = local.backend_vrrp_enabled ? [
    "/usr/sbin/sysctl -q -p /etc/sysctl.d/90-monitoring-vip.conf",
    "systemctl enable --quiet keepalived.service",
  ] : []
  # keepalived last: it only takes the VIPs once Alertmanager (and the WLC Telegraf) answer.
  backend_ha_services = local.backend_vrrp_enabled ? ["keepalived"] : []

  # Retired components. The deploy stops and removes their Quadlets (state file); this removes
  # their config and env files (secrets: the InfluxDB operator token, the WLC Telegraf's write
  # tokens), which no prune covers. Idempotent: drop a line once both backends are clean.
  #   - the InfluxDB relay (VyOS Telegraf -> every backend's InfluxDB), retired 2026-11-13;
  #   - InfluxDB itself and the WLC Telegraf's InfluxDB outputs, retired 2026-11-14. Its data
  #     (${local.backend_data}/influxdb) is NOT removed here: delete it by hand once the history
  #     is confirmed in Mimir (or after a final backup).
  backend_retired_cleanup = [
    "if [ -e ${local.backend_conf}/influx-relay ] || [ -e ${local.backend_conf}/influx-relay.env ]; then rm -rf ${local.backend_conf}/influx-relay ${local.backend_conf}/influx-relay.env; echo \"removed the retired influx-relay config\"; fi",
    "if [ -e ${local.backend_conf}/influxdb.env ] || [ -e ${local.backend_conf}/telegraf.env ]; then rm -f ${local.backend_conf}/influxdb.env ${local.backend_conf}/telegraf.env; echo \"removed the retired InfluxDB env files\"; fi",
  ]

  backend_rules = length(var.backends) > 1 ? [{
    name = "monitoring-ha"
    rules = concat(
      local.am_cluster_enabled ? [{
        alert       = "AlertmanagerClusterDegraded"
        expr        = "min by (host) (alertmanager_cluster_members{job=\"alertmanager\"}) < ${length(var.backends)}"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Alertmanager on {{ $labels.host }} sees {{ $value }} of ${length(var.backends)} cluster members" }
      }] : [],
      [for net, ip in { monitoring = local.backend_vip_monitoring, backend = local.backend_vip_backend } : {
        alert                      = "MonitoringVIPNotHeldOnce"
        expr                       = "count(node_network_address_info{job=\"node\", role=\"monitoring\", address=\"${ip[0]}\"}) != 1 or absent(node_network_address_info{job=\"node\", role=\"monitoring\", address=\"${ip[0]}\"})"
        for                        = "2m"
        labels                     = { severity = "critical", vip = ip[0], network = net }
        annotations                = { summary = "Monitoring VIP ${ip[0]} (${net}) is held by {{ $value }} backends instead of exactly one" }
      } if length(ip) > 0],
    )
  }] : []
}
