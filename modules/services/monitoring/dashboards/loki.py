"""Databases/loki: Loki (loki01-03): ingestion, streams, chunks to RGW, queries, retention; Alloy senders.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with its helpers; see
custom.py for the conventions. The deep dive behind the "Loki and Alloy (logs)" row of monitoring-stack.

The setup (modules/services/monitoring/logging.tf, README "Logging (Loki HA)"):

- Loki 3.7 monolithic (-target=all) on loki01-03, one ring over memberlist on the HA VLAN 214
  (10.21.12.34-36, which is also the `ingester` label of the distributor metrics), replication_factor 3,
  auth disabled (tenant "fake"). TSDB index schema v13, chunks and index in the Ceph RGW bucket `loki`
  through a local haproxy (127.0.0.1:7480 -> the RGWs on macbeth/titania/venom). Retention 90d, applied by
  the one compactor the ring elects. The ruler (rules in /etc/loki/rules/fake) sends to both Alertmanagers.
- keepalived VIPs 10.13.11.101 (backend: Grafana, Alloy pushes) and 10.5.11.101 (syslog from devices).
- Alloy on every Linux VM (job alloy, 24 senders): journal -> Loki; on loki01-03 also the syslog
  receiver, pushing to the local Loki. dns01/02 and proxy01/02 push over mgmt to all three Lokis
  (one loki.write endpoint each, exported_host = the endpoint), so their entries count three times
  on the Loki side; the ingesters drop the identical copies.

Jobs: loki (:3100), alloy (:12345), haproxy (the log VMs' RGW haproxy, :8405), node (role logging).
"""
from custom import (
    BLUE, LOGS_DASH, MERGE, ORANGE_IF_ANY, PERCENT, STACK_DASH, UP_MAP, Board, bargauge, cell, dashboard,
    fixed_color, mapping, matrix, organize, override, q, query_var, stat, state_timeline, steps, table,
    timeseries,
)
from logs import LOGS_LINK, by_total, logs, lq, per_bucket

TIME = "${__url_time_range}"
L = 'job="loki"'
LH = 'job="loki", host=~"$instance"'
A = 'job="alloy"'
AS = 'job="alloy", host=~"$sender"'
HAP = 'job="haproxy", proxy="rgw"'
NODE = 'job="node", role="logging"'
VIPS = {"backend": "10.13.11.101", "monitoring": "10.5.11.101"}
RGWS = 3  # logging_settings.rgw_endpoints
# Loki's HTTP query API (everything under /loki/api/v1 except the push), as the route label spells it.
QUERY_ROUTES = 'route=~"loki_api_v1_.+", route!="loki_api_v1_push"'
EXPLORE = ('/explore?schemaVersion=1&panes={"loki":{"datasource":"loki","queries":[{"refId":"A",'
           '"expr":"{app=\\"loki\\"}"}],"range":{"from":"now-1h","to":"now"}}}')

DB_LINK = {"type": "dashboards", "tags": ["databases"], "asDropdown": True, "title": "Database dashboards",
           "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
           "tooltip": "", "url": ""}


def url_link(title, url, icon="dashboard"):
    return {"type": "link", "title": title, "url": url, "icon": icon, "includeVars": False, "keepTime": True,
            "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}


OK_FAIL = mapping(**{"0": ("FAIL", "red"), "1": ("OK", "green")})
OK_STEPS = steps(("red", None), ("green", 1))
DASHED = {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]}}


def rate(metric, sel=LH, by="host", window="$__rate_interval"):
    return f"sum by ({by}) (rate({metric}{{{sel}}}[{window}]))"


def avg_hist(metric, sel=LH, by="host"):
    """Mean of a histogram/summary over the rate window: rate(_sum) / rate(_count)."""
    return (f"sum by ({by}) (rate({metric}_sum{{{sel}}}[$__rate_interval])) / "
            f"sum by ({by}) (rate({metric}_count{{{sel}}}[$__rate_interval]))")


def pct(quantile, metric, sel=LH, by="host"):
    return f"histogram_quantile({quantile}, sum by (le, {by}) (rate({metric}_bucket{{{sel}}}[$__rate_interval])))"


def red(name):
    return override(f".*{name}.*", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True)


