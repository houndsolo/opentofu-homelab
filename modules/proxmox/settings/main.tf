resource "proxmox_metrics_server" "influxdb_server" {
  name                = "influxdb"
  server              = var.influxdb.ip
  port                = 8086
  type                = "influxdb"
  influx_db_proto     = var.influxdb.proto
  influx_organization = var.influxdb.org
  influx_bucket       = var.influxdb.bucket
  influx_token        = var.influxdb.token
  influx_verify       = false
  mtu                 = 1500
  disable             = true
  lifecycle {
    ignore_changes = [
      influx_token
    ]
  }
}

