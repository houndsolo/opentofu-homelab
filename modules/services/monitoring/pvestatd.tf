# Proxmox stats from pvestatd into Prometheus (var.pvestatd; null leaves it out).
#
# pvestatd on every PVE node pushes node, guest (VM/LXC) and storage stats every ~10 s with
# its "influxdb" external metric server (InfluxDB v2 line protocol over HTTP). A second
# Telegraf on each backend ("pvestatd", separate from the WLC one so neither can take the
# other down) accepts those writes (influxdb_v2_listener, token-checked) on the backend's
# monitoring-network address and serves the latest values as Prometheus metrics. Each
# Prometheus scrapes its OWN backend's Telegraf by container name (job "pvestatd", every
# 10 s = pvestatd's own interval): the PVE side has one metric server per backend, so both
# replicas hold the same series and Mimir's HA dedup keeps one. Nothing is stored in InfluxDB.
#
# Metric names are pvestatd_<measurement>_<field> (pvestatd_system_cpu, pvestatd_blockstat_rd_bytes,
# pvestatd_nics_netin, pvestatd_cpustat_avg1, pvestatd_memory_memused, pvestatd_ballooninfo_actual);
# labels are pvestatd's tags: object (nodes|qemu|lxc|storages), host (node, guest or storage name),
# nodename, vmid, type (storages) and device (pvestatd's "instance": disk or NIC; renamed so it
# doesn't clash with Prometheus's instance). Counters (rd_bytes, netin...) arrive untyped; rate()
# works on them. String fields are dropped, except: status -> pvestatd_system_running (1 = running),
# and a guest's tags / a storage's content as labels (each list sorted: pvestatd's order is random).
locals {
  pvestatd_enabled      = var.pvestatd != null
  pvestatd_port         = try(var.pvestatd.port, 8186)
  pvestatd_metrics_port = 9274 # 9273 is the WLC Telegraf's
  pvestatd_conf         = "${local.backend_conf}/pvestatd"

  pvestatd_telegraf_conf = local.pvestatd_enabled ? join("\n", [
    "# Managed by OpenTofu (monitoring-config). Local edits are overwritten.",
    "[agent]",
    "  interval = \"10s\"",      # internal metrics only; pvestatd pushes on its own schedule
    "  flush_interval = \"1s\"", # into the prometheus_client cache: the scrape sees a push at once
    "  omit_hostname = true",
    "  skip_processors_after_aggregators = true",
    "",
    "[[inputs.influxdb_v2_listener]]",
    "  service_address = \":${local.pvestatd_port}\"",
    "  token = \"$${PVESTATD_TOKEN}\"", # pvestatd.env; PVE sends it as \"Authorization: Token ...\"
    "  name_prefix = \"pvestatd_\"",
    "  use_internal_statistics = true", # internal_influxdb_v2_listener_* (auth failures, bytes)
    "",
    "[[inputs.internal]]",
    "",
    "[[processors.rename]]",
    "  order = 1",
    "  namepass = [\"pvestatd_*\"]",
    "  [[processors.rename.replace]]",
    "    tag = \"instance\"",
    "    dest = \"device\"",
    "",
    # The guest's state as a number; the string itself is dropped (as a label it would start new
    # series on every start/stop).
    "[[processors.enum]]",
    "  order = 2",
    "  namepass = [\"pvestatd_system\"]",
    "  [[processors.enum.mapping]]",
    "    fields = [\"status\"]",
    "    dest = \"running\"",
    "    default = 0",
    "    [processors.enum.mapping.value_mappings]",
    "      running = 1",
    "",
    # pvestatd sends a guest's tags and a storage's content list in a different order on each push;
    # as labels every order would be its own series (144 series for 46 storages), so sort them first.
    # The Mimir backfill of the old InfluxDB data (pve_backfill.py) sorts the same way.
    "[[processors.starlark]]",
    "  order = 3",
    "  namepass = [\"pvestatd_system\"]",
    "  source = '''",
    "def apply(metric):",
    "    for key, sep in [(\"tags\", \";\"), (\"content\", \",\")]:",
    "        v = metric.fields.get(key)",
    "        if type(v) == \"string\":",
    "            metric.fields[key] = sep.join(sorted([p for p in v.split(sep) if p]))",
    "    return metric",
    "'''",
    "",
    "[[processors.converter]]",
    "  order = 4",
    "  namepass = [\"pvestatd_system\"]",
    "  [processors.converter.fields]",
    "    tag = [\"tags\", \"content\"]",
    "",
    "[[outputs.prometheus_client]]",
    "  listen = \":${local.pvestatd_metrics_port}\"",
    "  metric_version = 2",
    "  expiration_interval = \"60s\"", # a guest that stops being reported drops out after a minute
    "  string_as_label = false",
    "",
  ]) : ""

  # Always defined (main.tf filters it out unless enabled), like wlc_container.
  pvestatd_container = {
    for host, b in var.backends : host => {
      pvestatd = {
        description = "Telegraf: Proxmox pvestatd metric server (InfluxDB line protocol) -> Prometheus"
        image       = var.images.telegraf
        # The listener for the PVE nodes; the metrics on the backend VLAN for the health check
        # (Prometheus itself scrapes by container name on the monitoring network).
        publish   = ["${b.monitoring_address}:${local.pvestatd_port}:${local.pvestatd_port}", "${b.backend_address}:${local.pvestatd_metrics_port}:${local.pvestatd_metrics_port}"]
        volumes   = ["${local.pvestatd_conf}:/etc/telegraf:ro"]
        env_files = ["${local.backend_conf}/pvestatd.env"]
        user      = "telegraf" # see wlc_container
        reload    = true
      }
    }
  }

  pvestatd_files = {
    for host in local.backend_names : host => local.pvestatd_enabled ? [
      { path = "${local.pvestatd_conf}/telegraf.conf", mode = "0644", owner = "root", content = local.pvestatd_telegraf_conf, restart = [], reload = ["pvestatd"] },
      { path = "${local.backend_conf}/pvestatd.env", mode = "0600", owner = "root", content = "PVESTATD_TOKEN=${coalesce(var.pvestatd_token, "missing")}\n", restart = ["pvestatd"], reload = [] },
    ] : []
  }

  pvestatd_dirs = { for host in local.backend_names : host => local.pvestatd_enabled ? [{ path = local.pvestatd_conf, mode = "0755", owner = "root" }] : [] }

  pvestatd_validations = {
    for host in local.backend_names : host => local.pvestatd_enabled ? [
      "podman run --rm --network=none --user 0 --entrypoint telegraf -e PVESTATD_TOKEN=check -v \"$root${local.pvestatd_conf}:/etc/telegraf:ro\" '${var.images.telegraf}' config check --config /etc/telegraf/telegraf.conf",
    ] : []
  }

  pvestatd_health = {
    for host, b in var.backends : host => local.pvestatd_enabled ? [
      "curl -fsS -o /dev/null --max-time 3 http://${b.monitoring_address}:${local.pvestatd_port}/health",
      "curl -fsS -o /dev/null --max-time 3 http://${b.backend_address}:${local.pvestatd_metrics_port}/metrics",
    ] : []
  }

  # The same target on every replica, resolved to the local container: identical series on both.
  # honor_labels: the pvestatd_* series keep their own host (node, guest or storage); only up and
  # Telegraf's internal_* get host="pvestatd".
  pvestatd_scrape_configs = local.pvestatd_enabled ? [{
    job_name        = "pvestatd"
    scrape_interval = "10s"
    scrape_timeout  = "5s"
    honor_labels    = true
    static_configs  = [{ targets = ["pvestatd:${local.pvestatd_metrics_port}"], labels = { host = "pvestatd" } }]
  }] : []

  pvestatd_rules = local.pvestatd_enabled ? [{
    name = "pvestatd"
    rules = [
      {
        alert       = "PveMetricsStopped"
        expr        = "sum(rate(internal_gather_metrics_gathered{job=\"pvestatd\", input=\"influxdb_v2_listener\"}[5m])) == 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Telegraf (pvestatd) has received no Proxmox metrics for 15 minutes: no PVE node is sending" }
      },
      {
        alert       = "PveMetricsAuthFailing"
        expr        = "sum(increase(internal_influxdb_v2_listener_auth_failures{job=\"pvestatd\"}[10m])) > 0"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "Telegraf (pvestatd) is rejecting Proxmox metric writes with a wrong token" }
      },
    ]
  }] : []
}
