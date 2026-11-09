# InfluxDB bucket for Telegraf on VyOS routers (service monitoring telegraf influxdb).
# VyOS only runs its firewall/interface/service exec inputs (per-rule nftables
# counters) when the influxdb output is configured, so the routers write here and
# also expose the same metrics to Prometheus through telegraf's prometheus-client
# output. The routers aren't managed by this repo: set the token on them by hand
# (tofu output -raw vyos_telegraf_token).

resource "influxdb_bucket" "vyos" {
  name             = var.vyos_telegraf_bucket
  org_id           = data.influxdb_organization.monitoring.id
  description      = "Telegraf on VyOS routers"
  retention_period = var.pve_metrics.retention_days * 86400
}

resource "influxdb_authorization" "vyos" {
  org_id      = data.influxdb_organization.monitoring.id
  description = "Telegraf on VyOS routers -> ${var.vyos_telegraf_bucket}, write only"
  permissions = [{
    action = "write"
    resource = {
      type   = "buckets"
      id     = influxdb_bucket.vyos.id
      org_id = data.influxdb_organization.monitoring.id
    }
  }]
}
