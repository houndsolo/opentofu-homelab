"""Ceph RGW buckets dashboard (Prometheus), built by custom.py (imported there).

The metrics come from roots/monitoring-config/pve-collectors/rgw-bucket-stats.py, a
systemd timer on the RGW nodes that writes `radosgw-admin bucket stats` into
node_exporter's textfile collector (job "node"). Several nodes report the same
buckets, so every query takes max by (bucket, owner). Alerts: modules/services/monitoring/rgw.tf.
"""
from custom import (BLUE, CEPH_LINK, MERGE, Board, bargauge, cell, dashboard, organize,
                    override, q, query_var, stat, state_timeline, steps, table, timeseries, mapping)

SEL = 'job="node", bucket=~"$bucket"'
AGE = steps(("green", None), ("orange", 900), ("red", 1800))  # the timer runs every 5 min; alert at 30 min
QUOTA = steps(("green", None), ("orange", 0.85), ("red", 0.95))
NO_STATS = "No data: rgw-bucket-stats isn't installed on an RGW node yet (pve-collectors)"
NO_QUOTA = "No bucket or user quota is set"


def per_bucket(metric, sel=SEL):
    return f"max by (bucket, owner) ({metric}{{{sel}}})"


SIZE = per_bucket("ceph_rgw_bucket_size_bytes")
ACTUAL = per_bucket("ceph_rgw_bucket_size_actual_bytes")
OBJECTS = per_bucket("ceph_rgw_bucket_objects")
SHARDS = per_bucket("ceph_rgw_bucket_shards")
QUOTA_SIZE = per_bucket("ceph_rgw_bucket_quota_max_size_bytes")
QUOTA_OBJECTS = per_bucket("ceph_rgw_bucket_quota_max_objects")
ALL_ACTUAL = per_bucket("ceph_rgw_bucket_size_actual_bytes", 'job="node"')  # every bucket (user quotas)


def growth(window):
    return f'max by (bucket, owner) (delta(ceph_rgw_bucket_size_actual_bytes{{{SEL}}}[{window}]))'


