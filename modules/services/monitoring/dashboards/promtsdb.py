"""Databases/prometheus: the two Prometheus replicas (mon01/mon02): TSDB, scrapes, rules, remote write to Mimir.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with its helpers; registered in
custom.main(). The deep dive behind the Prometheus rows of Monitoring/monitoring-stack.json.

The setup (modules/services/monitoring main.tf, metrics.tf): Prometheus 3 in a Podman container on each backend
(mon01, mon02), the same scrape config and rules on both (global interval 30 s), local TSDB capped at 7 d and 20 GB
(settings.prometheus_retention_time/_size), both remote_write everything to Mimir (VIP 10.13.11.103:8080). Mimir's
HA tracker keeps one replica's samples (cluster "lylat", label __replica__) and drops the other's.

What that means for this dashboard (it reads Mimir, the default datasource):
- Each Prometheus scrapes BOTH Prometheus targets, so the prometheus_* / process_* series of mon01 and mon02 are
  both in Mimir (label host = the target) whichever replica is elected: per-replica panels work.
- Per-target series (up, scrape_*, ALERTS) are the elected replica's view only; each replica's own TSDB is one
  click away in Explore through the prometheus-mon01 / prometheus-mon02 datasources (header links).
"""
import json
import urllib.parse

from custom import (
    BLUE, LOGS_DASH, MERGE, NODE_DASH, STACK_DASH, UP_MAP, Board, bargauge, cell, dashboard, mapping, organize,
    override, q, query_var, stat, state_timeline, steps, table, timeseries,
)
from logs import logs, lq, per_bucket

TIME = "${__url_time_range}"
P = 'job="prometheus", host=~"$host"'   # the replicas picked in the Replica variable
PJ = 'job="prometheus"'                 # both replicas (health checks)
MJ = 'job="mimir"'
MON_FS = 'job="node", mountpoint="/"'
RETENTION_S = 7 * 86400                 # settings.prometheus_retention_time (variables.tf)
MIMIR_DASH = "/d/mimir/mimir"           # mimir.py

DB_LINK = {"type": "dashboards", "tags": ["databases"], "asDropdown": True, "title": "Database dashboards",
           "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
           "tooltip": "", "url": ""}

OK_FAIL = mapping(**{"0": ("FAIL", "red"), "1": ("OK", "green")})
OK_STEPS = steps(("red", None), ("green", 1))
RED = {"color": {"mode": "fixed", "fixedColor": "red"}}
DASHED = {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]}, "color": {"mode": "fixed", "fixedColor": "orange"}}
DASHED_RED = {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]}, "color": {"mode": "fixed", "fixedColor": "red"}}


def size(sel=P):
    """What --storage.tsdb.retention.size counts: persisted blocks + WAL (with checkpoints) + m-mapped head chunks."""
    return (f"sum by (host) (prometheus_tsdb_storage_blocks_bytes{{{sel}}}) + "
            f"sum by (host) (prometheus_tsdb_wal_storage_size_bytes{{{sel}}}) + "
            f"sum by (host) (prometheus_tsdb_head_chunks_storage_size_bytes{{{sel}}})")


def lag(sel=P):
    """Newest sample appended minus newest sample sent to Mimir (the PrometheusRemoteWriteBehind expression)."""
    return (f"max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{{{sel}}} - ignoring(remote_name, url) "
            f"group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds{{{sel}}})")


def grp(expr):
    """rule_group is "<file>;<group>": a `group` label with just the group's name."""
    return f'label_replace({expr}, "group", "$1", "rule_group", ".*;(.*)")'


def am(expr):
    """The notifier's alertmanager label is the push URL: an `am` label with host:port."""
    return f'label_replace({expr}, "am", "$1", "alertmanager", "https?://([^/]+)/.*")'


# Mimir's HA tracker: the replica whose samples it keeps, as a per-host series (1 = elected).
ELECTED = (f'max by (host) (label_replace(cortex_ha_tracker_elected_replica_status{{{MJ}, cluster="lylat"}} == 1, '
           f'"host", "$1", "replica", "(.*)"))')

# TSDB failure counters (all should stay 0).
TSDB_FAILURES = {
    "compaction failed": "prometheus_tsdb_compactions_failed_total",
    "head truncation failed": "prometheus_tsdb_head_truncations_failed_total",
    "WAL truncation failed": "prometheus_tsdb_wal_truncations_failed_total",
    "checkpoint failed": "prometheus_tsdb_checkpoint_creations_failed_total",
    "checkpoint deletion failed": "prometheus_tsdb_checkpoint_deletions_failed_total",
    "WAL write failed": "prometheus_tsdb_wal_writes_failed_total",
    "WAL corruption": "prometheus_tsdb_wal_corruptions_total",
    "mmap chunk corruption": "prometheus_tsdb_mmap_chunk_corruptions_total",
    "block reload failed": "prometheus_tsdb_reloads_failures_total",
}

# Samples a scrape threw away, and scrape pool problems.
SCRAPE_DROPS = {
    "over sample_limit": "prometheus_target_scrapes_exceeded_sample_limit_total",
    "out of order": "prometheus_target_scrapes_sample_out_of_order_total",
    "duplicate timestamp": "prometheus_target_scrapes_sample_duplicate_timestamp_total",
    "out of bounds": "prometheus_target_scrapes_sample_out_of_bounds_total",
    "over body_size_limit": "prometheus_target_scrapes_exceeded_body_size_limit_total",
    "over label limits": "prometheus_target_scrape_pool_exceeded_label_limits_total",
    "over target_limit": "prometheus_target_scrape_pool_exceeded_target_limit_total",
    "pool reload failed": "prometheus_target_scrape_pool_reloads_failed_total",
    "target sync failed": "prometheus_target_sync_failed_total",
}


def rose(counters, sel=PJ):
    """Total increase of several counters over the last hour, 0 when absent. One term per counter: increase() on a
    {__name__=~...} selector drops the names and fails with "vector cannot contain metrics with the same labelset"."""
    return "(" + " + ".join(f"(sum(increase({m}{{{sel}}}[1h])) or vector(0))" for m in counters.values()) + ")"