def loki():
    b = Board()

    # --- Status -------------------------------------------------------------------------------
    b.row("Status")
    b.col(4,
          (stat("VIPs on", [q(f'max by (host) (node_network_address_info{{{NODE}, address="{VIPS["backend"]}"}})',
                              "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NOBODY", text_size=(12, 26),
                desc=f"The log VM holding keepalived's VIPs ({VIPS['backend']} for Grafana and the Alloy pushes, "
                     f"{VIPS['monitoring']} for syslog from the devices; one VRRP instance, they move together). Its "
                     "Alloy receives the devices' syslog and its distributor most pushes."), 4),
          (stat("Compactor", [q(f"max by (host) (loki_boltdb_shipper_compactor_running{{{L}}}) == 1", "{{host}}",
                                instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NONE ELECTED", text_size=(12, 26),
                desc="The instance the compactor ring elected (a single token): only it compacts the index and "
                     "applies retention (90d)."), 4))
    checks = [
        ("Lokis up", f"min(up{{{L}}}) or vector(0)"),
        ("ingester ring 3 ACTIVE",
         f'(min(loki_ring_members{{{L}, name="ingester", state="ACTIVE"}}) or vector(0)) >= bool 3'),
        ("no unhealthy members", f'(max(loki_ring_members{{{L}, state="Unhealthy"}}) or vector(0)) == bool 0'),
        ("chunk flushes OK",
         f"(sum(increase(loki_ingester_chunks_flush_failures_total{{{L}}}[15m])) or vector(0)) == bool 0"),
        ("syslog arriving", f"(sum(rate(loki_source_syslog_entries_total{{{A}}}[15m])) or vector(0)) > bool 0"),
        ("Alloy not dropping",
         f"(sum(increase(loki_write_dropped_entries_total{{{A}}}[15m])) or vector(0)) == bool 0"),
        (f"all {RGWS} RGWs UP", f"(min(haproxy_backend_active_servers{{{HAP}}}) or vector(0)) >= bool {RGWS}"),
        ("backend VIP held once",
         f'(count(node_network_address_info{{{NODE}, address="{VIPS["backend"]}"}}) or vector(0)) == bool 1'),
        ("syslog VIP held once",
         f'(count(node_network_address_info{{{NODE}, address="{VIPS["monitoring"]}"}}) or vector(0)) == bool 1'),
        ("retention ran < 1 h",
         f"(time() - max(loki_compactor_apply_retention_last_successful_run_timestamp_seconds{{{L}}})) < bool 3600"),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 14), orientation="horizontal",
               desc="Mirrors the logging alert group (logging.tf): TargetDown, LokiRingMembersMissing (fewer than 3 "
                    "ACTIVE ingesters), LokiRingUnhealthy, LokiIngesterFlushFailures and AlloyLokiWriteDrops (over the "
                    "last 15 min), SyslogIngestStopped, RGWBackendDegraded/Down (haproxy on every log VM sees all 3 "
                    "RGWs) and LoggingVIPNotHeldOnce per VIP. 'retention ran' is no alert: the compactor applies "
                    "retention every compaction_interval (10 min)."), 8, 8)
    b.col(4,
          (stat("Lines received/s", [q(f"sum(rate(loki_distributor_lines_received_total{{{L}}}[$__rate_interval]))")],
                graph=True, color_mode="value", thresholds=BLUE, decimals=1, text_size=(12, 22),
                desc="Log lines all distributors accept per second (before the ingesters drop duplicates: the dns "
                     "and proxy VMs push to all three Lokis)."), 4),
          (stat("Bytes received/s", [q(f"sum(rate(loki_distributor_bytes_received_total{{{L}}}[$__rate_interval]))")],
                graph=True, unit="Bps", color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Uncompressed line bytes the distributors accept per second."), 4))
    b.col(4,
          (stat("Streams in memory", [q(f"max(loki_ingester_memory_streams{{{L}}})", instant=True)],
                decimals=0, color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Active streams (unique label sets) held by an ingester. With RF 3 and three ingesters each "
                     "holds every stream, so this is the max of the three."), 4),
          (stat("Bucket loki (RGW)", [
              q('max(ceph_rgw_bucket_size_bytes{bucket="loki"})', "size", instant=True),
              q('max(ceph_rgw_bucket_objects{bucket="loki"})', "objects", instant=True)],
              text_mode="value_and_name", color_mode="value", thresholds=BLUE, text_size=(11, 18),
              overrides=[override("size", {"unit": "bytes"}), override("objects", {"unit": "short", "decimals": 0})],
              desc="Chunks and TSDB index in Ceph (RGW bucket stats from the Ceph mgr). Grows until the 90d "
                   "retention starts deleting."), 4))
    b.col(4,
          (stat("Since last retention run", [
              q(f"time() - max(loki_compactor_apply_retention_last_successful_run_timestamp_seconds{{{L}}})",
                instant=True)],
              unit="dtdurations", color_mode="value", text_size=(12, 22),
              thresholds=steps(("green", None), ("orange", 1800), ("red", 3600)),
              desc="Since the elected compactor last applied retention successfully (it marks chunks older than "
                   "90d; the sweeper deletes them after retention_delete_delay, 2 h)."), 4),
          (stat("Discarded in range", [
              q(f"sum(increase(loki_discarded_samples_total{{{L}}}[$__range])) or vector(0)", "lines", instant=True)],
              decimals=0, color_mode="value", thresholds=ORANGE_IF_ANY, text_size=(12, 22),
              desc="Lines Loki refused in the time range, summed over the three Lokis (a line the ingesters refuse "
                   "is counted by each replica). Reasons in Ingestion > Discarded lines by reason."), 4))

    b.row("Instances")
    cols = [
        ("Up", f"max by (host) (up{{{L}}})"),
        ("Version", f"max by (host, version) (loki_build_info{{{L}}})"),
        ("Up for", f"time() - max by (host) (process_start_time_seconds{{{L}}})"),
        ("VIPs", f'max by (host) (node_network_address_info{{{NODE}, address="{VIPS["backend"]}"}})'),
        ("Compactor", f"max by (host) (loki_boltdb_shipper_compactor_running{{{L}}})"),
        ("Lines/s", rate("loki_distributor_lines_received_total", L, window="5m")),
        ("Streams", f"max by (host) (loki_ingester_memory_streams{{{L}}})"),
        ("Chunks", f"max by (host) (loki_ingester_memory_chunks{{{L}}})"),
        ("Flush queue", f"max by (host) (loki_ingester_flush_queue_length{{{L}}})"),
        ("RGWs UP", f"max by (host) (haproxy_backend_active_servers{{{HAP}}})"),
        ("Memory", f"max by (host) (process_resident_memory_bytes{{{L}}})"),
        ("Ruler groups", f"count by (host) (loki_prometheus_rule_group_rules{{{L}}})"),
    ]
    rename = {"host": "Instance", "version": "Loki"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(table("Loki instances", [q(e, table=True) for _, e in cols],
                desc="One row per Loki. VIPs: holds the keepalived VIPs. Compactor: the elected one. Lines/s: what its "
                     "distributor accepts (pushes land on the VIP holder, each log VM's own Alloy on its local Loki). "
                     "Streams/Chunks: in its ingester's memory. Flush queue: chunks waiting for S3 (should be 0). "
                     "RGWs UP: healthy RGWs its haproxy sees. Ruler groups: rule groups the ruler ring gave it "
                     "(one group, 'logging', on one of the three).",
                transformations=[MERGE, organize(exclude=["Time", "Value #B"], rename=rename,
                                                 order=["Instance", "Up", "VIPs", "Compactor", "Loki", "Up for",
                                                        "Lines/s", "Streams", "Chunks", "Flush queue", "RGWs UP",
                                                        "Memory", "Ruler groups"])],
                overrides=[override("Up", {"mappings": UP_MAP}), cell("Up", "color-text"),
                           override("VIPs", {"mappings": mapping(**{"1": ("VIPs", "green")})}),
                           cell("VIPs", "color-text"),
                           override("Compactor", {"mappings": mapping(**{"1": ("elected", "green"),
                                                                         "0": ("-", "text")})}),
                           cell("Compactor", "color-text"),
                           override("Up for", {"unit": "dtdurations"}), override("Memory", {"unit": "bytes"}),
                           override("Lines/s", {"decimals": 1}),
                           override("RGWs UP", {"thresholds": steps(("red", None), ("orange", 1), ("green", RGWS))}),
                           cell("RGWs UP", "color-text"),
                           override("Flush queue", {"thresholds": steps(("green", None), ("orange", 1))}),
                           cell("Flush queue", "color-text"),
                           override("Instance", {"links": [{"title": "Logs of this VM",
                                                            "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]})],
                sort="Instance"), 24, 5)

    # --- Ingestion ----------------------------------------------------------------------------
    b.row("Ingestion")
    b.add(timeseries("Received per distributor", [
        q(rate("loki_distributor_lines_received_total"), "{{host}} lines"),
        q(rate("loki_distributor_bytes_received_total"), "{{host}} bytes"),
        q(rate("loki_distributor_structured_metadata_bytes_received_total"), "{{host}} structured metadata"),
    ], fill=0, desc="Lines (left) and bytes (right axis) each distributor accepts per second. Structured metadata: "
                    "per-line key/values outside the labels.",
        overrides=[override(".*(bytes|metadata).*", {"unit": "Bps", "custom.axisPlacement": "right"},
                            regex=True)]), 8, 8)
    b.add(timeseries("Push requests (HTTP /loki/api/v1/push)", [
        q(f'sum by (status_code) (rate(loki_request_duration_seconds_count{{{LH}, route="loki_api_v1_push"}}'
          f'[$__rate_interval]))', "{{status_code}}"),
        q(pct(0.99, "loki_request_duration_seconds", f'{LH}, route="loki_api_v1_push"', by="route"), "p99 latency"),
    ], fill=10, unit="reqps",
        desc="Pushes from the Alloys by HTTP status (204 = accepted; 429 = rate limited; 500 = the ingesters didn't "
             "answer: Alloy retries 5xx/429 with backoff and drops the batch after its last retry) and the p99 "
             "latency (right axis).",
        overrides=[override("p99 latency", {"unit": "s", "custom.axisPlacement": "right", "custom.fillOpacity": 0}),
                   fixed_color("204", "green"), fixed_color("429", "orange"), red("5[0-9][0-9]")]), 8, 8)
    b.add(timeseries("Discarded lines by reason", [
        q(f"sum by (host, reason) (rate(loki_discarded_samples_total{{{LH}}}[$__rate_interval])) * 60 > 0",
          "{{host}} {{reason}}")],
        fill=10, stack=True, decimals=1, no_value="Nothing discarded in range",
        desc="Lines per minute Loki refused. too_far_behind: older than its stream's newest line minus "
             "max_chunk_age/2 (an out-of-order sender: a device whose clock is behind, or a resend after a VIP "
             "move); every ingester counts it, so the three hosts show the same lines. rate_limited / "
             "per_stream_rate_limit: over ingestion_rate_mb 16 / the per-stream limit (the push gets a 429)."), 8, 8)
    b.add(by_total(per_bucket("Lines stored by host (Loki)", [
        lq('topk(15, sum by (host) (count_over_time({source=~".+"} [$__auto])))', "{{host}}")],
        desc="From Loki itself (LogQL over every stream): lines per bucket of the 15 busiest hosts, after the "
             "duplicate copies were dropped. The monitoring and service VMs log their journal (source=journal), "
             "the devices and PVE nodes syslog. Logs overview has the lines.",
        links=[("Logs overview", LOGS_DASH + "?" + TIME)])), 12, 8)
    b.add(per_bucket("Bytes stored by source (Loki)", [
        lq('sum by (source) (bytes_over_time({source=~".+"} [$__auto]))', "{{source}}")],
        unit="bytes", desc="Log bytes per bucket: syslog (network devices, PVE nodes) vs the VMs' journals. LogQL "
                           "over every stream, so a long range takes a few seconds."), 12, 8)
    b.add(timeseries("Distributor → ingester appends", [
        q(f"sum by (host, ingester) (rate(loki_distributor_ingester_appends_total{{{LH}}}[$__rate_interval]))",
          "{{host}} → {{ingester}}"),
        q(f"sum by (host, ingester) (rate(loki_distributor_ingester_append_timeouts_total{{{LH}}}[$__rate_interval]))"
          f" > 0", "{{host}} → {{ingester}} timeout"),
    ], fill=0, desc="Push batches each distributor sends to each ingester (by ring address: 10.21.12.34-36 = "
                    "loki01-03 on VLAN 214). With RF 3 every batch goes to all three; a write succeeds once two "
                    "answer. Timeouts: an ingester that didn't answer in time (restart, overload).",
        overrides=[red("timeout")]), 8, 7)
    b.add(timeseries("Bytes per line", [
        q(pct(0.5, "loki_bytes_per_line", L, by="job"), "p50"),
        q(pct(0.99, "loki_bytes_per_line", L, by="job"), "p99"),
        q(avg_hist("loki_bytes_per_line", L, by="job"), "mean"),
    ], unit="bytes", fill=0, desc="Size of the lines pushed (all distributors; bucket boundaries are powers of 2, so "
                                  "the quantiles are coarse)."), 8, 7)
    b.add(timeseries("Ingester push (gRPC)", [
        q(f'sum by (host, status_code) (rate(loki_request_duration_seconds_count{{{LH}, '
          f'route="/logproto.Pusher/Push"}}[$__rate_interval]))', "{{host}} {{status_code}}"),
        q(pct(0.99, "loki_request_duration_seconds", f'{LH}, route="/logproto.Pusher/Push"'), "{{host}} p99"),
    ], fill=0, unit="reqps",
        desc="Push requests each ingester gets from the distributors, by result (429: the ingester's per-stream "
             "limit), and their p99 latency (right axis).",
        overrides=[override(".*p99.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   override(".*(429|error).*", {"color": {"mode": "fixed", "fixedColor": "orange"}}, regex=True)]),
        8, 7)

    # --- Ingesters and chunks -----------------------------------------------------------------
    b.row("Ingesters and chunks")
    b.add(timeseries("Streams in memory", [
        q(f"sum by (host) (loki_ingester_memory_streams{{{LH}}})", "{{host}} streams"),
        q(f"sum by (host) (rate(loki_ingester_streams_created_total{{{LH}}}[$__rate_interval])) * 60",
          "{{host}} created/min"),
        q(f"sum by (host) (rate(loki_ingester_streams_removed_total{{{LH}}}[$__rate_interval])) * 60",
          "{{host}} removed/min"),
    ], fill=0, desc="Active streams per ingester, and churn (dashed, right axis): a stream is created on its first "
                    "line and removed once its chunks are flushed and it went idle. High churn means a label with "
                    "many values (e.g. a per-request id) in the stream labels.",
        overrides=[override(".*/min.*", {"custom.axisPlacement": "right", **DASHED}, regex=True)]), 8, 7)
    b.add(timeseries("Chunks in memory and flush queue", [
        q(f"sum by (host) (loki_ingester_memory_chunks{{{LH}}})", "{{host}} chunks"),
        q(f"sum by (host) (loki_ingester_flush_queue_length{{{LH}}})", "{{host}} flush queue"),
    ], fill=0, decimals=0, desc="Open and not yet flushed chunks per ingester, and chunks queued for upload to S3 "
                                "(right axis). The queue should drain to 0 within seconds; a growing queue means S3 "
                                "(haproxy, RGW) is slow or failing.",
        overrides=[override(".*queue.*", {"custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Chunks flushed by reason", [
        q(f"sum by (reason) (rate(loki_ingester_chunks_flushed_total{{{LH}}}[$__rate_interval])) * 60", "{{reason}}"),
        q(f"sum by (host) (rate(loki_ingester_chunks_flush_failures_total{{{LH}}}[$__rate_interval])) * 60 > 0",
          "{{host}} FAILED"),
    ], fill=30, stack=True, decimals=1,
        desc="Chunks per minute (selected ingesters) by why they were cut: idle (stream quiet for chunk_idle_period, "
             "30 m), max_age (2 h), full (target size reached), synced. Mostly idle/max_age = many small streams. "
             "FAILED: alert LokiIngesterFlushFailures.",
        overrides=[red("FAILED"),
                   override(".*FAILED.*", {"custom.stacking": {"mode": "none", "group": "A"}}, regex=True)]), 8, 7)
    b.add(timeseries("Chunk utilisation and size at flush", [
        q(avg_hist("loki_ingester_chunk_utilization"), "{{host}} utilisation"),
        q(avg_hist("loki_ingester_chunk_size_bytes"), "{{host}} size (compressed)"),
    ], fill=0, desc="Mean fill of the flushed chunks against the target chunk size (1.5 MB), and their mean "
                    "compressed size (right axis). Low utilisation is expected here: most streams are quiet and get "
                    "flushed idle or at max_age.",
        overrides=[override(".*utilisation.*", {"unit": "percentunit"}, regex=True),
                   override(".*size.*", {"unit": "bytes", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Chunk age and entries at flush", [
        q(pct(0.5, "loki_ingester_chunk_age_seconds"), "{{host}} age p50"),
        q(avg_hist("loki_ingester_chunk_entries"), "{{host}} entries (mean)"),
    ], fill=0, desc="How long a chunk was open when it was flushed, and how many lines it held (right axis).",
        overrides=[override(".*age.*", {"unit": "s"}, regex=True),
                   override(".*entries.*", {"custom.axisPlacement": "right", "decimals": 0}, regex=True)]), 8, 7)
    b.add(timeseries("Chunk bytes stored / compression", [
        q(rate("loki_ingester_chunk_stored_bytes_total"), "{{host}} stored"),
        q(avg_hist("loki_ingester_chunk_compression_ratio"), "{{host}} compression ratio"),
    ], fill=0, desc="Compressed chunk bytes each ingester writes to S3 per second (every ingester flushes the same "
                    "chunks: three writes of one object), and the mean compression ratio (right axis).",
        overrides=[override(".*stored.*", {"unit": "Bps"}, regex=True),
                   override(".*ratio.*", {"custom.axisPlacement": "right", "decimals": 1}, regex=True)]), 8, 7)

    # --- WAL ----------------------------------------------------------------------------------
    b.row("WAL and checkpoints")
    b.add(timeseries("WAL writes", [
        q(rate("loki_ingester_wal_logged_bytes_total"), "{{host}} bytes"),
        q(rate("loki_ingester_wal_records_logged_total"), "{{host}} records"),
    ], fill=0, desc="What each ingester appends to its write-ahead log (/var/lib/logging/loki/wal, the VM's root "
                    "disk) so unflushed chunks survive a restart. Records/s on the right axis.",
        overrides=[override(".*bytes.*", {"unit": "Bps"}, regex=True),
                   override(".*records.*", {"unit": "ops", "custom.axisPlacement": "right"}, regex=True)]), 6, 7)
    b.add(timeseries("WAL disk usage", [
        q(f"max by (host) (loki_ingester_wal_disk_usage_percent{{{LH}}})", "{{host}}"),
    ], unit="percentunit", fill=0, min_=0,
        desc="Usage of the filesystem the WAL is on (the VM's root disk; Loki reports 0-1). Above "
             "wal.disk_full_threshold (90 %) the ingester stops writing the WAL and keeps data in memory only."), 6, 7)
    b.add(timeseries("Checkpoints", [
        q(f'max by (host) (loki_ingester_checkpoint_duration_seconds{{{LH}, quantile="0.5"}})', "{{host}} duration"),
        q(f"sum by (host) (increase(loki_ingester_checkpoint_creations_failed_total{{{LH}}}[1h])) > 0",
          "{{host}} failed / h"),
    ], fill=0, desc="A checkpoint writes every in-memory chunk to the WAL dir so the log segments before it can be "
                    "deleted (every 5 min; Loki spreads the writes over the interval, so ~4 min is normal).",
        overrides=[override(".*duration.*", {"unit": "s"}, regex=True), red("failed"),
                   override(".*failed.*", {"custom.axisPlacement": "right", "decimals": 0}, regex=True)]), 6, 7)
    b.add(stat("WAL problems in range", [
        q(f"sum(increase(loki_ingester_wal_corruptions_total{{{LH}}}[$__range])) or vector(0)", "corruptions",
          instant=True),
        q(f"sum(increase(loki_ingester_wal_disk_full_failures_total{{{LH}}}[$__range])) or vector(0)", "disk full",
          instant=True),
        q(f"sum(increase(loki_ingester_checkpoint_creations_failed_total{{{LH}}}[$__range])) or vector(0)",
          "checkpoint failures", instant=True),
        q(f"max(loki_ingester_wal_replay_active{{{LH}}}) or vector(0)", "replaying now", instant=True),
    ], text_mode="value_and_name", decimals=0, color_mode="value", thresholds=ORANGE_IF_ANY,
        orientation="horizontal", text_size=(11, 16),
        desc="Corrupt WAL records skipped at replay, WAL writes skipped because the disk was full, failed "
             "checkpoints, and whether an ingester is replaying its WAL right now (after a restart; it isn't ready "
             "until done)."), 6, 7)

    # --- Ring ---------------------------------------------------------------------------------
    b.row("Ring and memberlist")
    b.add(table("Ring members by state", [q(f"min by (name, state) (loki_ring_members{{{L}}})", table=True)],
                desc="Members of each Loki ring by state, as seen by the Loki that sees fewest. Every ring should list "
                     "3 ACTIVE and 0 elsewhere; LEAVING/JOINING during a restart, Unhealthy = missed heartbeats "
                     "(alert LokiRingUnhealthy; ingester ring below 3 ACTIVE: LokiRingMembersMissing).",
                transformations=matrix("state", row="name", corner="Ring"),
                overrides=[override("ACTIVE", {"thresholds": steps(("red", None), ("orange", 2), ("green", 3))}),
                           cell("ACTIVE", "color-text"),
                           override("Unhealthy", {"thresholds": steps(("green", None), ("red", 1))}),
                           cell("Unhealthy", "color-text")]), 8, 7)
    b.add(timeseries("memberlist", [
        q(f"min by (host) (loki_memberlist_client_cluster_members_count{{{LH}}})", "{{host}} members"),
        q(f"max by (host) (loki_memberlist_client_cluster_node_health_score{{{LH}}})", "{{host}} health score"),
    ], fill=0, decimals=0, min_=0,
        desc="Gossip members each Loki sees on VLAN 214 (3 expected), and its memberlist health score (right axis; "
             "0 = healthy, rises when it misses probes, e.g. a CPU-starved VM).",
        overrides=[override(".*score.*", {"custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Ring KV updates and errors", [
        q(f"sum by (host) (rate(loki_memberlist_client_cas_success_total{{{LH}}}[$__rate_interval])) * 60",
          "{{host}} ring updates/min"),
        q(f"sum by (host) (rate(loki_memberlist_client_cas_failure_total{{{LH}}}[$__rate_interval])) * 60 > 0",
          "{{host}} CAS failures/min"),
        q(f"sum by (host) (rate(loki_memberlist_tcp_transport_packets_sent_errors_total{{{LH}}}[$__rate_interval]))"
          f" * 60 > 0", "{{host}} send errors/min"),
        q(f"sum by (host) (rate(loki_memberlist_client_received_broadcasts_dropped_total{{{LH}}}"
          f"[$__rate_interval])) * 60 > 0", "{{host}} broadcasts dropped/min"),
    ], fill=0, decimals=1,
        desc="Ring state updates (heartbeats, token changes) and what went wrong: failed compare-and-swap on the "
             "ring key, packets the TCP transport couldn't send to a peer, gossip messages dropped.",
        overrides=[override(".*(failures|errors|dropped).*", {"color": {"mode": "fixed", "fixedColor": "red"}},
                            regex=True)]), 8, 7)

    # --- Queries ------------------------------------------------------------------------------
    b.row("Queries")
    b.add(timeseries("Query requests by route", [
        q(f"sum by (route) (rate(loki_request_duration_seconds_count{{{LH}, {QUERY_ROUTES}}}[$__rate_interval]))",
          "{{route}}")],
        unit="reqps", fill=30, stack=True, placement="right",
        desc="Requests to Loki's query API per route (Grafana panels, Explore, Logs Drilldown's volume and "
             "patterns): they arrive on the VIP holder's frontend."), 8, 8)
    b.add(timeseries("Query latency p99 by route", [
        q(f"histogram_quantile(0.99, sum by (le, route) (rate(loki_request_duration_seconds_bucket{{{LH}, "
          f"{QUERY_ROUTES}}}[$__rate_interval])))", "{{route}}")],
        unit="s", fill=0, placement="right",
        desc="End-to-end time of the query API requests at the frontend. Range queries over days of every stream "
             "(the log dashboards' totals) take seconds."), 8, 8)
    b.add(timeseries("Query errors by route and status", [
        q(f'sum by (route, status_code) (rate(loki_request_duration_seconds_count{{{LH}, {QUERY_ROUTES}, '
          f'status_code=~"[45]..|cancel"}}[$__rate_interval])) * 60 > 0', "{{route}} {{status_code}}")],
        fill=10, decimals=1, stack=True, placement="right", no_value="No failed queries in range",
        desc="Failed query requests per minute. 499/cancel = the client gave up (a dashboard refreshed or closed "
             "before the answer); 400 = a bad LogQL expression; 429 = query limits; 5xx = Loki failed."), 8, 8)
    b.add(timeseries("LogQL execution latency by type", [
        q(f"histogram_quantile(0.99, sum by (le, type) (rate(loki_logql_querystats_latency_seconds_bucket{{{LH}}}"
          f"[$__rate_interval])))", "{{type}} p99"),
        q(f"histogram_quantile(0.5, sum by (le, type) (rate(loki_logql_querystats_latency_seconds_bucket{{{LH}}}"
          f"[$__rate_interval])))", "{{type}} p50"),
    ], unit="s", fill=0, desc="Per executed (sub)query, by kind: filter = log lines, metric = count_over_time & co., "
                              "limited = plain selector, series/volume/stats = metadata. p50 dashed.",
        overrides=[override(".*p50.*", DASHED, regex=True)]), 8, 7)
    b.add(timeseries("Data processed by queries", [
        q(f"histogram_quantile(0.5, sum by (le, type) (rate(loki_logql_querystats_bytes_processed_per_seconds_bucket"
          f"{{{LH}}}[$__rate_interval])))", "{{type}} throughput p50"),
        q(f"sum by (host) (rate(loki_store_chunks_downloaded_total{{{LH}}}[$__rate_interval]))",
          "{{host}} chunks downloaded/s"),
    ], fill=0, desc="Bytes per second a query scans (decompressed), and chunks fetched from the store per querier "
                    "(right axis). The newest data (not yet flushed) comes from the ingesters, the rest from S3.",
        overrides=[override(".*throughput.*", {"unit": "Bps"}, regex=True),
                   override(".*chunks.*", {"custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Scheduler queue and caches", [
        q(f"sum by (host) (loki_query_scheduler_queue_length{{{LH}}})", "{{host}} queued"),
        q(f"sum by (host) (loki_querier_worker_inflight_queries{{{LH}}})", "{{host}} running"),
        q(f"sum by (name) (rate(loki_cache_hits{{{LH}}}[$__rate_interval])) / "
          f"sum by (name) (rate(loki_cache_fetched_keys{{{LH}}}[$__rate_interval]))", "{{name}} hit ratio"),
    ], fill=0, desc="Queries waiting in the query scheduler and sub-queries the queriers run; and the hit ratio of "
                    "Loki's embedded caches (chunks, results; right axis).",
        overrides=[override(".*hit ratio.*", {"unit": "percentunit", "custom.axisPlacement": "right"},
                            regex=True)]), 8, 7)

    # --- Storage ------------------------------------------------------------------------------
    b.row("Object storage (Ceph RGW bucket loki)")
    b.add(timeseries("S3 requests by operation", [
        q(f"sum by (operation) (rate(loki_s3_request_duration_seconds_count{{{LH}}}[$__rate_interval]))",
          "{{operation}}"),
        q(f'sum by (operation, status_code) (rate(loki_s3_request_duration_seconds_count{{{LH}, '
          f'status_code!~"2.."}}[$__rate_interval])) > 0', "{{operation}} {{status_code}} ERROR"),
    ], unit="reqps", fill=0,
        desc="Requests the selected Lokis send to S3 (through the local haproxy) per operation: PutObject = chunk "
             "flushes and index uploads, GetObject = queries and index sync, List = index tables, DeleteObject = "
             "retention. ERROR: non-2xx answers.",
        overrides=[red("ERROR")]), 8, 7)
    b.add(timeseries("S3 latency by operation", [
        q(pct(0.99, "loki_s3_request_duration_seconds", by="operation"), "{{operation}} p99"),
        q(avg_hist("loki_s3_request_duration_seconds", by="operation"), "{{operation}} mean"),
    ], unit="s", fill=0, desc="Time to the RGWs and back, per operation (Ceph RGW on macbeth/titania/venom). Mean "
                              "dashed.",
        overrides=[override(".*mean.*", DASHED, regex=True)]), 8, 7)
    b.add(timeseries("haproxy → RGWs", [
        q(f"max by (host) (haproxy_backend_active_servers{{{HAP}}})", "{{host}} RGWs UP"),
        q(f"max by (host) (haproxy_backend_response_time_average_seconds{{{HAP}}})", "{{host}} response time"),
        q(f'sum by (host) (rate(haproxy_backend_http_responses_total{{{HAP}, code="5xx"}}[$__rate_interval])) * 60'
          f' > 0', "{{host}} 5xx/min"),
    ], fill=0, desc="Each log VM's haproxy (127.0.0.1:7480) and the three RGWs behind it: healthy servers (alerts "
                    "RGWBackendDegraded below 3, RGWBackendDown at 0), mean response time of its last 1024 requests "
                    "(right axis) and 5xx answers.",
        overrides=[override(".*UP.*", {"decimals": 0}, regex=True),
                   override(".*response time.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   red("5xx")]), 8, 7)
    b.add(timeseries("Bucket size", [
        q('max(ceph_rgw_bucket_size_bytes{bucket="loki"})', "size"),
        q('max(ceph_rgw_bucket_objects{bucket="loki"})', "objects"),
    ], fill=10, desc="The bucket loki in Ceph (RGW bucket stats, before replication). Grows until the 90d retention "
                     "catches up (the schema started 2026-11-01). Objects on the right axis.",
        overrides=[override("size", {"unit": "bytes"}),
                   override("objects", {"custom.axisPlacement": "right", "decimals": 0, "custom.fillOpacity": 0})]),
        8, 7)
    b.add(timeseries("Index (TSDB) uploads and syncs", [
        q(f"sum by (host, status) (increase(loki_tsdb_shipper_tables_upload_operation_total{{{LH}}}[1h]))",
          "{{host}} upload {{status}}"),
        q(f"sum by (host, status) (increase(loki_tsdb_shipper_tables_sync_operation_total{{{LH}}}[1h]))",
          "{{host}} sync {{status}}"),
    ], fill=0, decimals=0,
        desc="Per hour: each ingester ships its TSDB index files to S3, and each querier syncs the index tables it "
             "needs from S3. A failure status means that window's index may be missing from S3 until the next "
             "upload.",
        overrides=[override(".*fail.*", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True)]), 8, 7)
    b.add(timeseries("Chunk store traffic", [
        q(rate("loki_chunk_store_stored_chunk_bytes_total"), "{{host}} written"),
        q(rate("loki_chunk_store_fetched_chunk_bytes_total"), "{{host}} fetched"),
    ], unit="Bps", fill=10, desc="Chunk bytes each Loki writes to and reads from the store (written = flushes; "
                                 "fetched = queries reaching past the ingesters)."), 8, 7)

    # --- Compactor and retention --------------------------------------------------------------
    b.row("Compactor and retention")
    b.add(state_timeline("Elected compactor", [
        q(f"max by (host) (loki_boltdb_shipper_compactor_running{{{L}}})", "{{host}}")],
        mappings=mapping(**{"1": ("compactor", "green"), "0": ("standby", "blue")}),
        thresholds=steps(("blue", None), ("green", 1)),
        desc="Which Loki ran the compactor when. Exactly one should be green at a time; it moves when that VM "
             "restarts."), 8, 6)
    b.add(timeseries("Since last successful run", [
        q(f"time() - max(loki_boltdb_shipper_compact_tables_operation_last_successful_run_timestamp_seconds{{{L}}})",
          "compaction"),
        q(f"time() - max(loki_compactor_apply_retention_last_successful_run_timestamp_seconds{{{L}}})", "retention"),
    ], unit="s", fill=0, min_=0,
        desc="Age of the last successful index compaction and retention pass (the newest over all three, so a "
             "standby's old timestamp doesn't count). A saw-tooth up to ~10 min (compaction_interval) is normal; a "
             "line that keeps rising means the compactor is stuck or failing."), 8, 6)
    b.add(timeseries("Compactor operations", [
        q(f"sum by (status) (increase(loki_boltdb_shipper_compact_tables_operation_total{{{L}}}[1h]))",
          "compaction {{status}} / h"),
        q(f"sum by (status) (increase(loki_compactor_apply_retention_operation_total{{{L}}}[1h]))",
          "retention {{status}} / h"),
        q(f"max(loki_compactor_apply_retention_operation_duration_seconds{{{L}}})", "retention duration"),
        q(f"max(loki_compactor_pending_delete_requests_count{{{L}}})", "pending delete requests"),
    ], fill=0, decimals=1,
        desc="Runs per hour by result, how long the last retention pass took (right axis), and log delete requests "
             "(Grafana / API deletes) waiting to be processed.",
        overrides=[override(".*duration.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   override(".*fail.*", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True)]), 8, 6)

    # --- Ruler --------------------------------------------------------------------------------
    b.row("Ruler (log alert rules)")
    b.add(timeseries("Rule evaluation", [
        q(f"max by (host) (loki_prometheus_rule_group_last_duration_seconds{{{LH}}})", "{{host}} duration"),
        q(f"sum by (host) (increase(loki_prometheus_rule_evaluation_failures_total{{{LH}}}[1h])) > 0",
          "{{host}} failures / h"),
        q(f"sum by (host) (increase(loki_prometheus_rule_group_iterations_missed_total{{{LH}}}[1h])) > 0",
          "{{host}} missed / h"),
    ], fill=0, desc="The 'logging' group (BGPSessionDownLogged, SataLinkReset) runs on the ruler that owns it in the "
                    "ruler ring. Duration of its last evaluation; failed rules and skipped iterations (evaluation "
                    "slower than the interval) per hour, right axis.",
        overrides=[override(".*duration.*", {"unit": "s"}, regex=True),
                   override(".*(failures|missed).*", {"color": {"mode": "fixed", "fixedColor": "red"},
                                                      "custom.axisPlacement": "right", "decimals": 0},
                            regex=True)]), 12, 6)
    b.add(timeseries("Alerts sent to Alertmanager", [
        q(f"sum by (host, alertmanager) (increase(loki_prometheus_notifications_sent_total{{{LH}}}[1h])) > 0",
          "{{host}} → {{alertmanager}}"),
        q(f"sum by (host) (increase(loki_prometheus_notifications_errors_total{{{LH}}}[1h])) > 0", "{{host}} errors"),
        q(f"sum by (host) (increase(loki_prometheus_notifications_dropped_total{{{LH}}}[1h])) > 0",
          "{{host}} dropped"),
    ], fill=0, decimals=0, no_value="No log alerts sent in range",
        desc="Alert notifications per hour, per Alertmanager (both get every alert; the cluster dedups). Only the "
             "ruler that evaluates the group sends, and only while a log alert is firing.",
        overrides=[red("errors"), red("dropped")]), 12, 6)

    # --- Alloy --------------------------------------------------------------------------------
    b.row("Alloy senders")
    acols = [
        ("Up", f"max by (host) (up{{{AS}}})"),
        ("Version", f"max by (host, version) (alloy_build_info{{{AS}}})"),
        ("Pushes to", f"count by (host) (max by (host, exported_host) (loki_write_sent_entries_total{{{AS}}}))"),
        ("Entries/s", f"max by (host) (rate(loki_write_sent_entries_total{{{AS}}}[5m]))"),
        ("Dropped in range", f"sum by (host) (increase(loki_write_dropped_entries_total{{{AS}}}[$__range]))"),
        ("Retries in range", f"sum by (host) (increase(loki_write_batch_retries_total{{{AS}}}[$__range]))"),
        ("Config", f"max by (host) (alloy_config_last_load_successful{{{AS}}})"),
        ("Unhealthy components",
         f'sum by (host) (alloy_component_controller_running_components{{{AS}, health_type!="healthy"}}) '
         f'or max by (host) (up{{{AS}}}) * 0'),
        ("Up for", f"time() - max by (host) (alloy_resources_process_start_time_seconds{{{AS}}})"),
        ("Memory", f"max by (host) (alloy_resources_process_resident_memory_bytes{{{AS}}})"),
    ]
    arename = {"host": "Sender", "version": "Alloy"}
    arename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(acols)})
    b.add(table("Alloys", [q(e, table=True) for _, e in acols],
                desc="Every Alloy that ships logs. Pushes to: Loki endpoints it writes to (1 = the VIP or its local "
                     "Loki; 3 = the dns and proxy VMs, which push to all three Lokis over mgmt). Entries/s: lines it "
                     "pushes (one endpoint's count). Dropped: entries it gave up on (alert AlloyLokiWriteDrops; "
                     "reason ingester_error = Loki answered 5xx until the last retry). Config: last reload of "
                     "config.alloy succeeded. Unhealthy components: pipeline components not healthy.",
                transformations=[MERGE, organize(exclude=["Time", "Value #B"], rename=arename,
                                                 order=["Sender", "Up", "Alloy", "Pushes to", "Entries/s",
                                                        "Dropped in range", "Retries in range", "Config",
                                                        "Unhealthy components", "Up for", "Memory"])],
                overrides=[override("Up", {"mappings": UP_MAP}), cell("Up", "color-text"),
                           override("Config", {"mappings": OK_FAIL}), cell("Config", "color-text"),
                           override("Entries/s", {"decimals": 2}),
                           override("Dropped in range", {"decimals": 0,
                                                         "thresholds": steps(("green", None), ("red", 1))}),
                           cell("Dropped in range", "color-text"),
                           override("Retries in range", {"decimals": 0,
                                                         "thresholds": steps(("green", None), ("orange", 1))}),
                           cell("Retries in range", "color-text"),
                           override("Unhealthy components", {"decimals": 0,
                                                             "thresholds": steps(("green", None), ("red", 1))}),
                           cell("Unhealthy components", "color-text"),
                           override("Up for", {"unit": "dtdurations"}), override("Memory", {"unit": "bytes"}),
                           override("Sender", {"links": [{"title": "Logs of this VM",
                                                          "url": LOGS_DASH + "?var-host=${__value.raw}&" + TIME}]})],
                sort="Sender"), 24, 9)
    b.add(timeseries("Entries pushed per sender", [
        q(f"max by (host) (rate(loki_write_sent_entries_total{{{AS}}}[$__rate_interval]))", "{{host}}")],
        fill=30, stack=True, placement="right",
        desc="Lines each Alloy pushes per second (for the dns/proxy VMs one endpoint's count: the other two carry "
             "the same lines). The log VMs' own Alloys carry the devices' syslog as well as their journal."), 12, 8)
    b.add(timeseries("Dropped, retried and failed pushes", [
        q(f"sum by (host, reason) (increase(loki_write_dropped_entries_total{{{AS}}}[$__rate_interval])) > 0",
          "{{host}} dropped ({{reason}})"),
        q(f"sum by (host) (increase(loki_write_batch_retries_total{{{AS}}}[$__rate_interval])) > 0",
          "{{host}} batch retries"),
        q(f'sum by (host, status_code) (increase(loki_write_request_duration_seconds_count{{{AS}, '
          f'status_code!~"2.."}}[$__rate_interval])) > 0', "{{host}} push {{status_code}}"),
    ], fill=30, draw="bars", decimals=0, placement="right", no_value="No failed pushes in range",
        desc="Per bucket: entries dropped after the last retry, batch retries, and pushes Loki answered with "
             "something other than 2xx (429 limit, 500 ingesters, -1 = no answer, e.g. during a VIP move or a Loki "
             "restart).",
        overrides=[red("dropped")]), 12, 8)
    b.add(timeseries("Push latency and entry delay", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(loki_write_request_duration_seconds_bucket{{{AS}}}"
          f"[$__rate_interval])))", "{{host}} push p99"),
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(loki_write_entry_propagation_latency_seconds_bucket"
          f"{{{AS}}}[$__rate_interval])))", "{{host}} entry delay p99"),
    ], unit="s", fill=0, placement="right",
        desc="Push p99: one HTTP push to Loki. Entry delay p99 (dashed): from the line's timestamp to its push, "
             "which includes batching, retries and, for syslog, the sender's clock.",
        overrides=[override(".*delay.*", DASHED, regex=True)]), 12, 8)
    b.add(timeseries("Sources: journal and syslog", [
        q(f"sum by (host) (rate(loki_source_journal_target_lines_total{{{AS}}}[$__rate_interval]))",
          "{{host}} journal"),
        q(f"sum by (host) (rate(loki_source_syslog_entries_total{{{AS}}}[$__rate_interval]))", "{{host}} syslog"),
        q(f"sum by (host) (rate(loki_source_syslog_parsing_errors_total{{{AS}}}[$__rate_interval])) > 0",
          "{{host}} syslog parse errors"),
        q(f"sum by (host) (rate(loki_source_syslog_empty_messages_total{{{AS}}}[$__rate_interval])) > 0",
          "{{host}} syslog empty"),
    ], fill=0, placement="right",
        desc="Lines each Alloy reads: its VM's journal, and on loki01-03 the syslog listeners (the VIP holder gets "
             "the devices; mgmt-VRF senders spread over all three). Parse errors: a sender whose format the "
             "listener can't parse (move it to the raw UDP 1514 listener). SyslogIngestStopped fires when all "
             "syslog stops for 15 min.", overrides=[red("parse errors"), red("empty")]), 12, 8)

    # --- Resources ----------------------------------------------------------------------------
    b.row("Resources")
    b.add(timeseries("Loki CPU", [
        q(f"sum by (host) (rate(process_cpu_seconds_total{{{LH}}}[$__rate_interval]))", "{{host}}")],
        unit="percentunit", fill=0, min_=0, desc="CPU cores used by each Loki process (100 % = one core)."), 6, 7)
    b.add(timeseries("Loki memory", [
        q(f"max by (host) (process_resident_memory_bytes{{{LH}}})", "{{host}} RSS"),
        q(f"max by (host) (go_memstats_heap_inuse_bytes{{{LH}}})", "{{host}} Go heap"),
    ], unit="bytes", fill=0, min_=0, desc="Resident memory and Go heap in use (dashed). Streams, chunks and the "
                                          "embedded caches live in the heap.",
        overrides=[override(".*heap.*", DASHED, regex=True)]), 6, 7)
    b.add(timeseries("Alloy CPU (top 10)", [
        q(f"topk(10, sum by (host) (rate(alloy_resources_process_cpu_seconds_total{{{AS}}}[$__rate_interval])))",
          "{{host}}")],
        unit="percentunit", fill=0, min_=0, placement="right",
        desc="The busiest Alloys (100 % = one core). The log VMs parse syslog as well as their journal."), 6, 7)
    b.add(timeseries("Alloy memory (top 10)", [
        q(f"topk(10, max by (host) (alloy_resources_process_resident_memory_bytes{{{AS}}}))", "{{host}}")],
        unit="bytes", fill=0, min_=0, placement="right", desc="Resident memory of the largest Alloys."), 6, 7)
    b.add(timeseries("Log VMs: CPU and memory", [
        q(f'1 - avg by (host) (rate(node_cpu_seconds_total{{{NODE}, mode="idle"}}[$__rate_interval]))',
          "{{host}} CPU"),
        q(f"1 - node_memory_MemAvailable_bytes{{{NODE}}} / node_memory_MemTotal_bytes{{{NODE}}}", "{{host}} memory"),
    ], unit="percentunit", fill=0, min_=0, max_=1,
        desc="loki01-03 as a whole (Loki, Alloy, haproxy, node_exporter, keepalived). Memory dashed.",
        overrides=[override(".*memory.*", DASHED, regex=True)]), 12, 6)
    b.add(bargauge("Log VMs: root FS used", [
        q(f'1 - node_filesystem_avail_bytes{{{NODE}, mountpoint="/"}} / node_filesystem_size_bytes{{{NODE}, '
          f'mountpoint="/"}}', "{{host}}", instant=True)],
        unit="percentunit", min_=0, max_=1, thresholds=PERCENT, mode="gradient",
        desc="The WAL, TSDB index cache, compactor working dir and ruler WAL live on / (/var/lib/logging/loki); "
             "chunks are in S3. Alert FilesystemAlmostFull."), 12, 6)

    # --- Logs ---------------------------------------------------------------------------------
    b.row("Loki and Alloy logs", collapsed=True)
    real = r'| regexp `level=(?P<lvl>[a-z]+)` | lvl=~"warn|error"'
    b.add(per_bucket("Loki warnings and errors per instance", [
        lq(f'sum by (host, lvl) (count_over_time({{app="loki", host=~"loki0[0-9]"}} {real} [$__auto]))',
           "{{host}} {{lvl}}")],
        desc="Loki's own warn/error lines (the level= in the line: the journal marks all of Podman's stderr as "
             "err). 'context canceled' errors are queries the client abandoned."), 12, 7)
    b.add(per_bucket("Alloy warnings and errors per VM", [
        lq(f'sum by (host) (count_over_time({{app="alloy"}} {real} [$__auto]))', "{{host}}")],
        desc="Alloy's own warn/error lines on every VM: failed pushes, syslog listener problems, reloads."), 12, 7)
    b.add(logs("Loki warnings and errors",
               '{app="loki", host=~"loki0[0-9]"} |~ `level=(warn|error)` != `context canceled`', max_lines=300,
               desc="Without the 'context canceled' noise of abandoned queries."), 12, 10)
    b.add(logs("Alloy warnings and errors", '{app="alloy"} |~ `level=(warn|error)`', max_lines=300,
               desc="Alloy's warn/error lines from every VM's journal."), 12, 10)

    instance = query_var("instance", "Loki", f"label_values(loki_build_info{{{L}}}, host)")
    sender = query_var("sender", "Alloy sender", f"label_values(alloy_build_info{{{A}}}, host)")
    return dashboard("loki", "Loki",
                     "Loki on loki01-03 (RF 3, chunks in the Ceph RGW bucket loki) and the Alloys that feed it: "
                     "health checks mirroring the logging alerts, ingestion and discards, ingesters, chunks and WAL, "
                     "the ring, queries, S3, compactor and retention, ruler, every Alloy sender, resources.",
                     b, tags=["databases", "loki"], variables=[instance, sender],
                     extra_links=[DB_LINK, LOGS_LINK, url_link("Monitoring stack", STACK_DASH + "?" + TIME),
                                  url_link("Explore Loki", EXPLORE, icon="info")])


DASHBOARDS = {"Databases/loki.json": loki}