def buckets():
    b = Board()
    b.row("Buckets")
    b.add(stat("Buckets", [q(f"count({OBJECTS})")], thresholds=BLUE, no_value=NO_STATS), 3, 4)
    b.add(stat("Stored", [q(f"sum({SIZE})")], unit="bytes", thresholds=BLUE,
               desc="Logical size of all objects (before replication)."), 3, 4)
    b.add(stat("Allocated", [q(f"sum({ACTUAL})")], unit="bytes", thresholds=BLUE,
               desc="Size rounded up to the allocation unit (what quotas count), before replication: "
                    "the RGW data pool stores it 3x."), 3, 4)
    b.add(stat("Objects", [q(f"sum({OBJECTS})")], decimals=0, thresholds=BLUE), 3, 4)
    b.add(stat("Growth, 24 h", [q(f"sum({growth('24h')})")], unit="bytes", color_mode="value", graph=True,
               thresholds=BLUE), 3, 4)
    b.add(stat("Quotas set", [q(f"count({QUOTA_SIZE} or {QUOTA_OBJECTS}) or vector(0)", "bucket"),
                              q('count(max by (owner) (ceph_rgw_user_quota_max_size_bytes{job="node"} '
                                'or ceph_rgw_user_quota_max_objects{job="node"})) or vector(0)', "user")],
               text_mode="value_and_name", color_mode="value", thresholds=BLUE, decimals=0), 3, 4)
    b.add(stat("Collected", [q('time() - max(ceph_rgw_bucket_stats_last_success_timestamp_seconds{job="node"})', "ago"),
                             q('count(ceph_rgw_bucket_stats_success{job="node"} == 1) or vector(0)', "nodes ok")],
               text_mode="value_and_name", thresholds=AGE, no_value=NO_STATS,
               overrides=[override("ago", {"unit": "s"}),
                          override("nodes ok", {"decimals": 0, "thresholds": steps(("red", None), ("green", 1))})],
               desc="Age of the newest successful collection, and how many RGW nodes collected successfully last time."),
          6, 4)

    b.add(table("Buckets", [
        q(SIZE, table=True), q(ACTUAL, table=True), q(OBJECTS, table=True),
        q(f"{SIZE} / ({OBJECTS} > 0)", table=True), q(SHARDS, table=True),
        q(f"{OBJECTS} / {SHARDS}", table=True),
        q(f"{growth('24h')}", table=True), q(f"{growth('7d')}", table=True),
        q(QUOTA_SIZE, table=True), q(f"{ACTUAL} / {QUOTA_SIZE}", table=True), q(QUOTA_OBJECTS, table=True),
    ], desc="One row per bucket (instant values). The Quota, Quota used and Object quota columns appear only "
             "once a bucket quota is set.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "bucket": "Bucket", "owner": "Owner", "Value #A": "Stored", "Value #B": "Allocated", "Value #C": "Objects",
            "Value #D": "Avg object", "Value #E": "Shards", "Value #F": "Objects / shard", "Value #G": "Growth 24 h",
            "Value #H": "Growth 7 d", "Value #I": "Quota", "Value #J": "Quota used", "Value #K": "Object quota"},
            order=["Bucket", "Owner", "Stored", "Allocated", "Objects", "Avg object", "Shards", "Objects / shard",
                   "Growth 24 h", "Growth 7 d", "Quota", "Quota used", "Object quota"])],
        overrides=[override(n, {"unit": "bytes"}) for n in ("Stored", "Allocated", "Avg object", "Growth 24 h",
                                                           "Growth 7 d", "Quota")]
        + [override(n, {"decimals": 0}) for n in ("Objects", "Shards", "Objects / shard", "Object quota")]
        + [override("Quota used", {"unit": "percentunit", "min": 0, "max": 1, "thresholds": QUOTA}),
           cell("Quota used", "gauge", mode="basic")],
        sort="Allocated", desc_sort=True), 24, 7)

    b.row("Over time")
    b.add(timeseries("Allocated per bucket", [q(ACTUAL, "{{bucket}}")], unit="bytes", fill=10,
                     calcs=("min", "max", "lastNotNull"), placement="right",
                     desc="Allocated size per bucket (what quotas count), before replication."), 12, 9)
    b.add(timeseries("Objects per bucket", [q(OBJECTS, "{{bucket}}")], decimals=0, fill=10,
                     calcs=("min", "max", "lastNotNull"), placement="right"), 12, 9)
    b.add(timeseries("Growth rate (6 h trend, per day)", [
        q(f'max by (bucket, owner) (deriv(ceph_rgw_bucket_size_actual_bytes{{{SEL}}}[6h])) * 86400', "{{bucket}}")],
        unit="bytes", fill=0, line=2, calcs=("mean", "max", "lastNotNull"), placement="right",
        desc="Linear trend of the allocated size over the last 6 hours, as bytes per day. Negative: "
             "retention deleting more than is written (Loki/Mimir compaction, pgBackRest expiry)."), 12, 9)
    b.add(timeseries("Change per hour", [q(growth("1h"), "{{bucket}}")], unit="bytes", draw="bars", fill=60,
                     calcs=("sum", "max"), placement="right",
                     desc="Allocated size now minus an hour ago. Alert CephRGWBucketFastGrowth at 10 GiB/h by default."),
          12, 9)

    b.row("Quotas")
    b.add(bargauge("Bucket quota used (size)", [q(f"{ACTUAL} / {QUOTA_SIZE}", "{{bucket}}")], unit="percentunit",
                   min_=0, max_=1, thresholds=QUOTA, mode="gradient", no_value=NO_QUOTA), 8, 6)
    b.add(bargauge("Bucket quota used (objects)", [q(f"{OBJECTS} / {QUOTA_OBJECTS}", "{{bucket}}")],
                   unit="percentunit", min_=0, max_=1, thresholds=QUOTA, mode="gradient", no_value=NO_QUOTA), 8, 6)
    b.add(bargauge("User quota used (size)", [
        q(f"sum by (owner) ({ALL_ACTUAL}) / max by (owner) (ceph_rgw_user_quota_max_size_bytes{{job=\"node\"}})",
          "{{owner}}")],
        unit="percentunit", min_=0, max_=1, thresholds=QUOTA, mode="gradient", no_value=NO_QUOTA,
        desc="All of the user's buckets against the user quota."), 8, 6)

    b.row("Collector", collapsed=True)
    b.add(state_timeline("Collection result per node", [q('ceph_rgw_bucket_stats_success{job="node"}', "{{host}}")],
                         mappings=mapping(**{"0": ("FAILED", "red"), "1": ("OK", "green")}),
                         thresholds=steps(("red", None), ("green", 1))), 12, 6)
    b.add(timeseries("Collection duration", [q('ceph_rgw_bucket_stats_duration_seconds{job="node"}', "{{host}}")],
                     unit="s", fill=10, calcs=("mean", "max")), 12, 6)

    bucket_var = query_var("bucket", "Bucket", 'label_values(ceph_rgw_bucket_objects{job="node"}, bucket)')
    return dashboard("ceph-rgw-buckets", "Ceph RGW buckets",
                     "Per-bucket Ceph RGW (S3) usage: size, objects, growth and quotas (radosgw-admin bucket stats "
                     "via node_exporter's textfile collector on the RGW nodes).",
                     b, tags=["ceph", "storage", "rgw"], variables=[bucket_var], time_from="now-7d",
                     extra_links=[CEPH_LINK])


DASHBOARDS = {"Storage/ceph-rgw-buckets.json": buckets}
