# Per-bucket Ceph RGW alerts (module rgw.tf; metrics from pve-collectors/rgw-bucket-stats.py).

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockmockmockmockmockmockmockmock" }
  }
}

# keepalived's PASS password is at most 8 characters (the shared mock result is longer).
override_resource {
  target = random_password.grafana_vrrp
  values = { result = "mockvrrp" }
}

override_resource {
  target = random_password.backend_vrrp
  values = { result = "monvrrp1" }
}

override_resource {
  target = random_password.mimir_vrrp
  values = { result = "mimirvrp" }
}

override_resource {
  target = random_password.pg_vrrp
  values = { result = "pgvrrp01" }
}

# influxdb.tf: the retired InfluxDBs' providers, only there to drop their objects from the state.
mock_provider "influxdb" {}

mock_provider "influxdb" {
  alias = "replica"
}

mock_provider "proxmox" {}

mock_provider "proxmox" {
  alias = "greatfox"
}

variables {
  ssh_private_key_path = "/dev/null"
  pve_api_token        = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  greatfox_api_token   = "mock@pve!mock=00000000-0000-0000-0000-000000000000"
  postgres_settings    = {} # the default; postgres.auto.tfvars (the live cutover) would leak in
  loki_s3              = { bucket = "loki", access_key = "MOCKACCESSKEY", secret_key = "mocksecretkeymocksecretkey" }
  mimir_s3             = { bucket = "mimir", access_key = "MOCKMIMIRKEY", secret_key = "mockmimirsecretmockmimirsecret" }
  postgres_s3          = { bucket = "postgres", access_key = "MOCKPGKEY", secret_key = "mockpgsecretmockpgsecret" }
}

run "rgw_bucket_rules" {
  command = plan

  assert {
    condition = (
      length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "ceph-rgw-buckets"]) == 1 &&
      toset(keys(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"]))) == toset([
        "CephRGWBucketStatsStale", "CephRGWBucketFastGrowth", "CephRGWBucketGrowth24h",
        "CephRGWBucketNearQuota", "CephRGWUserNearQuota", "CephRGWBucketQuotaFullSoon",
      ])
    )
    error_message = "With a Ceph cluster, the ceph-rgw-buckets group has the six bucket alerts."
  }

  assert {
    # Defaults: 10 GiB/h, 100 GiB/24h, 85 % of a quota, full within 7 days, stale after 30 min.
    condition = (
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketFastGrowth"], "[1h])) > 10737418240") &&
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketGrowth24h"], "[24h])) > 107374182400") &&
      strcontains(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketNearQuota"], "ceph_rgw_bucket_quota_max_size_bytes{job=\"node\"}) > 0.85 or ") &&
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWUserNearQuota"], "ceph_rgw_user_quota_max_objects{job=\"node\"}) > 0.85") &&
      strcontains(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketQuotaFullSoon"], "[24h:10m], 604800) > ") &&
      startswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketStatsStale"], "time() - max(ceph_rgw_bucket_stats_last_success_timestamp_seconds{job=\"node\"}) > 1800 or absent(")
    )
    error_message = "The RGW bucket alerts use the default thresholds."
  }
}

run "rgw_bucket_thresholds" {
  command = plan

  variables {
    rgw_bucket_alerts = { growth_1h_bytes = 1073741824, quota_ratio = 0.9 }
  }

  assert {
    condition = (
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketFastGrowth"], "[1h])) > 1073741824") &&
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWUserNearQuota"], ") > 0.9") &&
      endswith(one([for g in yamldecode(module.monitoring.prometheus_rules).groups : { for r in g.rules : r.alert => r.expr } if g.name == "ceph-rgw-buckets"])["CephRGWBucketGrowth24h"], "[24h])) > 107374182400")
    )
    error_message = "rgw_bucket_alerts overrides only the thresholds it sets."
  }
}

run "rgw_bucket_rules_need_ceph" {
  command = plan

  variables {
    ceph_mgr_nodes = []
  }

  assert {
    condition     = length([for g in yamldecode(module.monitoring.prometheus_rules).groups : g if g.name == "ceph-rgw-buckets"]) == 0
    error_message = "Without a Ceph cluster there are no RGW bucket alerts."
  }
}

run "rgw_bucket_ratio_validated" {
  command = plan

  variables {
    rgw_bucket_alerts = { quota_ratio = 1.5 }
  }

  expect_failures = [var.rgw_bucket_alerts]
}
