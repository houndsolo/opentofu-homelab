# Per-bucket Ceph RGW usage: alerts on the ceph_rgw_bucket_* metrics that
# roots/monitoring-config/pve-collectors/rgw-bucket-stats.py writes for node_exporter's textfile
# collector on the RGW nodes (scraped as job "node"). Several nodes report the same buckets,
# so every expression takes max by (bucket, owner). Dashboard: Storage/ceph-rgw-buckets.json
# (dashboards/rgw.py). Only with a Ceph cluster (targets.ceph).

locals {
  rgw_a    = var.rgw_bucket_alerts
  rgw_size = "max by (bucket, owner) (ceph_rgw_bucket_size_actual_bytes{job=\"node\"})"
  rgw_objs = "max by (bucket, owner) (ceph_rgw_bucket_objects{job=\"node\"})"

  rgw_rules = length(var.targets.ceph) == 0 ? [] : [{
    name = "ceph-rgw-buckets"
    rules = [
      {
        alert       = "CephRGWBucketStatsStale"
        expr        = "time() - max(ceph_rgw_bucket_stats_last_success_timestamp_seconds{job=\"node\"}) > ${local.rgw_a.stats_max_age_seconds} or absent(ceph_rgw_bucket_stats_last_success_timestamp_seconds{job=\"node\"})"
        for         = "10m"
        labels      = { severity = "warning" }
        annotations = { summary = "No RGW node has collected per-bucket usage for over ${local.rgw_a.stats_max_age_seconds / 60} minutes: rgw-bucket-stats.timer (pve-collectors) missing or failing; the bucket alerts are blind" }
      },
      {
        alert       = "CephRGWBucketFastGrowth"
        expr        = "max by (bucket, owner) (delta(ceph_rgw_bucket_size_actual_bytes{job=\"node\"}[1h])) > ${local.rgw_a.growth_1h_bytes}"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "RGW bucket {{ $labels.bucket }} ({{ $labels.owner }}) grew by {{ $value | humanize1024 }}B in the last hour" }
      },
      {
        alert       = "CephRGWBucketGrowth24h"
        expr        = "max by (bucket, owner) (delta(ceph_rgw_bucket_size_actual_bytes{job=\"node\"}[24h])) > ${local.rgw_a.growth_24h_bytes}"
        for         = "1h"
        labels      = { severity = "warning" }
        annotations = { summary = "RGW bucket {{ $labels.bucket }} ({{ $labels.owner }}) grew by {{ $value | humanize1024 }}B in 24 hours" }
      },
      {
        # Quotas are checked against the allocated size (size_actual), like RGW does.
        alert = "CephRGWBucketNearQuota"
        expr = join(" or ", [
          "${local.rgw_size} / max by (bucket, owner) (ceph_rgw_bucket_quota_max_size_bytes{job=\"node\"}) > ${local.rgw_a.quota_ratio}",
          "${local.rgw_objs} / max by (bucket, owner) (ceph_rgw_bucket_quota_max_objects{job=\"node\"}) > ${local.rgw_a.quota_ratio}",
        ])
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "RGW bucket {{ $labels.bucket }} ({{ $labels.owner }}) is at {{ $value | humanizePercentage }} of its bucket quota: writes fail when it is full" }
      },
      {
        alert = "CephRGWUserNearQuota"
        expr = join(" or ", [
          "sum by (owner) (${local.rgw_size}) / max by (owner) (ceph_rgw_user_quota_max_size_bytes{job=\"node\"}) > ${local.rgw_a.quota_ratio}",
          "sum by (owner) (${local.rgw_objs}) / max by (owner) (ceph_rgw_user_quota_max_objects{job=\"node\"}) > ${local.rgw_a.quota_ratio}",
        ])
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "RGW user {{ $labels.owner }}'s buckets are at {{ $value | humanizePercentage }} of the user quota: writes fail when it is full" }
      },
      {
        alert       = "CephRGWBucketQuotaFullSoon"
        expr        = "predict_linear(${local.rgw_size}[24h:10m], ${local.rgw_a.quota_horizon_days * 86400}) > max by (bucket, owner) (ceph_rgw_bucket_quota_max_size_bytes{job=\"node\"})"
        for         = "1h"
        labels      = { severity = "warning" }
        annotations = { summary = "RGW bucket {{ $labels.bucket }} ({{ $labels.owner }}) will reach its size quota within ${local.rgw_a.quota_horizon_days} days at the last 24 hours' rate" }
      },
    ]
  }]
}
