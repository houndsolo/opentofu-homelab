# InfluxDB bucket for Telegraf on mon01 (wlc_telemetry): model-driven telemetry from
# the C9800 WLCs (gRPC dial-out). The token goes into mon01's telegraf.env, so the
# backend deploy waits for it; on a fresh mon01, deploy with wlc_telemetry = null
# first (InfluxDB has to be up before these can be created).
resource "influxdb_bucket" "wlc" {
  count = var.wlc_telemetry == null ? 0 : 1

  name             = var.wlc_telemetry.bucket
  org_id           = data.influxdb_organization.monitoring.id
  description      = "Telegraf on mon01: Cisco C9800 model-driven telemetry"
  retention_period = var.pve_metrics.retention_days * 86400
}

resource "influxdb_authorization" "wlc" {
  count = var.wlc_telemetry == null ? 0 : 1

  org_id      = data.influxdb_organization.monitoring.id
  description = "Telegraf on mon01 (C9800 telemetry) -> ${var.wlc_telemetry.bucket}, write only"
  permissions = [{
    action = "write"
    resource = {
      type   = "buckets"
      id     = influxdb_bucket.wlc[0].id
      org_id = data.influxdb_organization.monitoring.id
    }
  }]
}
