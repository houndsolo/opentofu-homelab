# Model-driven telemetry from the Cisco C9800 WLCs (var.wlc_telemetry; null leaves it out).
#
# The WLCs dial out (gRPC, kvGPB, yang-push periodic subscriptions) to Telegraf's
# cisco_telemetry_mdt listener, published on the monitoring-network address of each
# backend in var.wlc_telemetry.backends (every subscription has one named receiver per
# backend; the WLCs' Vlan5 is on the same 10.5/16, so no router or firewall sits in between).
# Each Telegraf writes to its own backend's InfluxDB bucket var.wlc_telemetry.bucket with
# that backend's write-only token (made in the root), reaching InfluxDB by container name
# on the monitoring Podman network. Its own internal_* metrics go to Prometheus
# (prometheus_client output on the backend VLAN, job "telegraf") rather than to InfluxDB.
#
# With two or more such backends and keepalived (backend_vrrp), Telegraf also listens on the
# monitoring VIP and every Telegraf writes to the bucket on EVERY backend (the local one by
# container name, peers over the backend VLAN, each with that backend's token). IOS XE only
# keeps one receiver of a subscription active (a second named receiver is a standby, checked
# 2026-11-10), so the WLCs send to the VIP once (receiver "mon01", host = the VIP) and the
# VIP holder's Telegraf fans out.
#
# Measurements keep the YANG encoding paths as names (no aliases), e.g.
# "Cisco-IOS-XE-wireless-client-oper:client-oper-data/traffic-stats": the dashboards
# use them as they are, and so would grafana.com's InfluxQL dashboard 12468.
#
# Known WLC-side gap (IOS XE 26.01.1, checked 2026-11-10): in every periodic kvGPB update
# after the first one on a connection, the WLC leaves out the first (lowest-key) entry of
# each multi-entry wireless oper list: radio slot 0 (2.4 GHz), the lowest WLAN id, the lowest
# client MAC. Those rows are missing on the wire (packet capture of the gRPC stream), and a
# NETCONF yang-push subscription to the same xpaths has them. Telegraf is not the cause: fed
# the same messages with those rows added, this input config writes them, zero-valued keys
# (radio_slot_id=0, wlan_id=0) included. No Telegraf setting can bring them back; that has to
# be fixed on the WLC (see dashboards/wireless.py, FIRST_ENTRY_GAP).
locals {
  wlc_enabled = var.wlc_telemetry != null
  # Backends running Telegraf: each WLC subscription has one receiver per backend, and
  # each Telegraf writes to its own InfluxDB.
  wlc_backends = local.wlc_enabled ? [for name in local.backend_names : name if contains(var.wlc_telemetry.backends, name)] : []
  wlc_port     = try(var.wlc_telemetry.port, 57500)
  wlc_conf     = "${local.backend_conf}/telegraf"
  # Fan-out through the monitoring VIP (see above).
  wlc_vip = local.backend_vrrp_enabled && length(local.wlc_backends) > 1
  # Where each Telegraf writes: every Telegraf backend, or only its own.
  wlc_targets = { for host in local.backend_names : host => local.wlc_vip ? local.wlc_backends : [host] }
  # The local token stays INFLUX_TOKEN; peers' are INFLUX_TOKEN_<NAME>.
  wlc_env_var = { for host in local.backend_names : host => { for t in local.backend_names : t => t == host ? "INFLUX_TOKEN" : "INFLUX_TOKEN_${upper(replace(t, "/[^A-Za-z0-9]/", "_"))}" } }

  telegraf_conf = { for host in local.backend_names : host => local.wlc_enabled ? join("\n", concat([
    "# Managed by OpenTofu (monitoring-config). Local edits are overwritten.",
    "[agent]",
    "  interval = \"30s\"", # internal metrics; the WLCs push on their own schedule
    "  flush_interval = \"10s\"",
    "  metric_batch_size = 5000",
    "  metric_buffer_limit = 200000", # per output: rides out a peer's restart or short outage
    "  omit_hostname = true",         # host would be the container id; the WLCs' data carries source
    "  skip_processors_after_aggregators = true",
    "",
    "[[inputs.cisco_telemetry_mdt]]",
    "  transport = \"grpc\"",
    "  service_address = \":${local.wlc_port}\"",
    "  max_msg_size = 16777216", # 16 MiB: whole oper lists (clients, APs) arrive in one message
    # Nested YANG lists whose key isn't a tag otherwise: without these, the per-channel
    # RRM noise and foreign interference entries collapse into one series per radio.
    "  embedded_tags = [",
    "    \"Cisco-IOS-XE-wireless-rrm-oper:rrm-oper-data/rrm-measurement/noise/noise/noise-data/chan\",",
    "    \"Cisco-IOS-XE-wireless-rrm-oper:rrm-oper-data/rrm-measurement/foreign/foreign/foreign-data/chan\",",
    "  ]",
    # The per-process CPU list flattens into colliding fields (only the last process survives).
    "  fieldexclude = [\"cpu_usage_processes/*\"]",
    "",
    "[[inputs.internal]]",
    "",
    ], flatten([for target in local.wlc_targets[host] : [
      "[[outputs.influxdb_v2]]",
      "  alias = \"${target}\"",
      "  urls = [\"${target == host ? "http://influxdb:8086" : "http://${var.backends[target].backend_address}:8086"}\"]",
      "  token = \"$${${local.wlc_env_var[host][target]}}\"", # telegraf.env
      "  organization = \"${var.settings.influxdb_org}\"",
      "  bucket = \"${try(var.wlc_telemetry.bucket, "")}\"",
      "  namedrop = [\"internal_*\"]",
      "",
    ]]), [
    "[[outputs.prometheus_client]]",
    "  listen = \":9273\"",
    "  namepass = [\"internal_*\"]",
    "",
  ])) : "" }

  # Always defined (main.tf filters it out unless enabled): a conditional with {} would
  # need identical object types.
  wlc_container = {
    for host, b in var.backends : host => {
      telegraf = {
        description = "Telegraf: Cisco MDT (gRPC dial-out) from the C9800 WLCs -> InfluxDB"
        image       = var.images.telegraf
        # Its own metrics on the backend VLAN too: every Prometheus replica scrapes every Telegraf.
        # On the VIP too in fan-out mode (net.ipv4.ip_nonlocal_bind, backends.tf).
        publish = concat(
          ["${b.monitoring_address}:${local.wlc_port}:${local.wlc_port}"],
          [for vip in(local.wlc_vip ? local.backend_vip_monitoring : []) : "${vip}:${local.wlc_port}:${local.wlc_port}"],
          ["${b.backend_address}:9273:9273"],
        )
        volumes   = ["${local.wlc_conf}:/etc/telegraf:ro"]
        env_files = ["${local.backend_conf}/telegraf.env"]
        # As root, the image's entrypoint gives the binary cap_net_raw (file capability),
        # which Podman's default capability set refuses to exec. Both ports are unprivileged.
        user   = "telegraf"
        reload = true
      }
    }
  }

  wlc_files = {
    for host in local.backend_names : host => contains(local.wlc_backends, host) ? [
      { path = "${local.wlc_conf}/telegraf.conf", mode = "0644", owner = "root", content = local.telegraf_conf[host], restart = [], reload = ["telegraf"] },
      {
        path    = "${local.backend_conf}/telegraf.env"
        mode    = "0600"
        owner   = "root"
        content = join("", [for t in local.wlc_targets[host] : "${local.wlc_env_var[host][t]}=${try(coalesce(var.wlc_telemetry_tokens[t]), "missing")}\n"])
        restart = ["telegraf"]
        reload  = []
      },
    ] : []
  }

  wlc_dirs = { for host in local.backend_names : host => contains(local.wlc_backends, host) ? [{ path = local.wlc_conf, mode = "0755", owner = "root" }] : [] }

  wlc_validations = {
    for host in local.backend_names : host => contains(local.wlc_backends, host) ? [
      "podman run --rm --network=none --user 0 --entrypoint telegraf -v \"$root${local.wlc_conf}:/etc/telegraf:ro\" '${var.images.telegraf}' config check --config /etc/telegraf/telegraf.conf",
    ] : []
  }

  # The gRPC listener answers plain HTTP/2 (with 415), so curl proves the published port works.
  wlc_health = {
    for host, b in var.backends : host => contains(local.wlc_backends, host) ? [
      "curl -sS -o /dev/null --max-time 3 --http2-prior-knowledge http://${b.monitoring_address}:${local.wlc_port}/",
      "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:9273/metrics",
    ] : []
  }

  wlc_scrape_configs = local.wlc_enabled && length(local.wlc_backends) > 0 ? [{
    job_name       = "telegraf"
    static_configs = [for host in local.wlc_backends : { targets = ["${var.backends[host].backend_address}:9273"], labels = { host = host, role = "wlc-telemetry" } }]
  }] : []

  wlc_rules = length(local.wlc_scrape_configs) > 0 ? [{
    name = "wlc-telemetry"
    rules = [
      # In fan-out mode only the VIP holder receives, so the sum is over every Telegraf.
      local.wlc_vip ? {
        alert       = "WlcTelemetryStopped"
        expr        = "sum(rate(internal_gather_metrics_gathered{job=\"telegraf\", input=\"cisco_telemetry_mdt\"}[10m])) == 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "No Telegraf has received C9800 telemetry for 20 minutes (the WLCs send to the monitoring VIP)" }
        } : {
        alert       = "WlcTelemetryStopped"
        expr        = "sum by (host) (rate(internal_gather_metrics_gathered{job=\"telegraf\", input=\"cisco_telemetry_mdt\"}[10m])) == 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Telegraf on {{ $labels.host }} has received no C9800 telemetry for 20 minutes" }
      },
      {
        alert       = "WlcTelemetryWriteDropping"
        expr        = "sum by (host, alias) (increase(internal_write_metrics_dropped{job=\"telegraf\"}[15m])) > 0"
        for         = "5m"
        labels      = { severity = "warning" }
        annotations = { summary = "Telegraf (WLC telemetry) on {{ $labels.host }} dropped writes for {{ $labels.alias }} (buffer full)" }
      },
    ]
  }] : []
}