WARN_LOG = '{app="prometheus", host=~"$host"} |~ `level=(WARN|ERROR)`'


def explore(ds, expr):
    """A Grafana Explore URL on one datasource (the replicas' own TSDBs: prometheus-mon01 / -mon02)."""
    panes = {"a": {"datasource": ds, "queries": [{"refId": "A", "datasource": {"type": "prometheus", "uid": ds},
                                                   "expr": expr, "editorMode": "code"}],
                   "range": {"from": "now-1h", "to": "now"}}}
    return "/explore?schemaVersion=1&orgId=1&panes=" + urllib.parse.quote(json.dumps(panes, separators=(",", ":")),
                                                                          safe="")


def link(title, url, icon, tooltip, keep_time=True, blank=False):
    return {"type": "link", "title": title, "url": url, "keepTime": keep_time, "icon": icon, "asDropdown": False,
            "includeVars": False, "targetBlank": blank, "tooltip": tooltip, "tags": []}


def failures(title, counters, *, desc, no_value):
    """One bar series per (replica, counter) that rose in the hour; nothing drawn while all stay 0."""
    return timeseries(title, [q(f"sum by (host) (increase({metric}{{{P}}}[1h])) > 0", f"{{{{host}}}} {name}")
                              for name, metric in counters.items()],
                      decimals=0, fill=10, draw="bars", no_value=no_value, desc=desc,
                      overrides=[override(".*", RED, regex=True)])


