#!/usr/bin/python3 -I
"""Per-bucket Ceph RGW usage for node_exporter's textfile collector.

Runs `radosgw-admin bucket stats` (and `user info` for owners with a user quota) and
writes ceph_rgw_bucket_* / ceph_rgw_user_quota_* / ceph_rgw_bucket_stats_* metrics to
/var/lib/prometheus/node-exporter/ceph_rgw_buckets.prom (atomically). Installed on the
RGW nodes by install.sh with a systemd timer (README.md); Prometheus scrapes it with the
node's node_exporter (job "node", role "proxmox"), so every series also carries the
node's host label: dashboards and alerts take max by (bucket, owner).

    rgw-bucket-stats.py [--out FILE] [--stats-json FILE --users-json FILE]   (the last two: tests)
Python standard library only (PVE's python3).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

OUT = "/var/lib/prometheus/node-exporter/ceph_rgw_buckets.prom"
TIMEOUT = 60

HELP = {
    "ceph_rgw_bucket_size_bytes": "Logical size of the bucket's objects (radosgw-admin bucket stats, all usage categories).",
    "ceph_rgw_bucket_size_actual_bytes": "Space the bucket's objects take, rounded up to the allocation unit (before replication).",
    "ceph_rgw_bucket_objects": "Number of objects in the bucket.",
    "ceph_rgw_bucket_shards": "Number of bucket index shards.",
    "ceph_rgw_bucket_quota_max_size_bytes": "Bucket quota: maximum size (only when the quota is enabled with a size limit).",
    "ceph_rgw_bucket_quota_max_objects": "Bucket quota: maximum number of objects (only when enabled with an object limit).",
    "ceph_rgw_user_quota_max_size_bytes": "User quota of the bucket owner: maximum size over all their buckets (only when enabled).",
    "ceph_rgw_user_quota_max_objects": "User quota of the bucket owner: maximum objects over all their buckets (only when enabled).",
    "ceph_rgw_bucket_stats_success": "1 if the last collection succeeded, 0 if not.",
    "ceph_rgw_bucket_stats_last_run_timestamp_seconds": "When the collector last ran.",
    "ceph_rgw_bucket_stats_last_success_timestamp_seconds": "When the collector last succeeded.",
    "ceph_rgw_bucket_stats_duration_seconds": "How long the last collection took.",
}


def esc(v):
    return str(v).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def admin(*args):
    r = subprocess.run(["radosgw-admin", *args], capture_output=True, text=True, timeout=TIMEOUT, check=True)
    return json.loads(r.stdout)


def quota(q):
    """(max_size_bytes or None, max_objects or None) for an enabled quota with limits."""
    if not q or not q.get("enabled"):
        return None, None
    size, objects = q.get("max_size", -1), q.get("max_objects", -1)
    return (size if size and size > 0 else None), (objects if objects and objects > 0 else None)


def collect(stats, users):
    """stats: bucket stats list; users: {uid: user info}. Returns {metric: [(labels, value)]}."""
    m = {k: [] for k in HELP}
    for b in sorted(stats, key=lambda b: b["bucket"]):
        labels = {"bucket": b["bucket"], "owner": b.get("owner", "")}
        usage = (b.get("usage") or {}).values()
        m["ceph_rgw_bucket_size_bytes"].append((labels, sum(u.get("size", 0) for u in usage)))
        m["ceph_rgw_bucket_size_actual_bytes"].append((labels, sum(u.get("size_actual", 0) for u in usage)))
        m["ceph_rgw_bucket_objects"].append((labels, sum(u.get("num_objects", 0) for u in usage)))
        if b.get("num_shards") is not None:
            m["ceph_rgw_bucket_shards"].append((labels, b["num_shards"]))
        size, objects = quota(b.get("bucket_quota"))
        if size:
            m["ceph_rgw_bucket_quota_max_size_bytes"].append((labels, size))
        if objects:
            m["ceph_rgw_bucket_quota_max_objects"].append((labels, objects))
    for uid in sorted(users):
        size, objects = quota(users[uid].get("user_quota"))
        if size:
            m["ceph_rgw_user_quota_max_size_bytes"].append(({"owner": uid}, size))
        if objects:
            m["ceph_rgw_user_quota_max_objects"].append(({"owner": uid}, objects))
    return m


def render(m):
    lines = []
    for name, samples in m.items():
        if not samples:
            continue
        lines += [f"# HELP {name} {HELP[name]}", f"# TYPE {name} gauge"]
        for labels, value in samples:
            ls = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
            series = f"{name}{{{ls}}}" if ls else name
            lines.append(f"{series} {value:g}" if isinstance(value, float) else f"{series} {value}")
    return "\n".join(lines) + "\n"


def previous_success(path):
    try:
        with open(path) as f:
            for line in f:
                hit = re.match(r"ceph_rgw_bucket_stats_last_success_timestamp_seconds \S+$", line)
                if hit:
                    return float(line.split()[1])
    except (OSError, ValueError):
        pass
    return None


def write(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".ceph_rgw_buckets.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--stats-json", help="read bucket stats from this file instead of radosgw-admin (tests)")
    ap.add_argument("--users-json", help="read {uid: user info} from this file (tests)")
    a = ap.parse_args()

    start = time.time()
    ok, m, err = True, {k: [] for k in HELP}, None
    try:
        if a.stats_json:
            with open(a.stats_json) as f:
                stats = json.load(f)
            users = {}
            if a.users_json:
                with open(a.users_json) as f:
                    users = json.load(f)
        else:
            stats = admin("bucket", "stats")
            users = {uid: admin("user", "info", f"--uid={uid}") for uid in sorted({b.get("owner", "") for b in stats} - {""})}
        m = collect(stats, users)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as e:
        ok, err = False, e
    end = time.time()
    last_ok = end if ok else previous_success(a.out)
    status = {
        "ceph_rgw_bucket_stats_success": [({}, 1 if ok else 0)],
        "ceph_rgw_bucket_stats_last_run_timestamp_seconds": [({}, round(end))],
        "ceph_rgw_bucket_stats_duration_seconds": [({}, round(end - start, 3))],
        "ceph_rgw_bucket_stats_last_success_timestamp_seconds": [({}, round(last_ok))] if last_ok else [],
    }
    m.update(status)
    write(a.out, render(m))
    if not ok:
        print(f"rgw-bucket-stats: {err}", file=sys.stderr)
        return 1
    print(f"rgw-bucket-stats: {len(m['ceph_rgw_bucket_objects'])} buckets in {end - start:.2f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
