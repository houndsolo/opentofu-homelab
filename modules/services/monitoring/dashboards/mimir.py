"""Databases/mimir: Mimir (mim01-03): ingestion, HA dedup, ingesters, compactor, store, queries, object storage.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with its helpers.
The deep dive behind the Mimir row of Monitoring/monitoring-stack.

Setup (modules/services/monitoring/metrics.tf): Mimir 3.x monolithic (`target: all`, classic architecture,
no ingest storage) on mim01-03, one ring of three, replication factor 3, everything in the tenant
"anonymous" (multitenancy off). Both Prometheus replicas (mon01/mon02) remote_write everything to the
keepalived VIP 10.13.11.103:8080; the distributors' HA tracker (cluster label ha_cluster, replica label
__replica__, kv in memberlist) keeps the elected replica's samples (HTTP 200) and acknowledges the other
one's without storing them (HTTP 202). Blocks go to the Ceph RGW bucket "mimir" through a local haproxy on
127.0.0.1:7480 (job haproxy-mimir, :8405). The ruler runs but has no rules (alerting stays in Prometheus);
compactor_block_upload_enabled lets `mimirtool backfill` upload old blocks (InfluxDB history).
Jobs: mimir (:8080/metrics, host label = VM), haproxy-mimir, node (role metrics). Logs: Loki app="mimir".
"""
from custom import (
    BLUE, LOGS_DASH, MERGE, NODE_DASH, PERCENT, RED_IF_ANY, STACK_DASH, UP_STEPS, Board, bargauge, cell,
    dashboard, mapping, organize, override, q, query_var, stat, state_timeline, steps, table, timeseries,
)
from logs import logs, lq, per_bucket

TIME = "${__url_time_range}"
M = 'job="mimir"'
MH = 'job="mimir", host=~"$host"'
HA = 'job="haproxy-mimir"'
NODE = 'job="node", role="metrics"'
VIP = "10.13.11.103"
RGW_DASH = "/d/ceph-rgw-buckets/ceph-rgw-buckets"
RINGS = "ingester|store-gateway|compactor|distributor"   # the rings MimirRingMembersMissing watches
N_MIMIR = f"scalar(count(up{{{M}}}))"                   # the rule's length(var.metrics): every Mimir target
# Prometheus' remote_write lag, as alert PrometheusRemoteWriteBehind computes it.
RW_LAG = ('max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job="prometheus"} - ignoring(remote_name, url) '
          'group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job="prometheus"})')
OBJ = f'{MH}, component!="ruler-storage"'   # ruler_storage is the local filesystem, not S3
MIMIR_WARN = "level=(warn|error)"