def status(b):
    stack_link = [("Monitoring stack", STACK_DASH + "?" + TIME)]
    b.row("Status")
    b.col(4,
          (stat("Mimir keeps samples from", [q(f"{ELECTED} == 1", "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NO REPLICA ELECTED",
                text_size=(12, 30), links=stack_link,
                desc="The replica Mimir's HA tracker accepts right now (cortex_ha_tracker_elected_replica_status); the "
                     "other one's pushes are accepted and dropped. It fails over when the elected replica sends nothing "
                     "for 30 s (a ~30 s gap at a failover is normal)."), 5),
          (stat("HA failovers in range", [
              q(f"max(increase(cortex_ha_tracker_elected_replica_changes_total{{{MJ}}}[$__range])) or vector(0)",
                instant=True)],
              decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 1)), text_size=(12, 30),
              desc="Times the HA tracker switched replica in the time range (the Mimir that counted most). Each one is "
                   "a restart or stall of the elected Prometheus."), 5))
    lag_all = lag(PJ)
    checks = [
        ("both replicas up", f"(count(up{{{PJ}}} == 1) or vector(0)) == bool 2"),
        ("config loaded", f"min(prometheus_config_last_reload_successful{{{PJ}}}) == bool 1"),
        ("remote_write not failing", f"(sum(rate(prometheus_remote_storage_samples_failed_total{{{PJ}}}[10m])) "
                                     f"or vector(0)) == bool 0"),
        ("remote_write < 5 min behind", f"(max({lag_all}) or vector(1e9)) < bool 300"),
        ("Mimir got a sample < 2 min ago", f"(time() - max(cortex_distributor_latest_seen_sample_timestamp_seconds"
                                           f"{{{MJ}}}) or vector(1e9)) < bool 120"),
        ("TSDB < 80 % of 20 GB", f"max(({size(PJ)}) / max by (host) (prometheus_tsdb_retention_limit_bytes{{{PJ}}})) "
                                 f"< bool 0.8"),
        ("root FS > 10 % free", f"min(node_filesystem_avail_bytes{{{MON_FS}}} / node_filesystem_size_bytes{{{MON_FS}}} "
                                f"and on (host) prometheus_build_info{{{PJ}}}) > bool 0.1"),
        ("no TSDB failures (1 h)", f"{rose(TSDB_FAILURES)} < bool 1"),
        ("no rule failures (1 h)", f"(sum(increase(prometheus_rule_evaluation_failures_total{{{PJ}}}[1h])) "
                                   f"or vector(0)) < bool 1"),
        ("no missed rule runs (1 h)", f"(sum(increase(prometheus_rule_group_iterations_missed_total{{{PJ}}}[1h])) "
                                      f"or vector(0)) < bool 1"),
        ("no scrape drops (1 h)", f"{rose(SCRAPE_DROPS)} < bool 1"),
        ("both Alertmanagers seen", f"min(prometheus_notifications_alertmanagers_discovered{{{PJ}}}) >= bool 2"),
        ("alerts delivered (10 m)", f"(sum(rate(prometheus_notifications_errors_total{{{PJ}}}[10m])) + "
                                    f"sum(rate(prometheus_notifications_dropped_total{{{PJ}}}[10m])) or vector(0)) "
                                    f"== bool 0"),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 13), orientation="horizontal",
               desc="Both replicas, whatever the Replica picker says. Mirrors the alert rules TargetDown (up), "
                    "PrometheusRemoteWriteFailing (failed samples over 10 m), PrometheusRemoteWriteBehind (lag over "
                    "300 s) and FilesystemAlmostFull (the backend's root FS, where /prometheus lives). The rest are "
                    "invariants without an alert: config reload, Mimir still receiving, the TSDB under 80 % of its "
                    "20 GB cap (past it Prometheus deletes the oldest blocks before 7 d), no TSDB / rule / scrape "
                    "failures in the last hour, both Alertmanagers discovered and taking alerts."), 8, 10)
    b.col(4,
          (stat("Samples appended / s", [
              q(f"sum by (host) (rate(prometheus_tsdb_head_samples_appended_total{{{P}}}[$__rate_interval]))", "{{host}}")],
              text_mode="value_and_name", color_mode="value", graph=True, thresholds=BLUE, decimals=0,
              text_size=(11, 18), desc="Scraped and rule-produced samples written to the head, per replica. The two "
                                       "should match within a few %."), 5),
          (stat("Head series", [q(f"max by (host) (prometheus_tsdb_head_series{{{P}}})", "{{host}}", instant=True)],
                text_mode="value_and_name", color_mode="value", thresholds=BLUE, decimals=0, text_size=(11, 18),
                desc="Series in the in-memory head block (the last ~2-3 h): the main driver of memory use."), 5))
    b.col(4,
          (bargauge("Of the 20 GB size cap", [
              q(f"({size()}) / max by (host) (prometheus_tsdb_retention_limit_bytes{{{P}}})", "{{host}}", instant=True)],
              unit="percentunit", min_=0, max_=1, decimals=1, mode="gradient",
              thresholds=steps(("green", None), ("orange", 0.8), ("red", 0.95)),
              desc="Blocks + WAL + head chunks against --storage.tsdb.retention.size (20 GB, "
                   "prometheus_tsdb_retention_limit_bytes). At 100 % the oldest blocks go before they are 7 d old."), 5),
          (bargauge("Local history", [
              q(f"time() - max by (host) (prometheus_tsdb_lowest_timestamp_seconds{{{P}}})", "{{host}}", instant=True)],
              unit="dtdurations", min_=0, max_=RETENTION_S, mode="gradient", thresholds=BLUE,
              desc="Age of the oldest sample each replica still holds; a full bar is the 7 d time retention. Longer "
                   "ranges come from Mimir only (396 d)."), 5))
    b.col(4,
          (stat("remote_write lag", [q(lag(), "{{host}}", instant=True)],
                unit="s", decimals=0, text_mode="value_and_name", color_mode="value", text_size=(11, 18),
                thresholds=steps(("green", None), ("orange", 60), ("red", 300)),
                desc="Newest sample appended minus newest sample sent to Mimir. Alert PrometheusRemoteWriteBehind "
                     "at 300 s for 10 m."), 5),
          (stat("Alerts", [q('count(ALERTS{alertstate="firing"}) or vector(0)', "firing", instant=True),
                           q('count(ALERTS{alertstate="pending"}) or vector(0)', "pending", instant=True)],
                text_mode="value_and_name", color_mode="value", decimals=0, thresholds=BLUE, text_size=(11, 18),
                links=stack_link,
                desc="Alerts the rules evaluate to right now (ALERTS, the elected replica's copy). Alertmanager's "
                     "receiver is null: nobody is paged."), 5))

    cols = [
        ("Up", f"max by (host) (up{{{P}}})"),
        ("Version", f"max by (host, version) (prometheus_build_info{{{P}}})"),
        ("Mimir", f"{ELECTED} and on (host) up{{{P}}} or max by (host) (up{{{P}}}) * 0"),
        ("Uptime", f"time() - max by (host) (process_start_time_seconds{{{P}}})"),
        ("Config", f"max by (host) (prometheus_config_last_reload_successful{{{P}}})"),
        ("Config loaded", f"time() - max by (host) (prometheus_config_last_reload_success_timestamp_seconds{{{P}}})"),
        ("Head series", f"max by (host) (prometheus_tsdb_head_series{{{P}}})"),
        ("Samples/s", f"sum by (host) (rate(prometheus_tsdb_head_samples_appended_total{{{P}}}[5m]))"),
        ("TSDB size", size()),
        ("Of 20 GB", f"({size()}) / max by (host) (prometheus_tsdb_retention_limit_bytes{{{P}}})"),
        ("History", f"time() - max by (host) (prometheus_tsdb_lowest_timestamp_seconds{{{P}}})"),
        ("remote_write lag", lag()),
        ("Alertmanagers", f"max by (host) (prometheus_notifications_alertmanagers_discovered{{{P}}})"),
        ("Targets", f"sum by (host) (prometheus_target_scrape_pool_targets{{{P}}})"),
    ]
    rename = {"host": "Replica", "version": "Prometheus"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(table("Replicas", [q(e, table=True) for _, e in cols],
                desc="One row per replica. Mimir: whose samples the HA tracker keeps now. Config loaded: since the last "
                     "successful reload (every deploy SIGHUPs it). History: age of the oldest local sample (7 d cap). "
                     "Targets: targets in the replica's scrape pools (same config on both). Click a replica for its "
                     "logs.",
                transformations=[MERGE, organize(exclude=["Time", "Value #B"], rename=rename,
                                                 order=["Replica", "Up", "Mimir", "Prometheus", "Uptime", "Config",
                                                        "Config loaded", "Targets", "Head series", "Samples/s",
                                                        "TSDB size", "Of 20 GB", "History", "remote_write lag",
                                                        "Alertmanagers"])],
                overrides=[
                    override("Up", {"mappings": UP_MAP}), cell("Up", "color-text"),
                    override("Mimir", {"mappings": mapping(**{"1": ("kept", "green"), "0": ("dropped (standby)", "blue")})}),
                    cell("Mimir", "color-text"),
                    override("Config", {"mappings": OK_FAIL}), cell("Config", "color-text"),
                    override("Uptime", {"unit": "dtdurations"}), override("Config loaded", {"unit": "dtdurations"}),
                    override("History", {"unit": "dtdurations"}),
                    override("Head series", {"decimals": 0}), override("Targets", {"decimals": 0}),
                    override("Samples/s", {"decimals": 0}), override("TSDB size", {"unit": "bytes"}),
                    override("Alertmanagers", {"decimals": 0,
                                               "thresholds": steps(("red", None), ("orange", 1), ("green", 2))}),
                    cell("Alertmanagers", "color-text"),
                    override("Of 20 GB", {"unit": "percentunit", "decimals": 1,
                                          "thresholds": steps(("green", None), ("orange", 0.8), ("red", 0.95))}),
                    cell("Of 20 GB", "color-text"),
                    override("remote_write lag", {"unit": "s", "decimals": 0,
                                                  "thresholds": steps(("green", None), ("orange", 60), ("red", 300))}),
                    cell("remote_write lag", "color-text"),
                    override("Replica", {"links": [{"title": "Logs of this replica",
                                                    "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]}),
                ], sort="Replica"), 24, 5)


def tsdb(b):
    b.row("TSDB head")
    b.add(timeseries("Head series", [
        q(f"prometheus_tsdb_head_series{{{P}}}", "{{host}} series"),
        q(f"prometheus_tsdb_head_stale_series{{{P}}}", "{{host}} stale"),
    ], fill=0, decimals=0, desc="Series in the head block, and those whose last sample is a staleness marker (target or "
                                "series gone) waiting for the next head compaction to drop them."), 8, 8)
    b.add(timeseries("Series churn", [
        q(f"sum by (host) (rate(prometheus_tsdb_head_series_created_total{{{P}}}[$__rate_interval])) * 60",
          "{{host}} created / min"),
        q(f"sum by (host) (rate(prometheus_tsdb_head_series_removed_total{{{P}}}[$__rate_interval])) * 60",
          "{{host}} removed / min"),
    ], fill=0, desc="New series per minute, and series dropped at head GC (every 2 h, the spikes of 'removed'). A steady "
                    "high 'created' means a label whose values keep changing (see New series per scrape by job)."), 8, 8)
    b.add(timeseries("Head chunks", [
        q(f"prometheus_tsdb_head_chunks{{{P}}}", "{{host}} chunks"),
        q(f"rate(prometheus_tsdb_head_chunks_created_total{{{P}}}[$__rate_interval])", "{{host}} created / s"),
    ], fill=0, desc="Chunks in the head (up to 120 samples, so about one per series per hour at 30 s) and chunks cut "
                    "per second.", overrides=[override(".*created.*", {"custom.axisPlacement": "right"}, regex=True)]),
        8, 8)
    b.add(timeseries("Samples appended by type", [
        q(f"sum by (host, type) (rate(prometheus_tsdb_head_samples_appended_total{{{P}}}[$__rate_interval]))",
          "{{host}} {{type}}")], fill=0, decimals=0,
        desc="Floats vs native histograms (none of the exporters here sends native histograms)."), 8, 7)
    b.add(timeseries("Samples rejected by the TSDB", [
        q(f"sum by (host, type) (rate(prometheus_tsdb_out_of_order_samples_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} out of order ({{type}})"),
        q(f"sum by (host, type) (rate(prometheus_tsdb_too_old_samples_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} too old ({{type}})"),
        q(f"sum by (host) (rate(prometheus_tsdb_out_of_bound_samples_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} out of bounds"),
    ], fill=10, no_value="No samples rejected in range", overrides=[override(".*", RED, regex=True)],
        desc="Samples the head refused: older than the newest of their series (out of order; there is no "
             "out_of_order_time_window locally) or older than the head's start. Targets that send their own "
             "timestamps (Telegraf, the WLC telemetry) are the usual source."), 8, 7)
    b.add(timeseries("Head time span", [
        q(f"max by (host) (prometheus_tsdb_head_max_time_seconds{{{P}}} - prometheus_tsdb_head_min_time_seconds{{{P}}})",
          "{{host}}")], unit="s", fill=0,
        desc="Time the in-memory head covers: grows to ~3 h, then 2 h of it are written out as a block (the saw "
             "tooth). Not dropping back means head compaction is stuck."), 8, 7)

    b.row("Storage and retention")
    b.add(timeseries("Disk use vs the 20 GB cap", [
        q(f"sum by (host) (prometheus_tsdb_storage_blocks_bytes{{{P}}})", "{{host}} blocks"),
        q(f"sum by (host) (prometheus_tsdb_wal_storage_size_bytes{{{P}}})", "{{host}} WAL"),
        q(f"sum by (host) (prometheus_tsdb_head_chunks_storage_size_bytes{{{P}}})", "{{host}} head chunks"),
        q(f"max(prometheus_tsdb_retention_limit_bytes{{{P}}})", "size cap (20 GB)"),
    ], unit="bytes", fill=0, min_=0, calcs=("lastNotNull", "max"),
        desc="The three parts the size cap counts, per replica; the dashed line is --storage.tsdb.retention.size.",
        overrides=[override("size cap (20 GB)", DASHED_RED)]), 8, 8)
    b.add(timeseries("Local history vs 7 d", [
        q(f"time() - max by (host) (prometheus_tsdb_lowest_timestamp_seconds{{{P}}})", "{{host}}"),
        q(f"max(prometheus_tsdb_retention_limit_seconds{{{P}}})", "time retention (7 d)"),
    ], unit="s", fill=0, min_=0,
        desc="Age of the oldest local sample. It climbs until the oldest block is entirely past 7 d, then drops by a "
             "block. Retention was cut to 7 d on 2026-11-13; the replicas held more before.",
        overrides=[override("time retention (7 d)", DASHED)]), 8, 8)
    b.add(timeseries("Blocks loaded and deleted", [
        q(f"max by (host) (prometheus_tsdb_blocks_loaded{{{P}}})", "{{host}} blocks"),
        q(f"sum by (host) (increase(prometheus_tsdb_time_retentions_total{{{P}}}[1h])) > 0", "{{host}} deleted by time / h"),
        q(f"sum by (host) (increase(prometheus_tsdb_size_retentions_total{{{P}}}[1h])) > 0", "{{host}} deleted by SIZE / h"),
    ], decimals=0, fill=0,
        desc="Persisted blocks (2 h blocks are merged into larger ones, up to 10 % of the retention). 'Deleted by SIZE' "
             "means the 20 GB cap, not the 7 d, is removing history.",
        overrides=[override(".*SIZE.*", RED, regex=True)]), 8, 8)

    b.row("WAL and compactions")
    b.add(timeseries("Compactions", [
        q(f"sum by (host) (increase(prometheus_tsdb_compactions_total{{{P}}}[1h]))", "{{host}} per hour"),
        q(f"sum by (host) (increase(prometheus_tsdb_vertical_compactions_total{{{P}}}[1h])) > 0", "{{host}} vertical / h"),
    ], decimals=0, fill=10, draw="bars",
        desc="Head-to-block writes (every 2 h) plus merges of older blocks. Vertical compactions merge overlapping "
             "blocks (out-of-order data); normally none."), 8, 7)
    b.add(timeseries("Compaction and head GC duration", [
        q(f"histogram_quantile(0.9, sum by (le, host) (rate(prometheus_tsdb_compaction_duration_seconds_bucket{{{P}}}[1h])))",
          "{{host}} compaction p90"),
        q(f"rate(prometheus_tsdb_head_gc_duration_seconds_sum{{{P}}}[1h]) / "
          f"rate(prometheus_tsdb_head_gc_duration_seconds_count{{{P}}}[1h])", "{{host}} head GC avg"),
    ], unit="s", fill=0, desc="Over the last hour (both run every 2 h, so a shorter window would mostly be empty)."), 8, 7)
    b.add(failures("TSDB failures", TSDB_FAILURES, no_value="No TSDB failures in range",
                   desc="Per hour, only the counters that rose: failed compactions, truncations, checkpoints, WAL "
                        "writes, corruptions (repaired at start; a corruption means a crash or a full disk)."), 8, 7)
    b.add(timeseries("WAL write rate and size", [
        q(f"rate(prometheus_tsdb_wal_record_parts_bytes_written_total{{{P}}}[$__rate_interval])", "{{host}} written/s"),
        q(f"prometheus_tsdb_wal_storage_size_bytes{{{P}}}", "{{host}} size"),
    ], fill=0, desc="Bytes appended to the WAL per second and its size on disk (the head's ~3 h plus the last "
                    "checkpoint; remote_write replays from it after a Mimir outage).",
        overrides=[override(".*written.*", {"unit": "Bps"}, regex=True),
                   override(".*size.*", {"unit": "bytes", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("WAL fsync", [
        q(f"rate(prometheus_tsdb_wal_fsync_duration_seconds_sum{{{P}}}[1h]) / "
          f"rate(prometheus_tsdb_wal_fsync_duration_seconds_count{{{P}}}[1h])", "{{host}} avg fsync"),
        q(f"increase(prometheus_tsdb_wal_fsync_duration_seconds_count{{{P}}}[1h])", "{{host}} fsyncs / h"),
    ], fill=0, desc="Over the last hour: the WAL is fsynced when a 128 MiB segment closes, a few times an hour. The "
                    "backends' disks are Ceph RBD, so a slow fsync here is Ceph write latency.",
        overrides=[override(".*avg.*", {"unit": "s"}, regex=True),
                   override(".*fsyncs.*", {"custom.axisPlacement": "right", "decimals": 0}, regex=True)]), 8, 7)
    b.add(timeseries("WAL checkpoints and truncations", [
        q(f"sum by (host) (increase(prometheus_tsdb_checkpoint_creations_total{{{P}}}[1h]))", "{{host}} checkpoints / h"),
        q(f"sum by (host) (increase(prometheus_tsdb_wal_truncations_total{{{P}}}[1h]))", "{{host}} truncations / h"),
    ], decimals=0, fill=10, draw="bars", desc="After each head compaction the WAL is checkpointed and truncated."), 8, 7)


def scrapes(b):
    b.row("Scrapes")
    cols = [
        ("Targets", f'max by (job) (label_replace(prometheus_target_scrape_pool_targets{{{P}}}, "job", "$1", '
                    f'"scrape_job", "(.*)"))'),
        ("Up", "count by (job) (up == 1)"),
        ("Down", "count by (job) (up == 0)"),
        ("Samples", "sum by (job) (scrape_samples_post_metric_relabeling)"),
        ("New series", "sum by (job) (avg_over_time(scrape_series_added[10m]))"),
        ("Slowest", "max by (job) (scrape_duration_seconds)"),
    ]
    rename = {"job": "Job"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(table("Scrape pools", [q(e, table=True) for _, e in cols],
                desc="Per job: targets in the pool (max of the picked replicas), up/down, samples kept per scrape after "
                     "relabeling, new series per scrape (10 m average: churn) and the slowest target's last scrape. "
                     "Up to Slowest are the elected replica's scrapes (Mimir keeps only those).",
                transformations=[MERGE, organize(exclude=["Time"], rename=rename,
                                                 order=["Job", "Targets", "Up", "Down", "Samples", "New series",
                                                        "Slowest"])],
                overrides=[override("Down", {"thresholds": steps(("green", None), ("red", 1)), "noValue": "0"}),
                           cell("Down", "color-text"), override("Up", {"noValue": "0"}),
                           override("Samples", {"decimals": 0}), override("New series", {"decimals": 1}),
                           override("Slowest", {"unit": "s",
                                                "thresholds": steps(("green", None), ("orange", 5), ("red", 10))}),
                           cell("Slowest", "color-text")],
                sort="Samples", desc_sort=True), 12, 11)
    b.add(timeseries("Slowest targets", [q("topk(10, max by (job, host) (scrape_duration_seconds))", "{{job}} {{host}}")],
                     unit="s", fill=0, placement="right", calcs=("mean", "max"),
                     desc="The ten slowest scrapes (elected replica). SNMP walks of the switches and WLCs lead; a scrape "
                          "that hits its timeout fails and the target reads down (alert TargetDown)."), 12, 11)
    b.add(timeseries("Samples per scrape by job", [q("sum by (job) (scrape_samples_post_metric_relabeling)", "{{job}}")],
                     stack=True, fill=30, decimals=0, placement="right", calcs=("lastNotNull",),
                     desc="Samples each job's targets return per scrape after metric relabeling: who fills the head."),
          8, 9)
    b.add(timeseries("New series per scrape by job", [q("sum by (job) (scrape_series_added) > 0", "{{job}}")],
                     fill=10, draw="bars", stack=True, decimals=0, calcs=("sum", "max"), no_value="No new series in range",
                     desc="Series a scrape saw for the first time, per job. Spikes at restarts and deploys are normal; a "
                          "steady stream is a churning label."), 8, 9)
    b.add(failures("Scrape drops and pool problems", SCRAPE_DROPS, no_value="Nothing dropped in range",
                   desc="Per hour, only the counters that rose: samples a scrape threw away (over sample_limit, out of "
                        "order, duplicate timestamps, out of bounds), bodies or label sets over limits, failed scrape "
                        "pool reloads and target syncs. No job here sets a sample_limit."), 8, 9)
    b.add(timeseries("Scrape interval accuracy (p99)", [
        q(f'prometheus_target_interval_length_seconds{{{P}, quantile="0.99"}}', "{{host}} {{interval}}")],
        unit="s", fill=0, calcs=("mean", "max"),
        desc="Actual time between two scrapes of a target, p99 per configured interval (10 s pvestatd, 15 s / 30 s the "
             "rest). Well above the interval: Prometheus is overloaded or the VM stalled."), 12, 7)
    b.add(timeseries("Service discovery", [
        q(f'sum by (host) (prometheus_sd_discovered_targets{{{P}, name="scrape"}})', "{{host}} scrape targets"),
        q(f'sum by (host) (prometheus_sd_discovered_targets{{{P}, name="notify"}})', "{{host}} Alertmanagers"),
        q(f"sum by (host) (prometheus_sd_failed_configs{{{P}}}) > 0", "{{host}} failed SD configs"),
    ], fill=0, decimals=0, desc="Targets found by service discovery (static_configs only here, so it changes only "
                                "with a config deploy)."), 12, 7)


def rules(b):
    b.row("Rules")
    cols = [
        ("Rules", f"max by (host, group) ({grp(f'prometheus_rule_group_rules{{{P}}}')})"),
        ("Interval", f"max by (host, group) ({grp(f'prometheus_rule_group_interval_seconds{{{P}}}')})"),
        ("Last duration", f"max by (host, group) ({grp(f'prometheus_rule_group_last_duration_seconds{{{P}}}')})"),
        ("Of interval", f"max by (host, group) ({grp(f'prometheus_rule_group_last_duration_seconds{{{P}}} / prometheus_rule_group_interval_seconds{{{P}}}')})"),
        ("Samples", f"max by (host, group) ({grp(f'prometheus_rule_group_last_evaluation_samples{{{P}}}')})"),
        ("Last run", f"time() - max by (host, group) ({grp(f'prometheus_rule_group_last_evaluation_timestamp_seconds{{{P}}}')})"),
        ("Missed", f"sum by (host, group) ({grp(f'increase(prometheus_rule_group_iterations_missed_total{{{P}}}[$__range])')})"),
    ]
    rename = {"host": "Replica", "group": "Group"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(table("Rule groups", [q(e, table=True) for _, e in cols],
                desc="Each replica evaluates every group itself (the Alertmanager cluster dedupes the alerts). Of "
                     "interval: last evaluation time against the group's interval; near 100 % the next run is skipped "
                     "(Missed, in the time range). Samples: series the group's rules returned. Last run should stay "
                     "under the interval (30 s).",
                transformations=[MERGE, organize(exclude=["Time"], rename=rename,
                                                 order=["Group", "Replica", "Rules", "Interval", "Last duration",
                                                        "Of interval", "Samples", "Last run", "Missed"])],
                overrides=[override("Interval", {"unit": "s"}), override("Last duration", {"unit": "s"}),
                           override("Of interval", {"unit": "percentunit", "decimals": 1,
                                                    "thresholds": steps(("green", None), ("orange", 0.5), ("red", 0.9))}),
                           cell("Of interval", "color-text"),
                           override("Last run", {"unit": "s", "decimals": 0,
                                                 "thresholds": steps(("green", None), ("orange", 60), ("red", 120))}),
                           cell("Last run", "color-text"),
                           override("Missed", {"decimals": 0, "thresholds": steps(("green", None), ("red", 1))}),
                           cell("Missed", "color-text"),
                           override("Rules", {"decimals": 0}), override("Samples", {"decimals": 0})],
                sort="Last duration", desc_sort=True), 14, 10)
    b.add(timeseries("Evaluation time per group", [
        q(f"topk(10, {grp(f'prometheus_rule_group_last_duration_seconds{{{P}}}')})", "{{host}} {{group}}")],
        unit="s", fill=0, placement="right", calcs=("mean", "max"),
        desc="The ten slowest group evaluations. The ceph-mixin groups (ceph.yml) and storage-health touch the most "
             "series."), 10, 10)
    b.add(timeseries("Evaluations, failures, missed runs", [
        q(f"sum by (host) (rate(prometheus_rule_evaluations_total{{{P}}}[$__rate_interval]))", "{{host}} evaluations/s"),
        q(f"sum by (host) (rate(prometheus_rule_evaluation_failures_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} failures/s"),
        q(f"sum by (host) (rate(prometheus_rule_group_iterations_missed_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} missed/s"),
    ], fill=0, desc="Rule evaluations per second; failures (a query error, e.g. many-to-many matching) and missed group "
                    "runs only show when they happen.",
        overrides=[override(".*(failures|missed).*", RED, regex=True)]), 8, 7)
    b.add(timeseries("Rule evaluation latency (p99)", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(prometheus_rule_evaluation_duration_histogram_seconds_bucket"
          f"{{{P}}}[$__rate_interval])))", "{{host}} per rule"),
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(prometheus_rule_group_duration_histogram_seconds_bucket"
          f"{{{P}}}[$__rate_interval])))", "{{host}} per group"),
    ], unit="s", fill=0, desc="One rule's query and one group's whole run (bucketed: values snap to bucket bounds)."), 8, 7)
    b.add(timeseries("Alerts pending / firing", [q("count by (alertstate) (ALERTS)", "{{alertstate}}")],
                     fill=10, stack=True, decimals=0, no_value="No alerts in range",
                     overrides=[override("firing", RED),
                                override("pending", {"color": {"mode": "fixed", "fixedColor": "orange"}})],
                     desc="Active alerts as the rules produce them (both replicas fire the same ones; this is the "
                          "elected replica's ALERTS series)."), 8, 7)


def remote_write(b):
    b.row("Remote write to Mimir")
    b.add(timeseries("Samples in / sent", [
        q(f"sum by (host) (rate(prometheus_remote_storage_samples_in_total{{{P}}}[$__rate_interval]))", "{{host}} in"),
        q(f"sum by (host) (rate(prometheus_remote_storage_samples_total{{{P}}}[$__rate_interval]))", "{{host}} sent"),
    ], fill=0, decimals=0, desc="Samples read from the WAL into the queue and samples sent to Mimir (10.13.11.103:8080), "
                                "per second. Both replicas send everything; Mimir keeps the elected one's."), 8, 8)
    b.add(timeseries("Failed / retried", [
        q(f"sum by (host) (rate(prometheus_remote_storage_samples_failed_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} failed/s"),
        q(f"sum by (host) (rate(prometheus_remote_storage_samples_retried_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} retried/s"),
        q(f"sum by (host) (rate(prometheus_remote_storage_enqueue_retries_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} enqueue retries/s"),
        q(f"sum by (host) (rate(prometheus_remote_storage_metadata_failed_total{{{P}}}[$__rate_interval])) > 0",
          "{{host}} metadata failed/s"),
    ], fill=10, no_value="No failed or retried sends in range",
        desc="Failed: Mimir answered 4xx and the batch was dropped (alert PrometheusRemoteWriteFailing). Retried: 5xx, "
             "429 or a connection error (VIP failover, Mimir restart), sent again. Enqueue retries: the queue was full.",
        overrides=[override(".*failed.*", RED, regex=True)]), 8, 8)
    b.add(timeseries("Lag behind the newest sample", [q(lag(), "{{host}}"), q("vector(300)", "alert (300 s)")],
                     unit="s", fill=0, min_=0,
                     desc="Newest sample appended minus newest sample sent. Grows while Mimir is unreachable and drains "
                          "from the WAL afterwards; alert PrometheusRemoteWriteBehind above the dashed line for 10 m.",
                     overrides=[override("alert (300 s)", DASHED_RED)]), 8, 8)
    b.add(timeseries("Queue: pending samples and bytes", [
        q(f"sum by (host) (prometheus_remote_storage_samples_pending{{{P}}})", "{{host}} pending samples"),
        q(f"sum by (host) (prometheus_remote_storage_shard_capacity{{{P}}} * prometheus_remote_storage_shards{{{P}}})",
          "{{host}} capacity"),
        q(f"sum by (host) (rate(prometheus_remote_storage_bytes_total{{{P}}}[$__rate_interval]))", "{{host}} bytes/s"),
    ], fill=0, desc="Samples buffered in the shards against their capacity (running shards × 10000), and the "
                    "compressed bytes per second on the wire.",
        overrides=[override(".*capacity.*", DASHED, regex=True),
                   override(".*bytes.*", {"unit": "Bps", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Shards", [
        q(f"max by (host) (prometheus_remote_storage_shards{{{P}}})", "{{host}} running"),
        q(f"max by (host) (prometheus_remote_storage_shards_desired{{{P}}})", "{{host}} desired"),
        q(f"max(prometheus_remote_storage_shards_max{{{P}}})", "max_shards"),
    ], fill=0, desc="Parallel senders. Prometheus scales between min and max_shards (10) by itself; desired above "
                    "running for long means the queue can't keep up.", overrides=[override("max_shards", DASHED)]), 8, 7)
    b.add(timeseries("Send latency and WAL reader", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(prometheus_remote_storage_sent_batch_duration_seconds_bucket"
          f"{{{P}}}[$__rate_interval])))", "{{host}} batch p99"),
        q(f"max by (host) (prometheus_tsdb_wal_segment_current{{{P}}}) - "
          f"max by (host) (prometheus_wal_watcher_current_segment{{{P}}})", "{{host}} WAL segments behind"),
    ], fill=0, desc="Time to push one batch (up to 2000 samples) to Mimir, p99; and how many WAL segments the "
                    "remote_write reader trails the TSDB (0 normally; climbs during a long outage).",
        overrides=[override(".*p99.*", {"unit": "s"}, regex=True),
                   override(".*segments.*", {"decimals": 0, "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(state_timeline("Replica Mimir keeps", [
        q(f'max by (replica) (cortex_ha_tracker_elected_replica_status{{{MJ}, cluster="lylat"}})', "{{replica}}")],
        mappings=mapping(**{"1": ("kept", "green"), "0": ("dropped", "blue")}),
        thresholds=steps(("blue", None), ("green", 1)),
        desc="The HA tracker's choice over time: the green bar moving is a replica failover."), 12, 6)
    b.add(timeseries("Mimir: newest sample age, standby samples dropped", [
        q(f"time() - max(cortex_distributor_latest_seen_sample_timestamp_seconds{{{MJ}}})", "newest sample age"),
        q(f'sum(rate(cortex_distributor_deduped_samples_total{{{MJ}, cluster="lylat"}}[$__rate_interval]))',
          "standby replica dropped/s"),
    ], fill=0, desc="Mimir's end of the pipe: age of the newest sample its distributors received (scrape interval + "
                    "send delay, normally under a minute) and the standby replica's samples it drops per second.",
        links=[("Mimir dashboard", MIMIR_DASH + "?" + TIME)],
        overrides=[override("newest sample age", {"unit": "s"}),
                   override(".*dropped.*", {"custom.axisPlacement": "right", "decimals": 0}, regex=True)]), 12, 6)


def notifications_queries_process(b):
    b.row("Alertmanager notifications")
    b.add(timeseries("Alerts sent per Alertmanager", [
        q(f"sum by (host, am) ({am(f'rate(prometheus_notifications_sent_total{{{P}}}[$__rate_interval])')})",
          "{{host}} → {{am}}"),
        q(f"sum by (host, am) ({am(f'rate(prometheus_notifications_errors_total{{{P}}}[$__rate_interval])')}) > 0",
          "{{host}} → {{am}} errors"),
        q(f"sum by (host) (rate(prometheus_notifications_dropped_total{{{P}}}[$__rate_interval])) > 0", "{{host}} dropped"),
    ], fill=0, desc="Each replica sends every alert to both Alertmanagers (mon01 10.13.11.30, mon02 10.13.11.31 :9093), "
                    "which dedupe them over their gossip cluster. Errors and drops only show when they happen.",
        overrides=[override(".*(errors|dropped).*", RED, regex=True)]), 8, 7)
    b.add(timeseries("Notification queue", [
        q(f"prometheus_notifications_queue_length{{{P}}}", "{{host}} queued"),
        q(f"max(prometheus_notifications_queue_capacity{{{P}}})", "capacity"),
    ], fill=0, decimals=0, desc="Alerts waiting to be sent (normally 0). A full queue drops alerts.",
        overrides=[override("capacity", DASHED)]), 8, 7)
    b.add(timeseries("Notification latency (p99)", [
        q(am(f'prometheus_notifications_latency_seconds{{{P}, quantile="0.99"}}'), "{{host}} → {{am}}")],
        unit="s", fill=0, desc="Time to post a batch of alerts to each Alertmanager."), 8, 7)

    b.row("Queries and API")
    b.add(timeseries("Query engine latency (p99)", [
        q(f"histogram_quantile(0.99, sum by (le, host, slice) (rate(prometheus_engine_query_duration_histogram_seconds_bucket"
          f"{{{P}}}[$__rate_interval])))", "{{host}} {{slice}}")], unit="s", fill=0,
        desc="Per phase: queue_time (waiting for a slot), prepare_time (selecting series), inner_eval (the PromQL). Local "
             "queries are the rules plus Explore on prometheus-mon01/02; the dashboards query Mimir."), 8, 7)
    b.add(timeseries("Concurrent queries and samples loaded", [
        q(f"prometheus_engine_queries{{{P}}}", "{{host}} running"),
        q(f"max(prometheus_engine_queries_concurrent_max{{{P}}})", "max concurrent"),
        q(f"rate(prometheus_engine_query_samples_total{{{P}}}[$__rate_interval])", "{{host}} samples loaded/s"),
    ], fill=0, desc="Queries in flight against --query.max-concurrency (20), and samples the engine loaded per second.",
        overrides=[override("max concurrent", DASHED),
                   override(".*samples.*", {"custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("HTTP API by handler", [
        q(f"topk(8, sum by (host, handler) (rate(prometheus_http_requests_total{{{P}}}[$__rate_interval])) > 0)",
          "{{host}} {{handler}}"),
        q(f'sum by (host) (rate(prometheus_http_requests_total{{{P}, code=~"5.."}}[$__rate_interval])) > 0', "{{host}} 5xx"),
    ], unit="reqps", fill=0, desc="Requests to each Prometheus: /metrics is the replicas scraping each other; "
                                  "/api/v1/query and /targets come from Grafana's per-replica datasources and lylat-obs.",
        overrides=[override(".*5xx.*", RED, regex=True)]), 8, 7)

    b.row("Process")
    b.add(timeseries("CPU", [q(f"rate(process_cpu_seconds_total{{{P}}}[$__rate_interval])", "{{host}}")],
                     unit="percentunit", fill=0, min_=0, desc="CPU seconds per second (1 = one core).",
                     links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)]), 6, 7)
    b.add(timeseries("Memory", [
        q(f"process_resident_memory_bytes{{{P}}}", "{{host}} RSS"),
        q(f"go_memstats_heap_inuse_bytes{{{P}}}", "{{host}} heap in use"),
        q(f"go_memstats_next_gc_bytes{{{P}}}", "{{host}} next GC"),
    ], unit="bytes", fill=0, min_=0, desc="Resident memory grows with head series; next GC is the heap size at which "
                                          "Go collects next."), 6, 7)
    b.add(timeseries("Goroutines and file descriptors", [
        q(f"go_goroutines{{{P}}}", "{{host}} goroutines"),
        q(f"process_open_fds{{{P}}}", "{{host}} open fds"),
    ], fill=0, decimals=0, desc="Goroutines grow with targets and remote_write shards; open fds are block files, the "
                                "WAL and connections."), 6, 7)
    b.add(timeseries("Go GC pause (max)", [q(f'go_gc_duration_seconds{{{P}, quantile="1.0"}}', "{{host}}")],
                     unit="s", fill=0, desc="Longest stop-the-world GC pause in the recent window."), 6, 7)

    b.row("Logs", collapsed=True)
    b.add(per_bucket("Warnings and errors per replica", [
        lq(f"sum by (host) (count_over_time({WARN_LOG} [$__auto]))", "{{host}}")],
        desc="Prometheus' own WARN/ERROR lines. The journal marks every container line as priority 'error', so this "
             "matches level= in the text."), 8, 9)
    b.add(logs("Prometheus warnings and errors", WARN_LOG, max_lines=300,
               desc="TSDB, remote_write, rule and notifier problems (failed scrapes are not logged)."), 16, 9)
    b.add(logs("Prometheus log", '{app="prometheus", host=~"$host"}', max_lines=300,
               desc="All lines: compactions ('write block'), WAL checkpoints, config reloads ('Completed loading of "
                    "configuration file')."), 24, 10)


def prometheus():
    b = Board()
    status(b)
    tsdb(b)
    scrapes(b)
    rules(b)
    remote_write(b)
    notifications_queries_process(b)

    host = query_var("host", "Replica", 'label_values(prometheus_build_info{job="prometheus"}, host)')
    links = [dict(DB_LINK),
             link("Monitoring stack", STACK_DASH, "dashboard", "The whole monitoring stack on one page"),
             link("Logs", LOGS_DASH + "?var-host=mon01&var-host=mon02", "doc", "Logs overview for mon01 and mon02")]
    for name in ("mon01", "mon02"):
        links.append(link(f"Explore {name}", explore(f"prometheus-{name}", 'up{job="prometheus"}'), "bolt",
                          f"PromQL straight against {name}'s own Prometheus (7 d local history, its own scrapes)",
                          keep_time=False, blank=True))
    return dashboard("prometheus-server", "Prometheus",
                     "The two Prometheus replicas on mon01/mon02: health checks, TSDB head and storage against the "
                     "7 d / 20 GB caps, WAL and compactions, scrape pools, rule groups, remote write to Mimir (HA "
                     "tracker), Alertmanager notifications, queries and the process. Replica picker.",
                     b, tags=["databases", "prometheus"], variables=[host], extra_links=links)


DASHBOARDS = {"Databases/prometheus.json": prometheus}
