"""Databases/telegraf: the Telegraf instances (WLC telemetry, pvestatd, fw-wan): inputs, listeners, outputs and
the series they hand to Prometheus.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py). Registered in custom.main().
The deep dive behind the Telegraf panels of Monitoring/monitoring-stack.json. What runs where:

- job telegraf (modules/services/monitoring/telemetry.tf): a Telegraf on mon01 and mon02. The C9800 WLCs dial out
  (gRPC, cisco_telemetry_mdt) to the monitoring VIP 10.5.11.102 :57500, so only the VIP holder's Telegraf
  receives. It writes the YANG originals to InfluxDB (bucket wlc on BOTH backends, until the InfluxDB outputs are
  retired) and serves a renamed copy (wlc.star) on :9275; its own internal_* stats on :9273 (host = mon01/mon02).
- job wlc: the :9275 wlc_* series, scraped through the backend VIP 10.13.11.102 (= the VIP holder's Telegraf);
  up/scrape_* carry host="wlc-telemetry", the series themselves host = the WLC.
- job pvestatd (pvestatd.tf): a second Telegraf per mon (influxdb_v2_listener :8186, token-checked) that takes
  every PVE node's pvestatd pushes and serves them as pvestatd_* on :9274. Each Prometheus scrapes its OWN
  backend's container (target pvestatd:9274, host="pvestatd"); Mimir keeps the elected replica's copy only.
- job vyos-telegraf (main.tf): VyOS's built-in Telegraf on fw-wan (:9273, prometheus_client; its syslog_* series
  are dropped at scrape time). Telegraf 1.28 (VyOS's), the mon ones 1.40.

Telegraf's internal_* counters are cumulative since start (untyped: rate()/increase() work); gather_time_ns and
write_time_ns are timings (the mean over the last interval), not counters.
"""
from custom import (
    BLUE, LOGS_DASH, MERGE, ORANGE_IF_ANY, UP_MAP, UP_STEPS, Board, bargauge, cell, dashboard, fixed_color, mapping,
    organize, override, q, query_var, stat, state_timeline, steps, table, timeseries,
)
from logs import logs, lq, per_bucket, url_link

TIME = "${__url_time_range}"
TG_JOBS = 'job=~"telegraf|pvestatd|vyos-telegraf"'   # the Telegraf processes (internal_*, process_*)
ALL_JOBS = 'job=~"telegraf|wlc|pvestatd|vyos-telegraf"'
H = f'{TG_JOBS}, host=~"$host"'
MDT = 'job="telegraf", input="cisco_telemetry_mdt"'
PVE_IN = 'job="pvestatd", input="influxdb_v2_listener"'
INFLUX = 'output="influxdb_v2"'
WLC_VIP = "10.5.11.102"   # the monitoring VIP the WLCs dial out to (var.backend_vrrp)
VIP = f'job="node", role="monitoring", address="{WLC_VIP}"'
NO_INFLUX = "No InfluxDB output any more (retired): nothing to show"

DB_TAG_LINK = {"type": "dashboards", "tags": ["databases"], "asDropdown": True, "title": "Database dashboards",
               "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
               "tooltip": "", "url": ""}
LOGS_URL = LOGS_DASH + "?var-host=mon01&var-host=mon02&var-host=fw-wan&var-app=telegraf&var-app=pvestatd"

OK_FAIL = mapping(**{"0": ("FAIL", "red"), "1": ("OK", "green")})
OK_STEPS = steps(("red", None), ("green", 1))
JOB_DESC = ("telegraf = WLC telemetry Telegraf on mon01/02, pvestatd = Proxmox metric-server Telegraf (the elected "
            "replica's container, host \"pvestatd\"), vyos-telegraf = fw-wan's VyOS Telegraf.")


def dashed(name, color):
    return override(name, {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]},
                           "color": {"mode": "fixed", "fixedColor": color}})


