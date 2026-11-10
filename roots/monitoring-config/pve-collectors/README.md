# PVE-node collectors (installed by hand, not by OpenTofu)

OpenTofu doesn't manage files on the Proxmox nodes (like [log-senders](../log-senders/README.md)),
so these are copied and installed with a script. Prometheus picks their output up through the
node's own node_exporter (Debian `prometheus-node-exporter`, job `node`, role `proxmox`), whose
textfile collector reads `/var/lib/prometheus/node-exporter/*.prom`.

## rgw-bucket-stats: per-bucket Ceph RGW usage

[`rgw-bucket-stats.py`](rgw-bucket-stats.py) runs `radosgw-admin bucket stats` (plus
`user info` for each bucket owner, for user quotas) every 5 minutes
([`rgw-bucket-stats.timer`](rgw-bucket-stats.timer)) and writes
`ceph_rgw_buckets.prom` atomically:

| Metric | Labels | |
|---|---|---|
| `ceph_rgw_bucket_size_bytes` | bucket, owner | logical size (all usage categories) |
| `ceph_rgw_bucket_size_actual_bytes` | bucket, owner | allocated size, what quotas count (before replication) |
| `ceph_rgw_bucket_objects` | bucket, owner | objects |
| `ceph_rgw_bucket_shards` | bucket, owner | bucket index shards |
| `ceph_rgw_bucket_quota_max_size_bytes` / `_max_objects` | bucket, owner | only when the bucket quota is enabled with that limit |
| `ceph_rgw_user_quota_max_size_bytes` / `_max_objects` | owner | only when the user quota is enabled with that limit |
| `ceph_rgw_bucket_stats_success`, `_last_run_timestamp_seconds`, `_last_success_timestamp_seconds`, `_duration_seconds` | | the collector itself |

A failed run writes only the collector metrics (success 0, the previous success time), so no
stale bucket values are reported. It runs on the three RGW nodes (macbeth, titania, venom) for
redundancy; each reports the same buckets with its own `host` label, so the dashboard and the
alerts take `max by (bucket, owner)`. Any node of the lylat cluster works: all have
`radosgw-admin` and the admin keyring (`/etc/pve/priv`). One run takes about 1.5 s.

Dashboard: **Storage → Ceph RGW buckets** (`dashboards/rgw.py`). Alerts (module `rgw.tf`,
thresholds in `rgw_bucket_alerts`): `CephRGWBucketStatsStale` (no successful collection for
30 min: fires until this is installed), `CephRGWBucketFastGrowth` (10 GiB in 1 h),
`CephRGWBucketGrowth24h` (100 GiB in 24 h), `CephRGWBucketNearQuota` / `CephRGWUserNearQuota`
(85 %), `CephRGWBucketQuotaFullSoon` (24 h trend reaches the size quota within 7 days).

Install or update (idempotent; it runs one collection and fails if that fails):

```sh
cd roots/monitoring-config/pve-collectors
for ip in 10.20.7.12 10.20.7.13 10.20.7.17; do   # macbeth titania venom
  scp rgw-bucket-stats.py rgw-bucket-stats.service rgw-bucket-stats.timer rgw-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/rgw-install.sh
done
```

Check: `ssh root@10.20.7.12 'systemctl list-timers rgw-bucket-stats.timer; cat /var/lib/prometheus/node-exporter/ceph_rgw_buckets.prom'`.
Remove: `systemctl disable --now rgw-bucket-stats.timer; rm /etc/systemd/system/rgw-bucket-stats.{service,timer} /usr/local/sbin/rgw-bucket-stats /var/lib/prometheus/node-exporter/ceph_rgw_buckets.prom`.

Tests (no Ceph needed): `python3 -I roots/monitoring-config/pve-collectors/test_rgw_bucket_stats.py`.
