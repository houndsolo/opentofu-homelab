# InfluxDB 2 on mon01/mon02 is retired (2026-11-14): Proxmox and C9800 telemetry go to Prometheus
# (pvestatd.tf, telemetry.tf in the module), and the history of the buckets below is backfilled
# into Mimir. These blocks only drop the buckets and write tokens from the state: destroying them
# would need a running InfluxDB (the provider is gone) and would delete the history. The data stays
# on disk in /var/lib/monitoring/influxdb on both backends until it is removed by hand. Once one
# apply has run, this file and the influxdb provider requirement (providers.tf) can go.

# Both providers still need a reachable InfluxDB, even only to drop objects from the state: the
# provider pings its URL when it's configured. In the apply, that happens right at the start, while
# InfluxDB still runs (terraform_data.backend stops it minutes later). If an apply fails here because
# InfluxDB is already gone, drop the objects by hand instead:
#   tofu state rm influxdb_bucket.pve influxdb_bucket.wlc influxdb_authorization.wlc \
#     influxdb_bucket.replica influxdb_authorization.replica
# and delete this file, the provider requirement and random_password.influxdb_token.
provider "influxdb" {
  url   = "http://${coalesce(try(local.monitoring_address[local.backend_name], null), "0.0.0.0")}:8086"
  token = random_password.influxdb_token.result
}

provider "influxdb" {
  alias = "replica"
  url   = "http://${coalesce(try(local.monitoring_address[one([for name in keys(local.monitoring_vms) : name if name != var.monitoring_primary])], null), "0.0.0.0")}:8086"
  token = random_password.influxdb_token.result
}

# The operator token both InfluxDBs were set up with; only the providers above use it now.
resource "random_password" "influxdb_token" {
  length  = 48
  special = false
}

removed {
  from = influxdb_bucket.pve
  lifecycle {
    destroy = false
  }
}

removed {
  from = influxdb_bucket.wlc
  lifecycle {
    destroy = false
  }
}

removed {
  from = influxdb_authorization.wlc
  lifecycle {
    destroy = false
  }
}

removed {
  from = influxdb_bucket.replica
  lifecycle {
    destroy = false
  }
}

removed {
  from = influxdb_authorization.replica
  lifecycle {
    destroy = false
  }
}
