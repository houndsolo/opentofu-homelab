#!/bin/bash
# Run as root on a PVE node from this folder's files:
#   scp rgw-bucket-stats.py rgw-bucket-stats.service rgw-bucket-stats.timer rgw-install.sh root@<node>:/root/ &&
#   ssh root@<node> bash /root/rgw-install.sh
# Needs radosgw-admin with the cluster's admin keyring (every node of the lylat PVE cluster
# has both) and Debian's prometheus-node-exporter (textfile dir /var/lib/prometheus/node-exporter).
set -euo pipefail
cd "$(dirname "$0")"
command -v radosgw-admin >/dev/null || { echo "radosgw-admin not found" >&2; exit 1; }
[ -d /var/lib/prometheus/node-exporter ] || { echo "no node_exporter textfile dir" >&2; exit 1; }
install -m 0755 rgw-bucket-stats.py /usr/local/sbin/rgw-bucket-stats
install -m 0644 rgw-bucket-stats.service rgw-bucket-stats.timer /etc/systemd/system/
systemctl daemon-reload
systemctl start rgw-bucket-stats.service          # fails the install if a collection fails
systemctl enable --now rgw-bucket-stats.timer
grep -c '^ceph_rgw_bucket_objects{' /var/lib/prometheus/node-exporter/ceph_rgw_buckets.prom
rm -f rgw-bucket-stats.py rgw-bucket-stats.service rgw-bucket-stats.timer rgw-install.sh
