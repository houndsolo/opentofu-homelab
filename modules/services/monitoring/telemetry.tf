# Model-driven telemetry from the Cisco C9800 WLCs (var.wlc_telemetry; null leaves it out).
#
# The WLCs dial out (gRPC, kvGPB, yang-push periodic subscriptions) to Telegraf's
# cisco_telemetry_mdt listener, published on the monitoring-network address of each
# backend in var.wlc_telemetry.backends (the WLCs' Vlan5 is on the same 10.5/16, so no router or
# firewall sits in between). Telegraf turns the telemetry into wlc_* series for Prometheus (below);
# its own internal_* metrics go to Prometheus too (prometheus_client on the backend VLAN, job
# "telegraf"). Nothing is written to InfluxDB any more: its outputs and InfluxDB itself were retired
# on 2026-11-14 (the history is backfilled into Mimir).
#
# With two or more such backends and keepalived (backend_vrrp), Telegraf also listens on the
# monitoring VIP (keepalived checks this Telegraf, backends.tf). IOS XE only keeps one receiver of a
# subscription active (a second named receiver is a standby, checked 2026-11-10), so the WLCs send to
# the VIP once (receiver "mon01", host = the VIP) and only the VIP holder's Telegraf receives.
#
# Known WLC-side gap (IOS XE 26.01.1, checked 2026-11-10): in every periodic kvGPB update
# after the first one on a connection, the WLC leaves out the first (lowest-key) entry of
# each multi-entry wireless oper list: radio slot 0 (2.4 GHz), the lowest WLAN id, the lowest
# client MAC. Those rows are missing on the wire (packet capture of the gRPC stream), and a
# NETCONF yang-push subscription to the same xpaths has them. Telegraf is not the cause: fed
# the same messages with those rows added, this input config writes them, zero-valued keys
# (radio_slot_id=0, wlan_id=0) included. No Telegraf setting can bring them back; that has to
# be fixed on the WLC (see dashboards/wireless.py, FIRST_ENTRY_GAP).
#
# Prometheus: a clone of every telemetry metric is renamed to wlc_<short> (telegraf/wlc.star: e.g.
# wlc_client_traffic, wlc_ap_radio, wlc_rrm_noise_data), loses the path/subscription tags, gets
# source as host, and keeps its numeric fields; the string fields (names, SSIDs, states, IPs) become
# labels of a wlc_<short>_info series (value 1), except per-push timestamps; the client's
# current_rate becomes current_rate_mcs/_ss (or _mbps). The clones are served on
# :${local.wlc_prom_port} (prometheus_client); the YANG originals (named after their encoding paths)
# match no output any more and are dropped. The clone is kept so the wlc_* series stay exactly what
# the Mimir backfill replayed through this pipeline. Only the VIP holder receives, so both Prometheus
# replicas scrape the backend VIP (job "wlc"); the port is published on all local addresses, so a
# scrape of the VIP lands on the holder's Telegraf on either backend (a VIP-bound publish would also
# catch it on the non-holder and answer from the idle Telegraf).
locals {
  wlc_enabled = var.wlc_telemetry != null
  # Backends running Telegraf (each listens on its own monitoring address, and on the VIP).
  wlc_backends  = local.wlc_enabled ? [for name in local.backend_names : name if contains(var.wlc_telemetry.backends, name)] : []
  wlc_port      = try(var.wlc_telemetry.port, 57500)
  wlc_prom_port = 9275 # the wlc_* series (9273 = Telegraf's own metrics, 9274 = pvestatd)
  wlc_conf      = "${local.backend_conf}/telegraf"
  # The WLCs send to the monitoring VIP (see above).
  wlc_vip = local.backend_vrrp_enabled && length(local.wlc_backends) > 1

  telegraf_conf = { for host in local.backend_names : host => local.wlc_enabled ? join("\n", concat([
    "# Managed by OpenTofu (monitoring-config). Local edits are overwritten.",
    "[agent]",
    "  interval = \"30s\"", # internal metrics; the WLCs push on their own schedule
    "  flush_interval = \"10s\"",
    "  metric_batch_size = 5000",
    "  metric_buffer_limit = 200000",
    "  omit_hostname = true", # host would be the container id; the WLCs' data carries source
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
    # A renamed copy of every telemetry metric for Prometheus (see the top of this file).
    "[[processors.clone]]",
    "  order = 1",
    "  namepass = [\"Cisco-IOS-XE-*\"]",
    "  name_prefix = \"wlc_\"",
    "",
    "[[processors.starlark]]",
    "  order = 2",
    "  namepass = [\"wlc_*\"]",
    "  script = \"/etc/telegraf/wlc.star\"",
    "",
    "[[outputs.prometheus_client]]",
    "  listen = \":9273\"",
    "  namepass = [\"internal_*\"]",
    "",
    "[[outputs.prometheus_client]]",
    "  alias = \"wlc\"",
    "  listen = \":${local.wlc_prom_port}\"",
    "  namepass = [\"wlc_*\"]",
    "  metric_version = 2",
    "  string_as_label = false",
    "  expiration_interval = \"150s\"", # subscriptions push every 30 s or 60 s
    "",
  ])) : "" }

  # Always defined (main.tf filters it out unless enabled): a conditional with {} would
  # need identical object types.
  wlc_container = {
    for host, b in var.backends : host => {
      telegraf = {
        description = "Telegraf: Cisco MDT (gRPC dial-out) from the C9800 WLCs -> Prometheus"
        image       = var.images.telegraf
        # Its own metrics on the backend VLAN too: every Prometheus replica scrapes every Telegraf.
        # On the monitoring VIP too (net.ipv4.ip_nonlocal_bind, backends.tf).
        publish = concat(
          ["${b.monitoring_address}:${local.wlc_port}:${local.wlc_port}"],
          [for vip in(local.wlc_vip ? local.backend_vip_monitoring : []) : "${vip}:${local.wlc_port}:${local.wlc_port}"],
          ["${b.backend_address}:9273:9273"],
          ["${local.wlc_prom_port}:${local.wlc_prom_port}"], # all local addresses, incl. the VIP when held (see above)
        )
        volumes   = ["${local.wlc_conf}:/etc/telegraf:ro"]
        env_files = []
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
      { path = "${local.wlc_conf}/wlc.star", mode = "0644", owner = "root", content = file("${path.module}/telegraf/wlc.star"), restart = [], reload = ["telegraf"] },
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
      "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:${local.wlc_prom_port}/metrics",
    ] : []
  }

  wlc_scrape_on = local.wlc_enabled && length(local.wlc_backends) > 0
  wlc_scrape_configs = concat(
    local.wlc_scrape_on ? [{
      job_name       = "telegraf"
      static_configs = [for host in local.wlc_backends : { targets = ["${var.backends[host].backend_address}:9273"], labels = { host = host, role = "wlc-telemetry" } }]
    }] : [],
    # The telemetry itself, from whichever Telegraf receives (the VIP holder in fan-out mode): the same
    # target on both replicas. honor_labels: the series keep host = the WLC; up gets host="wlc-telemetry".
    local.wlc_scrape_on ? [{
      job_name     = "wlc"
      honor_labels = true
      static_configs = [{
        targets = local.wlc_vip ? [for vip in local.backend_vip_backend : "${vip}:${local.wlc_prom_port}"] : ["${var.backends[local.wlc_backends[0]].backend_address}:${local.wlc_prom_port}"]
        labels  = { host = "wlc-telemetry" }
      }]
    }] : [],
  )

  wlc_rules = local.wlc_scrape_on ? [{
    name = "wlc-telemetry"
    rules = [
      # With the VIP only the holder receives, so the sum is over every Telegraf.
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
      {
        # Telegraf receives but the wlc_* series don't reach Prometheus (job wlc down, or the clone/starlark
        # processing broken). The live client count is pushed every 30 s by every WLC with clients or not.
        alert       = "WlcTelemetryNotInPrometheus"
        expr        = "sum(rate(internal_gather_metrics_gathered{job=\"telegraf\", input=\"cisco_telemetry_mdt\"}[10m])) > 0 unless count(wlc_client_live_run_state_clients{job=\"wlc\"}) > 0"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "Telegraf receives C9800 telemetry, but no wlc_* series reach Prometheus (job wlc)" }
      },
    ]
  }] : []
}
