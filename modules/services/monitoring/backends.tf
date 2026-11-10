# Backend HA (var.backends): every backend runs the same Prometheus/exporters/InfluxDB
# stack (main.tf). This file adds what ties them together:
#   - the Alertmanager cluster (gossip on 9094 over the HA VLAN, ha_monitor);
#   - keepalived (backend_vrrp): one VRRP instance, adverts unicast over the HA VLAN, VIPs
#     on the monitoring network (InfluxDB, the relay) and the backend VLAN (Grafana's
#     InfluxDB and Alertmanager datasources). The containers publish on the VIPs too,
#     which needs net.ipv4.ip_nonlocal_bind (the VIP is only on one backend at a time);
#   - the InfluxDB relay (influx_relay): Telegraf listening for InfluxDB v2 writes and
#     copying them into every backend's InfluxDB, for writers that take one URL (VyOS);
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
  # Only auth_pass is secret: whether keepalived is on and the VIPs aren't.
  backend_vrrp_enabled   = nonsensitive(var.backend_vrrp != null) && local.backend_ha_ready && alltrue([for b in values(var.backends) : b.interfaces != null])
  backend_vip_monitoring = local.backend_vrrp_enabled ? [split("/", nonsensitive(var.backend_vrrp.vips.monitoring))[0]] : []
  backend_vip_backend    = local.backend_vrrp_enabled ? [split("/", nonsensitive(var.backend_vrrp.vips.backend))[0]] : []
  # Where Grafana reaches InfluxDB and Alertmanager: the backend VIP, else the primary.
  backend_service_host = local.backend_vrrp_enabled ? local.backend_vip_backend[0] : local.back

  backend_keepalived_conf = {
    for i, name in local.backend_order_ha : name => local.backend_vrrp_enabled ? templatefile("${path.module}/templates/monitoring-keepalived.conf.tftpl", {
      host            = name
      router_id       = try(var.backend_vrrp.router_id, 0)
      priority        = max(150 - 50 * i, 10)
      auth_pass       = try(var.backend_vrrp.auth_pass, "")
      backend_address = var.backends[name].backend_address
      ha_interface    = try(var.backends[name].interfaces.ha, "none")
      ha_address      = var.backends[name].ha_address
      peers           = [for peer in local.backend_names : var.backends[peer].ha_address if peer != name]
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
      { path = "/etc/sysctl.d/90-monitoring-vip.conf", mode = "0644", owner = "root", content = local.backend_sysctl, restart = ["influxdb", "alertmanager"], reload = [] },
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
  # keepalived last: it only takes the VIPs once InfluxDB and Alertmanager answer.
  backend_ha_services = local.backend_vrrp_enabled ? ["keepalived"] : []

  # InfluxDB relay.
  relay_enabled = var.influx_relay != null
  relay_port    = try(var.influx_relay.port, 8087)
  relay_bucket  = try(var.influx_relay.bucket, "")
  relay_conf    = "${local.backend_conf}/influx-relay"
  relay_targets = local.relay_enabled ? [for name in local.backend_names : name if contains(var.influx_relay.targets, name)] : []
  relay_secrets = var.influx_relay_secrets != null ? var.influx_relay_secrets : { listen_token = "", tokens = {} }
  relay_env_var = { for name in local.backend_names : name => "INFLUX_TOKEN_${upper(replace(name, "/[^A-Za-z0-9]/", "_"))}" }

  relay_telegraf_conf = {
    for host in local.backend_names : host => local.relay_enabled ? join("\n", concat([
      "# Managed by OpenTofu (monitoring-config). Local edits are overwritten.",
      "# InfluxDB write relay: writes accepted here go to bucket \"${local.relay_bucket}\" on every listed backend.",
      "[agent]",
      "  interval = \"30s\"", # internal metrics only
      "  flush_interval = \"5s\"",
      "  metric_batch_size = 5000",
      "  metric_buffer_limit = 200000", # per output: rides out a peer's restart or short outage
      "  omit_hostname = true",
      "",
      "[[inputs.influxdb_v2_listener]]",
      "  service_address = \":${local.relay_port}\"",
      "  token = \"$${RELAY_LISTEN_TOKEN}\"", # influx-relay.env: the token the writers already use
      "  max_body_size = \"32MiB\"",
      "",
      "[[inputs.internal]]",
      "",
      ], flatten([for target in local.relay_targets : [
        "[[outputs.influxdb_v2]]",
        "  alias = \"${target}\"",
        # The local InfluxDB by container name, peers over the backend VLAN.
        "  urls = [\"${target == host ? "http://influxdb:8086" : "http://${var.backends[target].backend_address}:8086"}\"]",
        "  token = \"$${${local.relay_env_var[target]}}\"",
        "  organization = \"${var.settings.influxdb_org}\"",
        "  bucket = \"${local.relay_bucket}\"",
        "  namedrop = [\"internal_*\"]",
        "",
      ]]), [
      "[[outputs.prometheus_client]]",
      "  listen = \":9274\"",
      "  namepass = [\"internal_*\"]",
      # Only the relay's own internal metrics (no host tag: omit_hostname). The writers'
      # Telegraf internal_* (fw-wan's, host=fw-wan) would otherwise pass as the relay's.
      "  [outputs.prometheus_client.tagdrop]",
      "    host = [\"*\"]",
      "",
    ])) : ""
  }
  relay_env = join("", concat(
    ["RELAY_LISTEN_TOKEN=${local.relay_secrets.listen_token}\n"],
    [for target in local.relay_targets : "${local.relay_env_var[target]}=${try(coalesce(local.relay_secrets.tokens[target]), "missing")}\n"],
  ))

  # Always defined (main.tf filters it out unless enabled), like wlc_container.
  relay_container = {
    for host, b in var.backends : host => {
      influx-relay = {
        description = "Telegraf: InfluxDB write relay -> ${try(var.influx_relay.bucket, "")} on every backend"
        image       = var.images.telegraf
        publish = concat(
          ["${b.monitoring_address}:${local.relay_port}:${local.relay_port}"],
          [for vip in local.backend_vip_monitoring : "${vip}:${local.relay_port}:${local.relay_port}"],
          ["${b.backend_address}:9274:9274"],
        )
        volumes   = ["${local.relay_conf}:/etc/telegraf:ro"]
        env_files = ["${local.backend_conf}/influx-relay.env"]
        user      = "telegraf" # see the WLC Telegraf (telemetry.tf)
        reload    = true
      }
    }
  }
  relay_files = {
    for host in local.backend_names : host => local.relay_enabled ? [
      { path = "${local.relay_conf}/telegraf.conf", mode = "0644", owner = "root", content = local.relay_telegraf_conf[host], restart = [], reload = ["influx-relay"] },
      { path = "${local.backend_conf}/influx-relay.env", mode = "0600", owner = "root", content = local.relay_env, restart = ["influx-relay"], reload = [] },
    ] : []
  }
  relay_dirs = local.relay_enabled ? [{ path = local.relay_conf, mode = "0755", owner = "root" }] : []
  relay_validations = local.relay_enabled ? [
    "podman run --rm --network=none --user 0 --entrypoint telegraf -v \"$root${local.relay_conf}:/etc/telegraf:ro\" '${var.images.telegraf}' config check --config /etc/telegraf/telegraf.conf",
  ] : []
  # Any HTTP answer (404 on /) proves the listener's published port works.
  relay_health = {
    for host, b in var.backends : host => local.relay_enabled ? [
      "curl -sS -o /dev/null --max-time 3 http://${b.monitoring_address}:${local.relay_port}/",
      "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:9274/metrics",
    ] : []
  }
  relay_scrape_configs = local.relay_enabled ? [{
    job_name       = "influx-relay"
    static_configs = [for name in local.backend_names : { targets = ["${var.backends[name].backend_address}:9274"], labels = { host = name } }]
  }] : []

  backend_rules = length(var.backends) > 1 || local.relay_enabled ? [{
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
      local.relay_enabled ? [
        {
          alert       = "InfluxRelayDropping"
          expr        = "sum by (host, alias) (increase(internal_write_metrics_dropped{job=\"influx-relay\"}[15m])) > 0"
          for         = "5m"
          labels      = { severity = "warning" }
          annotations = { summary = "InfluxDB relay on {{ $labels.host }} dropped writes for {{ $labels.alias }} (buffer full)" }
        },
        {
          alert       = "InfluxRelayBacklog"
          expr        = "max by (host, alias) (internal_write_buffer_size{job=\"influx-relay\"}) > 20000"
          for         = "15m"
          labels      = { severity = "warning" }
          annotations = { summary = "InfluxDB relay on {{ $labels.host }} can't write to {{ $labels.alias }}'s InfluxDB ({{ $value }} metrics queued)" }
        },
      ] : [],
    )
  }] : []
}
