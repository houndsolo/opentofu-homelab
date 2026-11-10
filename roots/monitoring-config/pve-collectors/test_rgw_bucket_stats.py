#!/usr/bin/env python3
"""Tests for rgw-bucket-stats.py (no Ceph needed):  python3 -I roots/monitoring-config/pve-collectors/test_rgw_bucket_stats.py"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "rgw-bucket-stats.py"

NO_QUOTA = {"enabled": False, "check_on_raw": False, "max_size": -1, "max_size_kb": 0, "max_objects": -1}
# Shaped like `radosgw-admin bucket stats` on Ceph 20.2 (trimmed).
STATS = [
    {"bucket": "mimir", "owner": "mimir", "num_shards": 11, "bucket_quota": NO_QUOTA, "usage": {
        "rgw.main": {"size": 155317938, "size_actual": 155357184, "num_objects": 13},
        "rgw.multimeta": {"size": 0, "size_actual": 0, "num_objects": 2}}},
    {"bucket": "loki", "owner": "loki", "num_shards": 11, "usage": {
        "rgw.main": {"size": 19416281, "size_actual": 41791488, "num_objects": 7069}},
        "bucket_quota": {"enabled": True, "max_size": 10737418240, "max_objects": -1}},
    {"bucket": "empty", "owner": "postgres", "num_shards": 11, "usage": {}, "bucket_quota": NO_QUOTA},
]
USERS = {
    "mimir": {"user_quota": NO_QUOTA},
    "loki": {"user_quota": NO_QUOTA},
    "postgres": {"user_quota": {"enabled": True, "max_size": 53687091200, "max_objects": 1000000}},
}


def run(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)


def samples(text):
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            series, value = line.rsplit(" ", 1)
            out[series] = float(value)
    return out


class Collector(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = pathlib.Path(self.tmp.name)
        self.out, self.stats, self.users = d / "ceph_rgw_buckets.prom", d / "stats.json", d / "users.json"
        self.stats.write_text(json.dumps(STATS))
        self.users.write_text(json.dumps(USERS))

    def tearDown(self):
        self.tmp.cleanup()

    def collect(self):
        return run("--out", str(self.out), "--stats-json", str(self.stats), "--users-json", str(self.users))

    def test_metrics(self):
        r = self.collect()
        self.assertEqual(r.returncode, 0, r.stderr)
        s = samples(self.out.read_text())
        # Usage categories are summed.
        self.assertEqual(s['ceph_rgw_bucket_size_bytes{bucket="mimir",owner="mimir"}'], 155317938)
        self.assertEqual(s['ceph_rgw_bucket_objects{bucket="mimir",owner="mimir"}'], 15)
        self.assertEqual(s['ceph_rgw_bucket_size_actual_bytes{bucket="loki",owner="loki"}'], 41791488)
        self.assertEqual(s['ceph_rgw_bucket_shards{bucket="loki",owner="loki"}'], 11)
        # A bucket without usage reports zeros, not nothing.
        self.assertEqual(s['ceph_rgw_bucket_size_bytes{bucket="empty",owner="postgres"}'], 0)
        self.assertEqual(s['ceph_rgw_bucket_objects{bucket="empty",owner="postgres"}'], 0)
        # Quotas only when enabled with a limit.
        self.assertEqual(s['ceph_rgw_bucket_quota_max_size_bytes{bucket="loki",owner="loki"}'], 10737418240)
        self.assertNotIn('ceph_rgw_bucket_quota_max_objects{bucket="loki",owner="loki"}', s)
        self.assertNotIn('ceph_rgw_bucket_quota_max_size_bytes{bucket="mimir",owner="mimir"}', s)
        self.assertEqual(s['ceph_rgw_user_quota_max_size_bytes{owner="postgres"}'], 53687091200)
        self.assertEqual(s['ceph_rgw_user_quota_max_objects{owner="postgres"}'], 1000000)
        self.assertNotIn('ceph_rgw_user_quota_max_size_bytes{owner="loki"}', s)
        self.assertEqual(s["ceph_rgw_bucket_stats_success"], 1)
        self.assertIn("ceph_rgw_bucket_stats_last_success_timestamp_seconds", s)
        # Valid exposition format: every sample's metric has HELP and TYPE lines.
        text = self.out.read_text()
        for series in s:
            name = series.split("{")[0]
            self.assertIn(f"# TYPE {name} gauge\n", text)

    def test_failure_keeps_last_success(self):
        self.assertEqual(self.collect().returncode, 0)
        before = samples(self.out.read_text())["ceph_rgw_bucket_stats_last_success_timestamp_seconds"]
        self.stats.write_text("not json")
        r = self.collect()
        self.assertEqual(r.returncode, 1)
        s = samples(self.out.read_text())
        self.assertEqual(s["ceph_rgw_bucket_stats_success"], 0)
        self.assertEqual(s["ceph_rgw_bucket_stats_last_success_timestamp_seconds"], before)
        self.assertFalse(any(k.startswith("ceph_rgw_bucket_size_bytes") for k in s))  # no stale bucket values

    def test_label_escaping(self):
        self.stats.write_text(json.dumps([{"bucket": 'a"b', "owner": "x\\y", "usage": {}}]))
        self.users.write_text("{}")
        self.assertEqual(self.collect().returncode, 0)
        self.assertIn('ceph_rgw_bucket_objects{bucket="a\\"b",owner="x\\\\y"} 0', self.out.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