DB_LINK = {"type": "dashboards", "tags": ["databases"], "asDropdown": True, "title": "Database dashboards",
           "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False, "tooltip": "", "url": ""}


def url_link(title, url):
    return {"type": "link", "title": title, "url": url, "icon": "dashboard", "includeVars": False, "keepTime": True,
            "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}


OK_FAIL = mapping(**{"0": ("FAIL", "red"), "1": ("OK", "green")})
OK_STEPS = steps(("red", None), ("green", 1))
DASHED = {"custom.lineStyle": {"fill": "dash", "dash": [6, 4]}, "color": {"mode": "fixed", "fixedColor": "orange"}}


def rate(metric, by="host", sel=MH, window="$__rate_interval"):
    return f"sum by ({by}) (rate({metric}{{{sel}}}[{window}]))"


def hist(qtl, metric, sel, by="host", window="$__rate_interval"):
    return f"histogram_quantile({qtl}, sum by (le, {by}) (rate({metric}_bucket{{{sel}}}[{window}])))"


def red(pattern):
    return override(f".*({pattern}).*", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True)


def mimir():
    b = Board()

    # --- Status ---------------------------------------------------------------------------
    b.row("Status")
    checks = [
        ("all targets up", 'min(up{job=~"mimir|haproxy-mimir"}) == bool 1'),
        ("rings: all ACTIVE", f'(min(cortex_ring_members{{{M}, name=~"{RINGS}", state="ACTIVE"}}) or vector(0)) >= bool {N_MIMIR}'),
        ("rings: none unhealthy", f'(max(cortex_ring_members{{{M}, state="Unhealthy"}}) or vector(0)) == bool 0'),
        ("one replica elected", f"(count(max by (replica) (cortex_ha_tracker_elected_replica_status{{{M}}}) == 1) or vector(0)) == bool 1"),
        ("no samples discarded", f'(sum(rate(cortex_discarded_samples_total{{{M}, reason!="replicas_did_not_match"}}[10m])) or vector(0)) == bool 0'),
        ("remote_write OK", '(sum(rate(prometheus_remote_storage_samples_failed_total{job="prometheus"}[10m])) or vector(0)) == bool 0'),
        ("remote_write < 5 min behind", f"(max({RW_LAG}) or vector(0)) < bool 300"),
        ("blocks reach S3", f"(sum(increase(cortex_ingester_shipper_upload_failures_total{{{M}}}[15m])) or vector(0)) == bool 0"),
        ("compactor ran < 24 h", f"time() - max(cortex_compactor_last_successful_run_timestamp_seconds{{{M}}}) < bool 86400"),
        ("RGW behind haproxy", f'(min(haproxy_backend_active_servers{{{HA}, proxy="rgw"}}) or vector(0)) > bool 0'),
        ("VIP held once", f'(count(node_network_address_info{{{NODE}, address="{VIP}"}}) or vector(0)) == bool 1'),
    ]
    b.add(stat("Checks", [q(e, name, instant=True) for name, e in checks], text_mode="value_and_name",
               mappings=OK_FAIL, thresholds=OK_STEPS, text_size=(11, 14), orientation="horizontal",
               desc="Mimir's invariants, the same ones the metrics alert group watches: TargetDown, MimirRingMembersMissing "
                    "(ingester/store-gateway/compactor/distributor rings with fewer ACTIVE members than Mimir targets), "
                    "MimirRingUnhealthy, MimirDiscardingSamples (the HA dedup's replicas_did_not_match excluded), "
                    "PrometheusRemoteWriteFailing / -Behind (> 300 s), MimirBlockUploadFailures (15 m), "
                    "MimirCompactorNotRunning (24 h), MimirRGWBackendDown and MimirVIPNotHeldOnce. 'one replica elected' "
                    "has no alert: the HA tracker must accept exactly one Prometheus."), 8, 9)
    b.col(4,
          (stat("Accepted Prometheus", [q(f"max by (replica) (cortex_ha_tracker_elected_replica_status{{{M}}}) == 1",
                                          "{{replica}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NONE", text_size=(12, 26),
                desc="The replica (__replica__) whose samples the HA tracker stores; the other one's pushes are answered "
                     "202 and dropped. It fails over when the elected replica sends nothing for 30 s (ha_tracker "
                     "failover timeout)."), 3),
          (stat("VIP on", [q(f'max by (host) (node_network_address_info{{{NODE}, address="{VIP}"}})', "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value="NOBODY", text_size=(12, 26),
                desc=f"The Mimir VM holding keepalived's VIP {VIP}: Prometheus pushes and Grafana queries arrive there "
                     "(its distributor and query-frontend fan out to all three)."), 3),
          (stat("Version", [q(f"count by (version) (mimir_build_info{{{M}}})", "{{version}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Mimir version(s) running; two names = a rolling upgrade in progress."), 3))
    b.col(4,
          (stat("Active series", [q(f'max(cortex_ingester_active_series{{{M}, user="anonymous"}})', instant=True)],
                decimals=0, color_mode="value", thresholds=BLUE, text_size=(12, 26),
                desc="Series that received a sample recently (per ingester; RF 3 means every ingester holds all of them)."), 3),
          (stat("of the series limit", [q(f'max(cortex_ingester_active_series{{{M}}}) / '
                                          f'max(cortex_ingester_local_limits{{{M}, limit="max_global_series_per_user"}})', instant=True)],
                unit="percentunit", decimals=1, color_mode="value", text_size=(12, 26),
                thresholds=steps(("green", None), ("orange", 0.8), ("red", 0.95)),
                desc="Active series against max_global_series_per_user (metrics_settings.max_series, as each ingester "
                     "enforces it). At 100 % new series are rejected (discarded reason per_user_series_limit)."), 3),
          (stat("Samples / s stored", [q(f"sum(rate(cortex_distributor_received_samples_total{{{M}}}[5m]))")],
                decimals=0, graph=True, color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Samples the distributors accept after the HA dedup (one Prometheus' worth)."), 3))
    b.col(4,
          (stat("Last compaction", [q(f"time() - max(cortex_compactor_last_successful_run_timestamp_seconds{{{M}}})", instant=True)],
                unit="dtdurations", color_mode="value", text_size=(12, 26),
                thresholds=steps(("green", None), ("orange", 7200), ("red", 86400)),
                desc="Since the newest successful compactor run on any VM (every hour; alert MimirCompactorNotRunning "
                     "after 24 h)."), 3),
          (stat("Last block shipped", [q(f"time() - max(cortex_ingester_shipper_last_successful_upload_timestamp_seconds{{{M}}})",
                                         instant=True)],
                unit="dtdurations", color_mode="value", text_size=(12, 26),
                thresholds=steps(("green", None), ("orange", 3 * 3600), ("red", 6 * 3600)),
                desc="Since an ingester last uploaded a 2 h TSDB block to S3 (normally every 2 h)."), 3),
          (stat("S3 bucket mimir", [q('max(ceph_rgw_bucket_size_actual_bytes{bucket="mimir"})', instant=True)],
                unit="bytes", color_mode="value", thresholds=BLUE, text_size=(12, 22),
                links=[("Ceph RGW buckets", RGW_DASH + "?" + TIME)],
                desc="Size of the RGW bucket holding every block (retention 396 d), from the Ceph RGW bucket stats."), 3))
    b.col(4,
          (stat("Rejected / failed in range", [
              q(f'sum(increase(cortex_discarded_samples_total{{{M}, reason!="replicas_did_not_match"}}[$__range])) or vector(0)',
                "discarded samples", instant=True),
              q(f'sum(increase(cortex_request_duration_seconds_count{{{M}, route="api_v1_push", status_code=~"5.."}}[$__range])) or vector(0)',
                "pushes 5xx", instant=True),
              q(f'sum(increase(cortex_per_tenant_request_total{{{M}, status_code=~"ERROR_(INTERNAL|EXECUTION)"}}[$__range])) or vector(0)',
                "query errors", instant=True),
              q(f'sum(increase(thanos_objstore_bucket_operation_failures_total{{{M}, component!="ruler-storage"}}[$__range])) or vector(0)',
                "S3 op failures", instant=True),
              q(f"sum(increase(cortex_compactor_runs_failed_total{{{M}}}[$__range])) or vector(0)", "compactor runs failed", instant=True),
          ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=RED_IF_ANY, orientation="horizontal",
              text_size=(11, 14),
              desc="Counts over the time range. Pushes 5xx: Prometheus retries them (a restart or ring change). Query "
                   "errors: queries that failed inside a querier (cancelled ones not counted)."), 9))

    # --- Ingestion ------------------------------------------------------------------------
    b.row("Ingestion (distributors and HA tracker)")
    b.add(timeseries("Samples in / stored / deduplicated", [
        q(f"sum(rate(cortex_distributor_samples_in_total{{{MH}}}[$__rate_interval]))", "pushed (both replicas)"),
        q(f"sum(rate(cortex_distributor_received_samples_total{{{MH}}}[$__rate_interval]))", "stored (elected replica)"),
        q(f"sum(rate(cortex_distributor_deduped_samples_total{{{MH}}}[$__rate_interval]))", "dropped by HA dedup"),
        q(f'sum by (reason) (rate(cortex_discarded_samples_total{{{MH}, reason!="replicas_did_not_match"}}[$__rate_interval])) > 0',
          "discarded: {{reason}}"),
    ], fill=0, desc="Samples/s at the distributors. pushed ≈ stored + dropped: both Prometheus replicas send everything, "
                    "the HA tracker keeps one. Any 'discarded' line is a limit or validation rejection.",
        overrides=[red("discarded")]), 8, 8)
    b.add(timeseries("Pushes by Mimir and response", [
        q(f'sum by (host, status_code) (rate(cortex_request_duration_seconds_count{{{MH}, route="api_v1_push"}}[$__rate_interval]))',
          "{{host}} {{status_code}}")],
        unit="reqps", fill=0,
        desc="remote_write requests per Mimir: the VIP holder gets them all. 200 = elected replica stored, 202 = the "
             "other replica's push acknowledged and dropped (HA dedup), 4xx = rejected (limits), 5xx = failed "
             "(Prometheus retries).",
        overrides=[override(".* 5..$", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True),
                   override(".* 4..$", {"color": {"mode": "fixed", "fixedColor": "orange"}}, regex=True)]), 8, 8)
    b.add(timeseries("Push latency", [
        q(hist(0.99, "cortex_request_duration_seconds", f'{MH}, route="api_v1_push"'), "{{host}} p99"),
        q(hist(0.5, "cortex_request_duration_seconds", f'{MH}, route="api_v1_push"'), "{{host}} p50"),
    ], unit="s", fill=0, min_=0, desc="remote_write request duration at the receiving Mimir: distributor + write to "
                                      "all three ingesters (quorum 2 of 3)."), 8, 8)
    b.add(state_timeline("Elected Prometheus replica", [
        q(f"max by (replica) (cortex_ha_tracker_elected_replica_status{{{M}}})", "{{replica}}")],
        mappings=mapping(**{"1": ("elected", "green"), "0": ("standby", "blue")}),
        thresholds=steps(("blue", None), ("green", 1)),
        desc="Which Prometheus the HA tracker accepted when. A switch means the elected one stopped pushing for 30 s "
             "(restart, network); a gap of ~30 s in the data at that moment is normal."), 8, 6)
    b.add(timeseries("HA tracker elections and sample age", [
        q(f"max(increase(cortex_ha_tracker_elected_replica_changes_total{{{M}}}[1h]))", "replica changes / h"),
        q(f"sum(rate(cortex_distributor_sample_delay_seconds_sum{{{MH}}}[$__rate_interval])) / "
          f"sum(rate(cortex_distributor_sample_delay_seconds_count{{{MH}}}[$__rate_interval]))", "avg sample age at push (s)"),
    ], fill=0, desc="Replica changes per hour (each distributor counts them; the max is shown). Sample age: how old the "
                    "samples are when they reach the distributor (scrape → remote_write queue → push). It rises while "
                    "Prometheus catches up after an outage.",
        overrides=[override(".*age.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   override(".*changes.*", {"custom.drawStyle": "bars", "custom.fillOpacity": 60, "decimals": 0}, regex=True)]), 8, 6)
    b.add(timeseries("Prometheus → Mimir remote_write", [
        q(RW_LAG, "{{host}} behind (s)"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_failed_total{job="prometheus"}[$__rate_interval])) > 0', "{{host}} failed/s"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_retried_total{job="prometheus"}[$__rate_interval])) > 0', "{{host}} retried/s"),
    ], fill=0, min_=0, desc="The senders' side: how far each Prometheus is behind (alert PrometheusRemoteWriteBehind at "
                            "300 s) and samples it failed or retried (5xx/429 from Mimir). Details: Prometheus dashboard.",
        overrides=[red("failed"), override(".*behind.*", {"unit": "s"}, regex=True)]), 8, 6)
    b.add(timeseries("Distributor load and rejections", [
        q(f"sum by (host) (cortex_distributor_inflight_push_requests{{{MH}}})", "{{host}} in-flight pushes"),
        q(f"sum by (host, reason) (rate(cortex_distributor_instance_rejected_requests_total{{{MH}}}[$__rate_interval])) > 0",
          "{{host}} rejected: {{reason}}"),
        q(f"sum by (host, reason) (rate(cortex_ingester_instance_rejected_requests_total{{{MH}}}[$__rate_interval])) > 0",
          "{{host}} ingester rejected: {{reason}}"),
    ], fill=0, min_=0, decimals=0, desc="Pushes being processed now, and pushes refused by an instance limit "
                                        "(max_inflight_push_requests: 2000 per distributor, 30000 per ingester).",
        overrides=[red("rejected")]), 8, 6)
    b.add(timeseries("Ingestion rate per Mimir", [
        q(f"sum by (host) (cortex_distributor_ingestion_rate_samples_per_second{{{MH}}})", "{{host}} distributor"),
        q(f"sum by (host) (cortex_ingester_ingestion_rate_samples_per_second{{{MH}}})", "{{host}} ingester"),
    ], fill=0, decimals=0, desc="Each distributor's own sliding-window rate (the VIP holder takes them all) and the "
                                "samples each ingester appends (RF 3: each one appends every stored sample). The "
                                "tenant's ingestion_rate limit is 300k samples/s (metrics_settings)."), 8, 6)
    b.add(timeseries("Discarded samples by reason", [
        q(f'sum by (reason) (rate(cortex_discarded_samples_total{{{MH}, reason!="replicas_did_not_match"}}[$__rate_interval]))',
          "{{reason}}")],
        fill=30, stack=True, no_value="No samples discarded in range",
        desc="Samples Mimir rejected (alert MimirDiscardingSamples): rate_limited / per_user_series_limit (raise "
             "metrics_settings), sample-out-of-order / sample-too-old (older than the head and the 10 m out-of-order "
             "window), label validation. The HA dedup's replicas_did_not_match is left out. Only counted when it "
             "happens, so empty is the healthy state."), 8, 6)

    # --- Series ---------------------------------------------------------------------------
    b.row("Series and limits (tenant anonymous)")
    b.add(timeseries("Active series vs limit", [
        q(f'sum by (host) (cortex_ingester_active_series{{{MH}, user="anonymous"}})', "{{host}}"),
        q(f'max(cortex_ingester_local_limits{{{M}, limit="max_global_series_per_user"}})', "limit (max_series)"),
    ], fill=0, decimals=0, min_=0, desc="Active series per ingester (all three hold every series: RF 3 on 3 ingesters) "
                                        "against the per-tenant limit as the ingesters enforce it.",
        overrides=[override("limit (max_series)", DASHED)]), 8, 8)
    b.add(timeseries("Series churn", [
        q(f"sum by (host) (rate(cortex_ingester_memory_series_created_total{{{MH}}}[$__rate_interval]))", "{{host}} created/s"),
        q(f"-sum by (host) (rate(cortex_ingester_memory_series_removed_total{{{MH}}}[$__rate_interval]))", "{{host}} removed/s"),
    ], fill=10, desc="New series per second (a new target, a relabel, a label value that changes) and series dropped at "
                     "head compaction (gone for over an hour). Big spikes after a deploy point at a label that churns."), 8, 8)
    b.add(timeseries("In-memory series and head span", [
        q(f"sum by (host) (cortex_ingester_memory_series{{{MH}}})", "{{host}} series in head"),
        q(f"max by (host) (cortex_ingester_tsdb_head_max_timestamp_seconds{{{MH}}} - "
          f"cortex_ingester_tsdb_head_min_timestamp_seconds{{{MH}}})", "{{host}} head span"),
    ], fill=0, desc="Series in each ingester's head (active ones plus those that stopped within the last 1-3 h) and the "
                    "time the head covers: it grows to 3 h and drops to 1 h at each 2 h head compaction.",
        overrides=[override(".*span.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True)]), 8, 8)

    # --- Ingester TSDB --------------------------------------------------------------------
    b.row("Ingester TSDB, WAL and blocks to S3")
    b.add(timeseries("Head chunks and samples appended", [
        q(f"sum by (host) (cortex_ingester_tsdb_head_chunks{{{MH}}})", "{{host}} head chunks"),
        q(rate("cortex_ingester_ingested_samples_total"), "{{host}} samples/s"),
        q(f"sum by (host) (rate(cortex_ingester_ingested_samples_failures_total{{{MH}}}[$__rate_interval])) > 0", "{{host}} failed/s"),
    ], fill=0, decimals=0, desc="Chunks held in each ingester's head, and samples appended per second (and appends that "
                                "failed: out of bounds, out of order, series limit).",
        overrides=[override(".*/s", {"custom.axisPlacement": "right"}, regex=True), red("failed")]), 8, 8)
    b.add(timeseries("WAL fsync and append latency", [
        q(f"sum by (host) (rate(cortex_ingester_tsdb_wal_fsync_duration_seconds_sum{{{MH}}}[$__rate_interval])) / "
          f"sum by (host) (rate(cortex_ingester_tsdb_wal_fsync_duration_seconds_count{{{MH}}}[$__rate_interval]))", "{{host}} WAL fsync (avg)"),
        q(hist(0.99, "cortex_ingester_tsdb_appender_commit_duration_seconds", MH), "{{host}} append commit p99"),
    ], unit="s", fill=0, min_=0, desc="The WAL (/var/lib/metrics/mimir/tsdb on the VM's Ceph RBD disk) is fsynced at "
                                      "segment cuts and checkpoints, so the fsync line has gaps; commit p99 is what each "
                                      "push waits for in the ingester."), 8, 8)
    b.add(timeseries("TSDB and WAL failures", [
        q(f"sum by (host) (increase(cortex_ingester_tsdb_wal_writes_failed_total{{{MH}}}[1h])) > 0", "{{host}} WAL writes failed"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_wal_corruptions_total{{{MH}}}[1h])) > 0", "{{host}} WAL corruptions"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_wal_truncations_failed_total{{{MH}}}[1h])) > 0", "{{host}} WAL truncations failed"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_checkpoint_creations_failed_total{{{MH}}}[1h])) > 0", "{{host}} checkpoints failed"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_compactions_failed_total{{{MH}}}[1h])) > 0", "{{host}} head compactions failed"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_head_truncations_failed_total{{{MH}}}[1h])) > 0", "{{host}} head truncations failed"),
        q(f"sum by (host) (increase(cortex_ingester_tsdb_mmap_chunk_corruptions_total{{{MH}}}[1h])) > 0", "{{host}} mmap chunk corruptions"),
    ], draw="bars", fill=60, decimals=0, no_value="No WAL/TSDB failures in range",
        desc="Per hour. Any of these is a disk or data problem on that ingester (the other two still hold every series)."), 8, 8)
    b.add(timeseries("Head compactions and blocks shipped", [
        q(f"sum by (host) (increase(cortex_ingester_tsdb_compactions_total{{{MH}}}[1h]))", "{{host}} head → block"),
        q(f"sum by (host) (increase(cortex_ingester_shipper_uploads_total{{{MH}}}[1h]))", "{{host}} uploaded to S3"),
        q(f"sum by (host) (increase(cortex_ingester_shipper_upload_failures_total{{{MH}}}[1h])) > 0", "{{host}} upload failed"),
    ], draw="bars", fill=60, decimals=0, desc="Per hour: each ingester cuts a 2 h block from its head every 2 h and ships "
                                              "it to the bucket (alert MimirBlockUploadFailures). The three copies (RF 3) "
                                              "are merged by the compactor.", overrides=[red("failed")]), 8, 7)
    b.add(timeseries("Since last block shipped", [
        q(f"time() - max by (host) (cortex_ingester_shipper_last_successful_upload_timestamp_seconds{{{MH}}})", "{{host}}"),
        q(f"(time() - max by (host) (cortex_ingester_oldest_unshipped_block_timestamp_seconds{{{MH}}} > 0)) or "
          f"max by (host) (cortex_ingester_oldest_unshipped_block_timestamp_seconds{{{MH}}}) * 0", "{{host}} oldest unshipped"),
    ], unit="s", fill=0, min_=0, desc="Time since each ingester's last successful upload (sawtooth up to ~2 h), and the "
                                      "age of its oldest local block not yet in S3 (0 = all shipped)."), 8, 7)
    b.add(timeseries("Out-of-order samples", [
        q(f"sum by (host) (rate(cortex_ingester_tsdb_out_of_order_samples_appended_total{{{MH}}}[$__rate_interval]))", "{{host}} appended/s"),
        q(f'sum by (reason) (rate(cortex_discarded_samples_total{{{MH}, reason=~"sample-out-of-order|sample-too-old|sample-out-of-bounds"}}[$__rate_interval]))',
          "rejected: {{reason}}"),
    ], fill=0, desc="Samples older than the head's newest that were still accepted thanks to out_of_order_time_window "
                    "(10 m: a replica failover resends a little older data), and those rejected for being too old. "
                    "History backfills don't go through here: they are uploaded as blocks (Compactor row).",
        overrides=[red("rejected")]), 8, 7)

    # --- Compactor ------------------------------------------------------------------------
    b.row("Compactor, retention and backfill uploads")
    b.add(table("Compactor per VM", [
        q(f"max by (host) (time() - cortex_compactor_last_successful_run_timestamp_seconds{{{MH}}})", table=True),
        q(f"max by (host) (time() - cortex_compactor_block_cleanup_last_successful_run_timestamp_seconds{{{MH}}})", table=True),
        q(f"sum by (host) (increase(cortex_compactor_runs_completed_total{{{MH}}}[$__range]))", table=True),
        q(f"sum by (host) (increase(cortex_compactor_runs_failed_total{{{MH}}}[$__range]))", table=True),
        q(f"sum by (host) (increase(cortex_compactor_group_compactions_total{{{MH}}}[$__range]))", table=True),
        q(f"sum by (host) (increase(cortex_compactor_group_compactions_failures_total{{{MH}}}[$__range]))", table=True),
    ], desc="Each Mimir runs a compactor that owns a share of the jobs (compactor ring), hourly. Last run / Last cleanup: "
            "since its last successful compaction pass and bucket cleanup (deletes blocks marked for deletion, applies "
            "the 396 d retention, rewrites the bucket index). Counts are over the time range.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "VM", "Value #A": "Last run", "Value #B": "Last cleanup", "Value #C": "Runs",
            "Value #D": "Runs failed", "Value #E": "Compactions", "Value #F": "Compactions failed"},
            order=["VM", "Last run", "Last cleanup", "Runs", "Runs failed", "Compactions", "Compactions failed"])],
        overrides=[override("Last run", {"unit": "dtdurations", "thresholds": steps(("green", None), ("orange", 7200), ("red", 86400))}),
                   cell("Last run", "color-text"),
                   override("Last cleanup", {"unit": "dtdurations", "thresholds": steps(("green", None), ("orange", 7200), ("red", 86400))}),
                   cell("Last cleanup", "color-text"),
                   override("Runs failed", {"thresholds": RED_IF_ANY, "decimals": 0}), cell("Runs failed", "color-text"),
                   override("Compactions failed", {"thresholds": RED_IF_ANY, "decimals": 0}), cell("Compactions failed", "color-text"),
                   override("Runs", {"decimals": 0}), override("Compactions", {"decimals": 0})],
        sort="VM"), 8, 6)
    b.add(timeseries("Blocks compacted and deleted", [
        q(f"sum(increase(cortex_compactor_group_compactions_total{{{MH}}}[1h]))", "compactions"),
        q(f"sum by (reason) (increase(cortex_compactor_blocks_marked_for_deletion_total{{{MH}}}[1h]))", "marked for deletion: {{reason}}"),
        q(f"sum(increase(cortex_compactor_blocks_cleaned_total{{{MH}}}[1h]))", "deleted from S3"),
        q(f"sum by (reason) (increase(cortex_compactor_blocks_marked_for_no_compaction_total{{{MH}}}[1h])) > 0", "no-compact: {{reason}}"),
    ], draw="bars", fill=60, decimals=0, desc="Per hour, all compactors. Compaction merges the three ingesters' copies "
                                              "and smaller blocks (2 h → 12 h → 24 h); the sources are marked and deleted "
                                              "~12 h later. retention: past 396 d. no-compact: a block the compactor "
                                              "gave up on (look at the logs).", overrides=[red("no-compact")]), 8, 6)
    b.add(timeseries("Blocks in the bucket", [
        q(f'max by (state) (cortex_compactor_meta_blocks_synced{{{M}, state=~"loaded|marked-for-deletion|failed|corrupted-meta-json|marked-for-no-compact"}}) > 0',
          "{{state}}")],
        fill=0, decimals=0, desc="Blocks the compactor sees in the bucket (largest view of the three): loaded = live "
                                 "blocks, marked-for-deletion = waiting for cleanup. failed / corrupted = broken meta.json.",
        overrides=[red("failed|corrupted")]), 8, 6)
    b.add(timeseries("Block uploads (backfill)", [
        q(f"sum(increase(cortex_block_upload_api_blocks_total{{{MH}}}[1h]))", "blocks uploaded / h"),
        q(f'sum by (status_code) (increase(cortex_request_duration_seconds_count{{{MH}, route="api_v1_upload_block_block_finish"}}[1h]))',
          "finished ({{status_code}}) / h"),
        q(f'sum by (status_code) (increase(cortex_request_duration_seconds_count{{{MH}, route=~"api_v1_upload_block_.*", status_code!~"2.."}}[1h]))',
          "failed requests ({{status_code}}) / h"),
        q(f"sum(cortex_block_upload_validations_in_progress{{{MH}}})", "validations running"),
    ], draw="bars", fill=60, decimals=0, no_value="No block uploads in range",
        desc="History uploaded as whole blocks with `mimirtool backfill` (compactor_block_upload_enabled): the InfluxDB "
             "history of the WLC and Proxmox series. Each block is started, its files sent, then validated by the "
             "compactor and added to the bucket. Flat at 0 while no backfill runs.", overrides=[red("failed")]), 8, 6)
    b.add(timeseries("Backfill bytes and validation time", [
        q(f"sum(increase(cortex_block_upload_api_bytes_total{{{MH}}}[1h]))", "bytes uploaded / h"),
        q(f"histogram_quantile(0.99, sum by (le) (rate(cortex_compactor_block_upload_duration_seconds_bucket{{{MH}}}[1h])))",
          "validation p99"),
    ], fill=10, no_value="No block uploads in range", desc="Bytes received by the block-upload API per hour and how long "
                                                            "the compactor took to validate an uploaded block.",
        overrides=[override("bytes uploaded / h", {"unit": "bytes", "custom.drawStyle": "bars", "custom.fillOpacity": 60}),
                   override("validation p99", {"unit": "s", "custom.axisPlacement": "right"})]), 8, 6)
    b.add(timeseries("Compaction job duration", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(cortex_compactor_compaction_job_duration_seconds_bucket{{{MH}}}[1h])))",
          "{{host}} p99"),
        q(f"max by (host) (rate(cortex_compactor_garbage_collection_duration_seconds_sum{{{MH}}}[1h]) / "
          f"rate(cortex_compactor_garbage_collection_duration_seconds_count{{{MH}}}[1h]))", "{{host}} GC avg"),
    ], unit="s", fill=0, min_=0, no_value="No compaction jobs in range",
        desc="How long a compaction job takes (download, merge, upload) and the compactor's garbage collection of "
             "superseded blocks."), 8, 6)

    # --- Store-gateway --------------------------------------------------------------------
    b.row("Store-gateway (blocks older than 12 h)")
    b.add(timeseries("Blocks loaded", [
        q(f'sum by (host) (cortex_bucket_store_blocks_loaded{{{MH}}})', "{{host}} blocks"),
        q(f'sum by (host) (cortex_bucket_store_blocks_loaded_size_bytes{{{MH}}})', "{{host}} size"),
    ], fill=0, desc="Blocks each store-gateway serves (store-gateway ring, replication factor 3: normally every gateway "
                    "loads every block; counts differ for a while after compaction) and their size. Queries reaching "
                    "back past 12 h read these.",
        overrides=[override(".*size", {"unit": "bytes", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Block loads and sync", [
        q(f"sum by (host) (increase(cortex_bucket_store_block_loads_total{{{MH}}}[1h]))", "{{host}} loads / h"),
        q(f"sum by (host) (increase(cortex_bucket_store_block_load_failures_total{{{MH}}}[1h])) > 0", "{{host}} load failures / h"),
        q(f"sum by (host) (increase(cortex_bucket_store_block_drops_total{{{MH}}}[1h]))", "{{host}} drops / h"),
        q(f"time() - max by (host) (cortex_bucket_stores_blocks_last_successful_sync_timestamp_seconds{{{MH}}})", "{{host}} since last sync"),
    ], fill=0, decimals=0, desc="Blocks loaded/dropped as the compactor replaces them, and time since each store-gateway "
                                "last synced the bucket index (every 15 min).",
        overrides=[red("failures"), override(".*since.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Store-gateway Series latency", [
        q(hist(0.99, "cortex_request_duration_seconds", f'{MH}, route="/gatewaypb.StoreGateway/Series"'), "{{host}} p99"),
        q(hist(0.5, "cortex_request_duration_seconds", f'{MH}, route="/gatewaypb.StoreGateway/Series"'), "{{host}} p50"),
    ], unit="s", fill=0, min_=0, no_value="No long-range queries in range",
        desc="Series requests from the queriers (only for queries reaching back past 12 h)."), 8, 7)

    # --- Queries --------------------------------------------------------------------------
    b.row("Queries (query-frontend, scheduler, querier)")
    qr = 'route=~"prometheus_api_v1_(query|query_range|series|labels|label_name_values|query_exemplars)"'
    b.add(timeseries("Queries per second by route", [
        q(f"sum by (route) (rate(cortex_request_duration_seconds_count{{{MH}, {qr}}}[$__rate_interval]))", "{{route}}")],
        unit="reqps", fill=30, stack=True,
        desc="Grafana's (and lylat-obs') requests through the query-frontend, by API route. Nothing queries Mimir "
             "unless a dashboard is open (alerting runs on the Prometheus replicas)."), 8, 8)
    b.add(timeseries("Query latency", [
        q(hist(0.99, "cortex_request_duration_seconds", f'{MH}, route=~"prometheus_api_v1_query(_range)?"', by="route"), "{{route}} p99"),
        q(hist(0.5, "cortex_request_duration_seconds", f'{MH}, route=~"prometheus_api_v1_query(_range)?"', by="route"), "{{route}} p50"),
    ], unit="s", fill=0, min_=0, desc="At the query-frontend: queue wait + execution by the queriers (split by day, "
                                      "sharded) + merge."), 8, 8)
    b.add(timeseries("Query errors", [
        q(f'sum by (route, status_code) (rate(cortex_request_duration_seconds_count{{{MH}, {qr}, status_code!~"2.."}}[$__rate_interval])) > 0',
          "{{route}} {{status_code}}"),
        q(f'sum by (status_code) (rate(cortex_per_tenant_request_total{{{MH}, route="querierpb.EvaluateQueryRequest", status_code!="OK"}}[$__rate_interval])) > 0',
          "querier {{status_code}}"),
        q(f"sum by (reason) (rate(cortex_querier_queries_rejected_total{{{MH}}}[$__rate_interval])) > 0", "rejected: {{reason}}"),
    ], unit="reqps", fill=0, no_value="No query errors in range",
        desc="Non-2xx answers at the frontend (4xx: bad query or limit, 5xx/429: overloaded or failed), queries that "
             "failed inside a querier (ERROR_CANCELED = Grafana gave up / the panel was closed, usually harmless) and "
             "queries refused by a per-query limit.",
        overrides=[override(".*CANCELED.*", {"color": {"mode": "fixed", "fixedColor": "text"}}, regex=True)]), 8, 8)
    b.add(timeseries("Scheduler queue", [
        q(f"sum by (host) (cortex_query_scheduler_queue_length{{{MH}}})", "{{host}} queued"),
        q(hist(0.99, "cortex_query_scheduler_queue_duration_seconds", MH), "{{host}} wait p99"),
        q(f'sum by (host) (cortex_query_scheduler_inflight_requests{{{MH}, quantile="0.99"}})', "{{host}} in flight p99"),
    ], fill=0, min_=0, desc="Queries waiting for a querier in each query-scheduler (ring discovery: every frontend "
                            "uses all three). Queue limit 800 per tenant (max_outstanding_requests_per_tenant); a long "
                            "wait means the queriers are saturated.",
        overrides=[override(".*wait.*", {"unit": "s", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Data read by queries", [
        q(rate("cortex_query_fetched_series_total"), "{{host}} series/s"),
        q(rate("cortex_query_fetched_chunk_bytes_total"), "{{host}} chunk bytes/s"),
        q(rate("cortex_query_fetched_index_bytes_total"), "{{host}} index bytes/s"),
    ], fill=0, desc="Series and bytes the queriers fetched from ingesters and store-gateways.",
        overrides=[override(".*bytes/s", {"unit": "Bps", "custom.axisPlacement": "right"}, regex=True)]), 8, 7)
    b.add(timeseries("Queries by type and ruler", [
        q(f"sum by (op) (rate(cortex_query_frontend_queries_total{{{MH}}}[$__rate_interval]))", "{{op}}"),
        q(f"sum(cortex_ruler_managers_total{{{MH}}})", "ruler rule managers"),
    ], fill=0, desc="Queries per second by kind at the frontend. The ruler runs (target all) but holds no rules: "
                    "alerting and recording rules are in Prometheus, so ruler managers stays 0.",
        overrides=[override("ruler rule managers", {"custom.axisPlacement": "right", "decimals": 0, **DASHED})]), 8, 7)

    # --- Object storage -------------------------------------------------------------------
    b.row("Object storage (Ceph RGW via haproxy)")
    b.add(timeseries("S3 operations by component", [
        q(f"sum by (component, operation) (rate(thanos_objstore_bucket_operations_total{{{OBJ}}}[$__rate_interval])) > 0",
          "{{component}} {{operation}}")],
        unit="reqps", fill=30, stack=True,
        desc="Requests to the bucket: the ingesters upload, the compactor lists/reads/uploads/deletes, store-gateways "
             "and queriers read. ruler-storage (local filesystem) is left out."), 8, 8)
    b.add(timeseries("S3 operation latency (p99)", [
        q(hist(0.99, "thanos_objstore_bucket_operation_duration_seconds", OBJ, by="component, operation"),
          "{{component}} {{operation}}")],
        unit="s", fill=0, min_=0, desc="Per component and operation, all VMs. Uploads of big compacted blocks take "
                                       "seconds; get/exists/attributes should be a few ms."), 8, 8)
    b.add(timeseries("S3 operation failures", [
        q(f"sum by (host, component, operation) (increase(thanos_objstore_bucket_operation_failures_total{{{OBJ}}}[$__rate_interval])) > 0",
          "{{host}} {{component}} {{operation}}")],
        draw="bars", fill=60, decimals=0, no_value="No S3 failures in range",
        desc="Failed bucket operations (not-found answers to exists/get don't count). Failures together with haproxy "
             "showing no RGW = the RGWs are down (alert MimirRGWBackendDown)."), 8, 8)
    b.add(state_timeline("RGWs per haproxy", [
        q(f'max by (host, server) (haproxy_server_status{{{HA}, proxy="rgw", state="UP", host=~"$host"}})', "{{host}} → {{server}}")],
        mappings=mapping(**{"1": ("UP", "green"), "0": ("DOWN", "red")}), thresholds=UP_STEPS, row_height=0.8,
        desc="haproxy on each Mimir VM (127.0.0.1:7480) health-checks the three RGWs; Mimir's S3 client reaches the "
             "bucket only through it."), 8, 7)
    b.add(timeseries("haproxy → RGW responses and latency", [
        q(f'sum by (code) (rate(haproxy_backend_http_responses_total{{{HA}, proxy="rgw", host=~"$host"}}[$__rate_interval])) > 0', "{{code}}"),
        q(f'max by (host) (haproxy_backend_response_time_average_seconds{{{HA}, proxy="rgw", host=~"$host"}})', "{{host}} avg response"),
        q(f'sum by (host) (rate(haproxy_backend_connection_errors_total{{{HA}, proxy="rgw", host=~"$host"}}[$__rate_interval]) + '
          f'rate(haproxy_backend_retry_warnings_total{{{HA}, proxy="rgw", host=~"$host"}}[$__rate_interval])) > 0', "{{host}} conn errors + retries"),
    ], fill=0, desc="HTTP answers from the RGWs per second (4xx are mostly 404s to exists checks: normal), haproxy's "
                    "average response time over its last 1024 requests, and connection errors/retries.",
        overrides=[override(".*avg response", {"unit": "s", "custom.axisPlacement": "right"}, regex=True),
                   red("5xx|errors")]), 8, 7)
    b.add(timeseries("Bucket mimir", [
        q('max(ceph_rgw_bucket_size_actual_bytes{bucket="mimir"})', "size"),
        q('max(ceph_rgw_bucket_objects{bucket="mimir"})', "objects"),
    ], fill=10, desc="The RGW bucket (Ceph RGW bucket stats via the node_exporter textfile on the PVE nodes).",
        links=[("Ceph RGW buckets", RGW_DASH + "?" + TIME)],
        overrides=[override("size", {"unit": "bytes"}),
                   override("objects", {"custom.axisPlacement": "right", "decimals": 0})]), 8, 7)

    # --- Ring -----------------------------------------------------------------------------
    b.row("Rings and memberlist")
    b.add(table("Ring members by state", [
        q(f"min by (name, state) (cortex_ring_members{{{M}}})", table=True)],
        desc="Members of every hash ring as the Mimir that sees fewest reports them (one row per ring). All three "
             "ACTIVE is healthy. Unhealthy = a member stopped heartbeating (a rebuilt VM's old entry: forget it on "
             "/ingester/ring); LEAVING/JOINING during restarts.",
        transformations=[{"id": "groupingToMatrix", "options": {"columnField": "state", "rowField": "name",
                                                               "valueField": "Value", "emptyValue": "null"}},
                         organize(rename={"name\\state": "Ring"}, order=["Ring", "ACTIVE", "JOINING", "LEAVING", "PENDING", "Unhealthy"])],
        overrides=[override("ACTIVE", {"thresholds": steps(("red", None), ("orange", 2), ("green", 3)), "decimals": 0}),
                   cell("ACTIVE", "color-background"),
                   override("Unhealthy", {"thresholds": RED_IF_ANY, "decimals": 0}), cell("Unhealthy", "color-text"),
                   override("LEAVING", {"thresholds": steps(("green", None), ("orange", 1)), "decimals": 0}), cell("LEAVING", "color-text"),
                   override("JOINING", {"thresholds": steps(("green", None), ("orange", 1)), "decimals": 0}), cell("JOINING", "color-text"),
                   override("PENDING", {"thresholds": steps(("green", None), ("orange", 1)), "decimals": 0}), cell("PENDING", "color-text")],
        sort="Ring"), 8, 8)
    b.add(timeseries("ACTIVE members per ring", [
        q(f'min by (name) (cortex_ring_members{{{M}, state="ACTIVE"}})', "{{name}}"),
        q(f'max by (name) (cortex_ring_members{{{M}, state="Unhealthy"}}) > 0', "{{name}} unhealthy")],
        fill=0, decimals=0, min_=0, step=True,
        desc="Over time: a dip is a Mimir restart (alert MimirRingMembersMissing after 10 m).", overrides=[red("unhealthy")]), 8, 8)
    b.add(timeseries("memberlist", [
        q(f"min by (host) (memberlist_client_cluster_members_count{{{MH}}})", "{{host}} members"),
        q(f"max by (host) (memberlist_client_cluster_node_health_score{{{MH}}}) > 0", "{{host}} health score (0 = good)"),
        q(f"sum by (host) (rate(memberlist_tcp_transport_packets_sent_errors_total{{{MH}}}[$__rate_interval]) + "
          f"rate(memberlist_tcp_transport_outgoing_stream_errors_total{{{MH}}}[$__rate_interval])) > 0", "{{host}} transport errors/s"),
        q(f"sum by (host) (rate(memberlist_client_cas_failure_total{{{MH}}}[$__rate_interval])) > 0", "{{host}} KV CAS failures/s"),
    ], fill=0, min_=0, desc="The gossip that carries every ring and the HA tracker state (port 7946 on the HA VLAN, "
                            "cluster label lylat-mimir). Members should be 3 everywhere; health score > 0 means the node "
                            "misses probes.", overrides=[red("errors|failures")]), 8, 8)

    # --- Process and VMs ------------------------------------------------------------------
    b.row("Process and VMs mim01-03")
    b.add(timeseries("Mimir CPU", [q(rate("process_cpu_seconds_total"), "{{host}}")],
                     unit="percentunit", fill=0, min_=0, desc="CPU of the Mimir process (1 = one core)."), 6, 7)
    b.add(timeseries("Mimir memory", [
        q(f"sum by (host) (process_resident_memory_bytes{{{MH}}})", "{{host}} RSS"),
        q(f"sum by (host) (go_memstats_heap_inuse_bytes{{{MH}}})", "{{host}} Go heap in use"),
        q(f'max by (host) (node_memory_MemTotal_bytes{{{NODE}, host=~"$host"}})', "{{host}} VM RAM"),
    ], unit="bytes", fill=0, min_=0, desc="The head (every series, RF 3) lives in memory: RSS grows with active series.",
        overrides=[override(".*VM RAM", DASHED, regex=True)]), 6, 7)
    b.add(timeseries("Goroutines and file descriptors", [
        q(f"sum by (host) (go_goroutines{{{MH}}})", "{{host}} goroutines"),
        q(f"sum by (host) (process_open_fds{{{MH}}})", "{{host}} open fds"),
    ], fill=0, decimals=0, desc="Steadily climbing goroutines = something stuck (hung S3 or gRPC calls).",
        overrides=[override(".*fds", {"custom.axisPlacement": "right"}, regex=True)]), 6, 7)
    b.add(bargauge("VM disk used (/)", [
        q(f'1 - node_filesystem_avail_bytes{{{NODE}, host=~"$host", mountpoint="/"}} / '
          f'node_filesystem_size_bytes{{{NODE}, host=~"$host", mountpoint="/"}}', "{{host}}", instant=True),
        q(f'sum by (host) (cortex_ingester_tsdb_storage_blocks_bytes{{{MH}}}) / '
          f'max by (host) (node_filesystem_size_bytes{{{NODE}, host=~"$host", mountpoint="/"}})', "{{host}} local TSDB blocks", instant=True),
    ], unit="percentunit", min_=0, max_=1, thresholds=PERCENT, mode="gradient",
        links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)],
        desc="Root filesystem (60 GB) of each VM: /var/lib/metrics/mimir holds the WAL, the last 13 h of blocks, the "
             "store-gateway's index headers and the compactor's scratch space."), 6, 7)

    # --- Logs -----------------------------------------------------------------------------
    b.row("Logs", collapsed=True)
    b.add(per_bucket("Mimir warnings and errors per VM", [
        lq(f'sum by (host) (count_over_time({{app="mimir", host=~"$host"}} |~ `{MIMIR_WARN}` [$__auto]))', "{{host}}")],
        desc="Mimir logs logfmt; Podman stores its stderr with priority err, so the real level comes from the "
             "line's level= field. Recurring: store-gateway 'failed to collect on-disk stats' for blocks it just "
             "loaded (harmless)."), 8, 8)
    b.add(per_bucket("Mimir log lines by level", [
        lq(f'sum by (lvl) (count_over_time({{app="mimir", host=~"$host"}} | regexp `level=(?P<lvl>[a-z]+)` [$__auto]))', "{{lvl}}")],
        desc="All Mimir log lines by their logfmt level."), 16, 8)
    b.add(logs("Mimir warnings and errors", f'{{app="mimir", host=~"$host"}} |~ `{MIMIR_WARN}`', max_lines=300), 24, 10)

    host = query_var("host", "Mimir VM", f"label_values(up{{{M}}}, host)")
    return dashboard("mimir", "Mimir",
                     "Mimir on mim01-03, the long-term metrics store behind both Prometheus replicas (Grafana's default "
                     "datasource): health checks mirroring the alerts, ingestion and HA dedup, series vs limits, ingester "
                     "TSDB and block shipping, compactor and backfill uploads, store-gateway, queries, S3 on Ceph RGW, "
                     "rings, processes and logs.",
                     b, tags=["databases", "mimir"], variables=[host],
                     extra_links=[DB_LINK, url_link("Monitoring stack", STACK_DASH),
                                  url_link("Mimir logs", LOGS_DASH + "?var-app=mimir")])


DASHBOARDS = {"Databases/mimir.json": mimir}
