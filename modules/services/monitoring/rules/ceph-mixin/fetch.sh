#!/usr/bin/env bash
# Re-fetches prometheus_alerts.yml (the ceph-mixin's rendered alert rules, loaded on every
# Prometheus backend as rules/ceph.yml by ../../main.tf) from the pinned ceph/ceph commit.
#
# Keep COMMIT the same as CEPH_MIXIN_COMMIT in ../../dashboards/update.py (the ceph-mixin
# dashboards' Firing Alerts / Alerts panels look for these alert names). To bump: change
# both, run this with --update, then dashboards/update.py, and check the plan.
#
#   ./fetch.sh            check that the vendored file matches the pinned commit
#   ./fetch.sh --update   overwrite it with the pinned commit's file
set -euo pipefail

COMMIT=804c592824f88ea7e06a9b84a82be359b8dec325 # tentacle (Ceph 20.2), 2026-09-30
URL="https://raw.githubusercontent.com/ceph/ceph/${COMMIT}/monitoring/ceph-mixin/prometheus_alerts.yml"
here=$(cd "$(dirname "$0")" && pwd)
file="$here/prometheus_alerts.yml"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL --max-time 60 -o "$tmp" "$URL"

if [ "${1:-}" = "--update" ]; then
  install -m 0644 "$tmp" "$file"
  echo "updated $file from ${COMMIT:0:12} (sha256 $(sha256sum "$file" | cut -d' ' -f1))"
elif cmp -s "$tmp" "$file"; then
  echo "$file matches ceph@${COMMIT:0:12}"
else
  echo "$file differs from ceph@${COMMIT:0:12} (run with --update to replace it)" >&2
  exit 1
fi