def telegraf():
    b = Board()

    # --- Status ---------------------------------------------------------------------------------
    b.row("Status")
    checks = [
        ("WLC telemetry arriving", f"sum(rate(internal_gather_metrics_gathered{{{MDT}}}[10m])) > bool 0"),
        ("WLC writes not dropped", 'sum(increase(internal_write_metrics_dropped{job="telegraf"}[15m])) == bool 0'),
        ("wlc_* in Prometheus", '(count(wlc_client_live_run_state_clients{job="wlc"}) or vector(0)) > bool 0'),
        ("receiver = VIP holder", f"(count(sum by (host) (rate(internal_gather_metrics_gathered{{{MDT}}}[10m])) > 0 "
                                  f"and on (host) node_network_address_info{{{VIP}}}) or vector(0)) == bool 1"),
        ("Proxmox metrics arriving", f"sum(rate(internal_gather_metrics_gathered{{{PVE_IN}}}[5m])) > bool 0"),
        ("pvestatd token accepted", 'sum(increase(internal_influxdb_v2_listener_auth_failures{job="pvestatd"}[10m])) == bool 0'),
        ("all targets up", f"min(up{{{ALL_JOBS}}})"),
        ("monitoring VIP held once", f"(count(node_network_address_info{{{VIP}}}) or vector(0)) == bool 1"),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 14), orientation="horizontal",
               desc="The Telegraf alert rules, as tiles: WlcTelemetryStopped (no cisco_telemetry_mdt metrics for 10 min), "
                    "WlcTelemetryWriteDropping (an output of the WLC Telegraf dropped metrics in 15 min: buffer full), "
                    "WlcTelemetryNotInPrometheus (no wlc_client_live_run_state_clients in job wlc), PveMetricsStopped, "
                    "PveMetricsAuthFailing (pvestatd writes with a wrong token), TargetDown for the four jobs and "
                    f"MonitoringVIPNotHeldOnce ({WLC_VIP}). 'receiver = VIP holder' has no alert: the Telegraf that "
                    "receives the WLCs' stream must be the one on the VIP holder (the WLCs only reach the VIP)."), 8, 8)
    b.col(4,
          (stat("WLC receiver (VIP holder)", [q(f"max by (host) (node_network_address_info{{{VIP}}})", "{{host}}",
                                                instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NOBODY", text_size=(12, 30),
                desc=f"The mon holding the monitoring VIP {WLC_VIP}, where the WLCs dial out to: its Telegraf gets the "
                     "whole gRPC stream, the other one idles. The wlc job scrapes the backend VIP, so it lands there too."), 4),
          (stat("WLCs reporting", [q('count(count by (host) (wlc_client_live_run_state_clients{job="wlc"}))', instant=True)],
                decimals=0, color_mode="value", thresholds=steps(("red", None), ("orange", 1), ("green", 2)),
                text_size=(12, 30), no_value="0",
                desc="C9800s whose live client count (pushed every 30 s whether or not there are clients) is in job wlc "
                     "right now: 2 = both wlc-1 and wlc-2 stream."), 4))
    b.col(4,
          (stat("PVE nodes reporting", [q('count(pvestatd_cpustat_cpu{job="pvestatd", object="nodes"})', instant=True)],
                decimals=0, color_mode="value", thresholds=BLUE, text_size=(12, 30), no_value="0",
                desc="Proxmox nodes whose pvestatd pushes reach the pvestatd Telegraf (7 in the lylat cluster + greatfox, "
                     "which is often powered off on purpose)."), 4),
          (stat("Gather errors (1 h)", [q(f"sum(increase(internal_gather_errors{{{TG_JOBS}}}[1h])) or vector(0)", instant=True)],
                decimals=0, color_mode="value", thresholds=ORANGE_IF_ANY, text_size=(12, 30),
                desc="Failed gathers of every input on every Telegraf in the last hour. fw-wan's chrony input fails on "
                     "every interval (it times out after 10 s; see Inputs), so this is rarely 0."), 4))
    b.col(4,
          (stat("Samples per scrape", [q(f"sum by (job) (scrape_samples_scraped{{{ALL_JOBS}}})", "{{job}}", instant=True)],
                text_mode="value_and_name", decimals=0, color_mode="value", thresholds=BLUE, text_size=(11, 16),
                desc="What each job hands to Prometheus per scrape (summed over its targets). " + JOB_DESC +
                     " wlc = the WLC telemetry itself."), 8))

    inst_cols = [
        ("Up", f"max by (host, job) (up{{{H}}})"),
        ("Version", f"max by (host, job, version) (internal_agent_metrics_gathered{{{H}}})"),
        ("Started", f"time() - max by (host, job) (process_start_time_seconds{{{H}}})"),
        ("Gathered/s", f"sum by (host, job) (rate(internal_agent_metrics_gathered{{{H}}}[5m]))"),
        ("Written/s", f"sum by (host, job) (rate(internal_agent_metrics_written{{{H}}}[5m]))"),
        ("Dropped (1 h)", f"sum by (host, job) (increase(internal_agent_metrics_dropped{{{H}}}[1h]))"),
        ("Gather errors (1 h)", f"sum by (host, job) (increase(internal_agent_gather_errors{{{H}}}[1h]))"),
        ("Buffer max", f"max by (host, job) (internal_write_buffer_size{{{H}}} / internal_write_buffer_limit{{{H}}})"),
        ("RSS", f"max by (host, job) (process_resident_memory_bytes{{{H}}})"),
        ("Series", f"max by (host, job) (scrape_samples_scraped{{{H}}})"),
    ]
    rename = {"host": "Instance", "job": "Job", "version": "Telegraf"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(inst_cols)})
    b.add(table("Instances", [q(e, table=True) for _, e in inst_cols],
                desc="One row per Telegraf process. " + JOB_DESC + " Started: since the process started (a reload "
                     "keeps it). Buffer max: the fullest output buffer against its metric_buffer_limit (200 000 on the "
                     "WLC Telegraf, 10 000 elsewhere); at 100 % the oldest metrics are dropped. Series: samples per scrape "
                     "of its own /metrics (for pvestatd that is all pvestatd_* series).",
                transformations=[MERGE, organize(exclude=["Time", "Value #B"], rename=rename,
                                                 order=["Instance", "Job", "Up", "Telegraf", "Started", "Gathered/s",
                                                        "Written/s", "Dropped (1 h)", "Gather errors (1 h)",
                                                        "Buffer max", "RSS", "Series"])],
                overrides=[override("Up", {"mappings": UP_MAP, "thresholds": UP_STEPS}), cell("Up", "color-background"),
                           override("Started", {"unit": "dtdurations"}),
                           override("Gathered/s", {"decimals": 1}), override("Written/s", {"decimals": 1}),
                           override("Dropped (1 h)", {"decimals": 0, "thresholds": steps(("green", None), ("red", 1))}),
                           cell("Dropped (1 h)", "color-text"),
                           override("Gather errors (1 h)", {"decimals": 0, "thresholds": ORANGE_IF_ANY}),
                           cell("Gather errors (1 h)", "color-text"),
                           override("Buffer max", {"unit": "percentunit", "decimals": 1,
                                                   "thresholds": steps(("green", None), ("orange", 0.5), ("red", 0.9))}),
                           cell("Buffer max", "color-text"),
                           override("RSS", {"unit": "bytes"}), override("Series", {"decimals": 0}),
                           override("Instance", {"links": [{"title": "Logs of this host",
                                                            "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]})],
                sort="Instance"), 24, 6)

    # --- WLC telemetry (gRPC dial-out) ----------------------------------------------------------
    b.row("WLC telemetry (cisco_telemetry_mdt, job telegraf / wlc)")
    b.add(state_timeline("Monitoring VIP holder", [
        q(f"max by (host) (node_network_address_info{{{VIP}}}) or max by (host) "
          '(up{job="telegraf"}) * 0', "{{host}}")],
        mappings=mapping(**{"1": ("VIP: receives the WLCs", "green"), "0": ("standby", "blue")}),
        thresholds=steps(("blue", None), ("green", 1)),
        desc=f"Which mon held {WLC_VIP} when. A keepalived failover moves the WLCs' gRPC stream (they reconnect within "
             "a push interval or two) and the wlc job's scrape target with it."), 8, 6)
    b.add(timeseries("Telemetry received per Telegraf", [
        q(f"sum by (host) (rate(internal_gather_metrics_gathered{{{MDT}}}[$__rate_interval]))", "{{host}}")],
        fill=20, stack=True, min_=0, unit="short",
        desc="Metrics per second from the gRPC dial-out (one metric per YANG list entry per push). Only the VIP holder "
             "should show traffic; 0 for 10 min fires WlcTelemetryStopped."), 8, 6)
    b.add(timeseries("gRPC stream errors", [
        q(f"sum by (host) (increase(internal_gather_errors{{{MDT}}}[$__rate_interval])) > 0", "{{host}}")],
        decimals=0, draw="bars", fill=60, no_value="No gRPC errors in range",
        desc="cisco_telemetry_mdt errors: a WLC's stream ended ('receive error during GRPC dialout ... context "
             "canceled' on a Telegraf reload, or the WLC dropped/reconnected). Isolated bursts at reloads are normal; "
             "a steady rate means a WLC keeps reconnecting (see Logs)."), 8, 6)
    b.add(timeseries("wlc_* series per WLC", [
        q('count by (host) ({job="wlc", host=~"c9800.*"})', "{{host}}"),
        q('scrape_samples_scraped{job="wlc"}', "scraped from the VIP (all WLCs)")],
        decimals=0, fill=0, min_=0,
        desc="Series in job wlc per controller, and the samples per scrape of the :9275 endpoint. Telegraf expires a "
             "series 150 s after its last push; a WLC dropping out, or whole subscriptions missing, shows as a step down. "
             "The controller with the AP and clients carries most of them.",
        overrides=[dashed("scraped from the VIP (all WLCs)", "text")]), 8, 7)
    b.add(bargauge("wlc_* metric families", [
        q('sort_desc(topk(15, count by (__name__) ({job="wlc", __name__=~"wlc_.*"})))', "{{__name__}}", instant=True)],
        decimals=0, thresholds=BLUE, mode="gradient",
        desc="The 15 largest wlc_* names by series count (one per YANG path and numeric field, see telegraf/wlc.star). "
             "The *_info series carry the strings as labels."), 8, 7)
    b.add(timeseries("Clone and Starlark (wlc.star)", [
        q('sum by (host, processor) (increase(internal_process_errors{job="telegraf"}[$__rate_interval]))',
          "{{host}} {{processor}} errors"),
        q('sum by (host) (rate(internal_write_metrics_written{job="telegraf", alias="wlc"}[$__rate_interval]))',
          "{{host}} to :9275 /s"),
    ], fill=0, min_=0,
        desc="Every telemetry metric is cloned to wlc_* and reshaped by wlc.star before the :9275 output: processor "
             "errors (a Starlark exception drops the metric) and what reaches that output per second. Received but "
             "not here = the processing broke (WlcTelemetryNotInPrometheus).",
        overrides=[override(".*errors.*", {"color": {"mode": "fixed", "fixedColor": "red"}, "decimals": 0,
                                           "custom.axisPlacement": "right"}, regex=True)]), 8, 7)

    # --- Proxmox listener -----------------------------------------------------------------------
    b.row("Proxmox listener (influxdb_v2_listener, job pvestatd)")
    b.add(timeseries("HTTP requests", [
        q('sum(rate(internal_influxdb_v2_listener_writes_served{job="pvestatd"}[$__rate_interval]))', "writes"),
        q('sum(rate(internal_influxdb_v2_listener_requests_received{job="pvestatd"}[$__rate_interval]))', "requests"),
        q('sum(rate(internal_influxdb_v2_listener_healths_served{job="pvestatd"}[$__rate_interval])) * 60 > 0',
          "health checks / min"),
        q('sum(rate(internal_influxdb_v2_listener_not_founds_served{job="pvestatd"}[$__rate_interval])) * 60 > 0',
          "404 / min"),
    ], fill=0, min_=0,
        desc="Requests to :8186 per second: one write per PVE node per pvestatd cycle (~10 s), so ~0.8/s with 8 nodes. "
             "Health checks are the deploy's curl; 404s are clients on a wrong path. This is the elected replica's "
             "container only (Mimir keeps one copy of the pair)."), 8, 7)
    b.add(timeseries("Rejected writes (wrong token)", [
        q('sum(increase(internal_influxdb_v2_listener_auth_failures{job="pvestatd"}[$__rate_interval])) > 0', "auth failures")],
        decimals=0, draw="bars", fill=60, no_value="No auth failures in range",
        overrides=[fixed_color("auth failures", "red")],
        desc="Writes refused with 401: a PVE metric-server entry (pvestatd-<backend> in /etc/pve/status.cfg) with a token "
             "that isn't pvestatd_token. Alert PveMetricsAuthFailing."), 8, 7)
    b.add(timeseries("Metrics received / PVE nodes", [
        q(f"sum(rate(internal_gather_metrics_gathered{{{PVE_IN}}}[$__rate_interval]))", "metrics/s"),
        q('count(pvestatd_cpustat_cpu{job="pvestatd", object="nodes"})', "nodes reporting"),
    ], fill=0, min_=0,
        desc="pvestatd_* metrics per second (one per node, guest, storage, disk and NIC per push) and the nodes in "
             "them. 0 for 10 min fires PveMetricsStopped. A greatfox gap is expected (often powered off).",
        overrides=[override("nodes reporting", {"custom.axisPlacement": "right", "decimals": 0,
                                                "color": {"mode": "fixed", "fixedColor": "blue"}})]), 8, 7)
    b.add(timeseries("pvestatd_* series by object", [
        q('count by (object) ({job="pvestatd", object!=""})', "{{object}}")],
        decimals=0, fill=30, stack=True,
        desc="Series in job pvestatd per pvestatd object type (qemu dominates: per VM disk and NIC). Each series "
             "expires 60 s after its last push (a stopped guest drops out)."), 12, 6)
    b.add(bargauge("pvestatd_* series per node / guest", [
        q('sort_desc(topk(15, count by (host) ({job="pvestatd", object=~"nodes|qemu|lxc"})))', "{{host}}", instant=True)],
        decimals=0, thresholds=BLUE, mode="gradient",
        desc="The 15 objects with the most pvestatd_* series: PVE nodes (per-CPU, per-NIC) and VMs with many disks/NICs."), 12, 6)

    # --- Inputs ---------------------------------------------------------------------------------
    b.row("Inputs ($host)")
    b.add(timeseries("Metrics gathered per input", [
        q(f'sum by (host, input) (rate(internal_gather_metrics_gathered{{{H}, input!="internal"}}[$__rate_interval]))',
          "{{host}} {{input}}")],
        fill=0, min_=0, placement="right",
        desc="Metrics per second each input produced (Telegraf's own internal input left out). Listener inputs "
             "(cisco_telemetry_mdt, influxdb_v2_listener) count what was pushed to them; the rest are polled every "
             "agent interval."), 12, 8)
    b.add(timeseries("Gather errors per input", [
        q(f"sum by (host, input) (increase(internal_gather_errors{{{H}}}[$__rate_interval])) > 0", "{{host}} {{input}}")],
        decimals=0, draw="bars", fill=60, stack=True, placement="right", no_value="No gather errors in range",
        desc="Failed gathers per input. fw-wan's chrony input fails every interval (each attempt runs into the 10 s "
             "timeout, see Gather time); cisco_telemetry_mdt errors are WLC streams ending."), 12, 8)
    b.add(timeseries("Gather time per input", [
        q(f'max by (host, input) (internal_gather_gather_time_ns{{{H}, input!~"cisco_telemetry_mdt|influxdb_v2_listener"}}) / 1e9',
          "{{host}} {{input}}")],
        unit="s", fill=0, min_=0, placement="right",
        desc="How long each polled input's last collection took (listeners don't gather, left out). Close to the "
             "agent interval means the input can't keep up; 10 s flat is a timeout (fw-wan chrony)."), 12, 8)
    b.add(timeseries("Processor and parser errors", [
        q(f"sum by (host, processor) (increase(internal_process_errors{{{H}}}[$__rate_interval])) > 0", "{{host}} {{processor}}"),
        q(f"sum by (host, type) (increase(internal_parser_errors{{{H}}}[$__rate_interval])) > 0", "{{host}} parser {{type}}"),
        q(f"sum by (host) (increase(internal_gather_startup_errors{{{H}}}[$__rate_interval])) > 0", "{{host}} input startup"),
    ], decimals=0, draw="bars", fill=60, placement="right", no_value="No processor, parser or startup errors in range",
        desc="Processors: clone + starlark (WLC), rename/enum/starlark/converter (pvestatd). Parser: fw-wan's exec "
             "inputs. Startup: an input that failed to start and is being retried."), 12, 8)

    # --- Outputs --------------------------------------------------------------------------------
    b.row("Outputs ($host)")
    b.add(timeseries("Metrics written per output", [
        q(f"sum by (host, output, alias) (rate(internal_write_metrics_written{{{H}}}[$__rate_interval]))",
          "{{host}} {{output}} {{alias}}")],
        fill=0, min_=0, placement="right",
        desc="Per second. prometheus_client 'writes' into its own cache, which Prometheus scrapes (alias wlc = the "
             ":9275 wlc_* endpoint, no alias = Telegraf's internal_* / fw-wan's metrics); influxdb_v2 alias = the "
             "backend whose InfluxDB it writes to."), 12, 8)
    b.add(timeseries("Dropped, rejected and failed writes", [
        q(f"sum by (host, output, alias) (increase(internal_write_metrics_dropped{{{H}}}[$__rate_interval])) > 0",
          "{{host}} {{output}} {{alias}} dropped"),
        q(f"sum by (host, output, alias) (increase(internal_write_metrics_rejected{{{H}}}[$__rate_interval])) > 0",
          "{{host}} {{output}} {{alias}} rejected"),
        q(f"sum by (host, output, alias) (increase(internal_write_errors{{{H}}}[$__rate_interval])) > 0",
          "{{host}} {{output}} {{alias}} write errors"),
    ], decimals=0, draw="bars", fill=60, placement="right", no_value="Nothing dropped, rejected or failed in range",
        desc="Dropped: the buffer overflowed (WlcTelemetryWriteDropping on the WLC Telegraf). Rejected: the output "
             "refused the metric (e.g. a name it can't serialize). Write errors: a flush failed and is retried."), 12, 8)
    b.add(timeseries("Buffer fill per output", [
        q(f"max by (host, output, alias) (internal_write_buffer_size{{{H}}} / internal_write_buffer_limit{{{H}}})",
          "{{host}} {{output}} {{alias}}"),
        q("vector(1)", "limit (oldest dropped)")],
        unit="percentunit", fill=0, min_=0, placement="right",
        desc="Metrics waiting in each output's buffer against metric_buffer_limit. A peer InfluxDB that is down "
             "makes the WLC Telegraf's buffer for it grow until it's back (200 000 metrics rides out a short outage).",
        overrides=[dashed("limit (oldest dropped)", "red")]), 12, 8)
    b.add(timeseries("Write time per output", [
        q(f"max by (host, output, alias) (internal_write_write_time_ns{{{H}}}) / 1e9", "{{host}} {{output}} {{alias}}")],
        unit="s", fill=0, min_=0, placement="right",
        desc="How long the last flush of each output took (mean over the interval). InfluxDB writes over the backend "
             "VLAN take milliseconds; seconds mean the receiving InfluxDB is slow or unreachable."), 12, 8)

    # --- InfluxDB outputs (until retired) -------------------------------------------------------
    b.row("InfluxDB outputs (until retired)")
    b.add(timeseries("Written to InfluxDB", [
        q(f"sum by (host, alias) (rate(internal_write_metrics_written{{{TG_JOBS}, {INFLUX}}}[$__rate_interval]))",
          "{{host}} → {{alias}}")],
        fill=0, min_=0, no_value=NO_INFLUX,
        desc="Metrics per second each Telegraf still writes to InfluxDB: the WLC Telegraf on the VIP holder writes the "
             "YANG originals to bucket wlc on both backends (alias = the target backend) until those outputs are "
             "removed; the idle one writes 0. fw-wan's own influxdb_v2 output (no alias) carries nothing since the "
             "influx-relay was retired. These panels go empty when the outputs are gone."), 8, 6)
    b.add(timeseries("InfluxDB write errors and drops", [
        q(f"sum by (host, alias) (increase(internal_write_errors{{{TG_JOBS}, {INFLUX}}}[$__rate_interval])) > 0",
          "{{host}} → {{alias}} errors"),
        q(f"sum by (host, alias) (increase(internal_write_metrics_dropped{{{TG_JOBS}, {INFLUX}}}[$__rate_interval])) > 0",
          "{{host}} → {{alias}} dropped"),
    ], decimals=0, draw="bars", fill=60, no_value="No InfluxDB write errors in range (or no InfluxDB output left)",
        desc="Failed flushes (retried from the buffer) and drops for the influxdb_v2 outputs only."), 8, 6)
    b.add(timeseries("InfluxDB buffer and write time", [
        q(f"max by (host, alias) (internal_write_buffer_size{{{TG_JOBS}, {INFLUX}}})", "{{host}} → {{alias}} buffered"),
        q(f"max by (host, alias) (internal_write_write_time_ns{{{TG_JOBS}, {INFLUX}}}) / 1e9", "{{host}} → {{alias}} write time"),
    ], fill=0, min_=0, no_value=NO_INFLUX,
        desc="Metrics waiting for each InfluxDB, and the last flush duration.",
        overrides=[override(".*write time.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   override(".*buffered.*", {"decimals": 0}, regex=True)]), 8, 6)

    # --- Prometheus side ------------------------------------------------------------------------
    b.row("What Prometheus scrapes")
    b.add(timeseries("Samples per scrape", [
        q(f"scrape_samples_scraped{{{ALL_JOBS}}}", "{{job}} {{host}}")],
        decimals=0, fill=0, min_=0, placement="right",
        desc="Series each target exposes per scrape: pvestatd (every PVE node, guest and storage), fw-wan's Telegraf "
             "(after dropping syslog_*), the wlc_* endpoint and the two WLC Telegrafs' own internal_* metrics."), 12, 7)
    b.add(timeseries("New series per hour (churn)", [
        q(f"sum by (job) (sum_over_time(scrape_series_added{{{ALL_JOBS}}}[1h]))", "{{job}}")],
        decimals=0, fill=0, min_=0, placement="right",
        desc="Series that appeared for the first time in each scrape, summed over the last hour. Steady churn is "
             "labels that keep changing (wlc_*_info strings, guest tags); a spike is a restart or a new device."), 12, 7)
    b.add(timeseries("Scrape duration", [
        q(f"scrape_duration_seconds{{{ALL_JOBS}}}", "{{job}} {{host}}"),
    ], unit="s", fill=0, min_=0, placement="right",
        desc="Time to scrape each endpoint (pvestatd every 10 s, the rest at the global interval)."), 12, 7)
    b.add(bargauge("Series in Mimir per job", [
        q(f"sort_desc(count by (job) ({{{ALL_JOBS}}}))", "{{job}}", instant=True)],
        decimals=0, thresholds=BLUE, mode="gradient",
        desc="Active series in Mimir now, per job (incl. up/scrape_* and, for vyos-telegraf, fw-wan's whole metric "
             "set). " + JOB_DESC), 12, 7)

    # --- Process --------------------------------------------------------------------------------
    b.row("Process ($host)")
    b.add(timeseries("CPU", [q(f"rate(process_cpu_seconds_total{{{H}}}[$__rate_interval])", "{{host}} ({{job}})")],
                     unit="percentunit", fill=0, min_=0, desc="Cores used by each Telegraf."), 6, 7)
    b.add(timeseries("Resident memory", [q(f"process_resident_memory_bytes{{{H}}}", "{{host}} ({{job}})")],
                     unit="bytes", fill=0, min_=0,
                     desc="RSS. The WLC Telegraf on the VIP holder holds the decoded telemetry and both output caches."), 6, 7)
    b.add(timeseries("Go heap in use", [q(f"internal_memstats_heap_in_use_bytes{{{H}}}", "{{host}} ({{job}})")],
                     unit="bytes", fill=0, min_=0,
                     desc="Telegraf's own heap figure (internal input); grows with buffered metrics."), 6, 7)
    b.add(timeseries("Goroutines", [q(f"go_goroutines{{{H}}}", "{{host}} ({{job}})")], decimals=0, fill=0, min_=0,
                     desc="Rises with open gRPC streams and HTTP connections."), 6, 7)

    # --- Logs -----------------------------------------------------------------------------------
    b.row("Logs", collapsed=True)
    sel = '{app=~"telegraf|pvestatd"}'
    b.add(per_bucket("Errors and warnings per host", [
        lq(f"sum by (host, app) (count_over_time({sel} |~ ` [EW]! ` [$__auto]))", "{{host}} {{app}}")],
        desc="Telegraf's E! and W! lines (Podman logs them all at priority err, so the journal level means nothing)."),
        8, 8)
    b.add(logs("Telegraf errors and warnings", f"{sel} |~ ` [EW]! `", max_lines=300,
               desc="mon01/02 (containers telegraf and pvestatd, journal via Alloy) and fw-wan's telegraf if it logs."),
          16, 8)

    host = query_var("host", "Instance", f"label_values(internal_agent_metrics_gathered{{{TG_JOBS}}}, host)")
    return dashboard("telegraf", "Telegraf",
                     "The Telegraf instances: WLC telemetry (gRPC dial-out on mon01/02 behind the monitoring VIP), the "
                     "pvestatd listener and fw-wan's VyOS Telegraf. Health tiles from the alert rules, listeners, inputs, "
                     "outputs (incl. the InfluxDB ones until they are retired), the series they export, process stats.",
                     b, tags=["databases", "telegraf"], variables=[host],
                     extra_links=[DB_TAG_LINK, url_link("Monitoring stack", "/d/monitoring-stack"),
                                  url_link("Telegraf logs", LOGS_URL), url_link("Explore", "/explore")])


DASHBOARDS = {"Databases/telegraf.json": telegraf}
