# Proxmox external metric servers (pvestatd, every ~10 s).
#
# Since 2026-11-13 pvestatd writes only to the pvestatd Telegraf on each monitoring backend, which
# serves the data to Prometheus (below and modules/services/monitoring/pvestatd.tf). The InfluxDB
# metric servers ("influxdb" -> mon01, "influxdb-mon02") and their write-only tokens are retired.
# The buckets below (one for the cluster, one per standalone host; mon02's copies in
# influxdb-replica.tf) keep the history from 2026-11-09 until it is backfilled into Mimir; then
# they can go too.

locals {
  pve_metric_buckets = merge(
    { cluster = var.pve_metrics.cluster_bucket },
    { for name in local.standalone_pve : name => "${var.pve_metrics.standalone_bucket_prefix}${name}" },
  )
}

data "influxdb_organization" "monitoring" {
  name = var.settings.influxdb_org
}

resource "influxdb_bucket" "pve" {
  for_each = local.pve_metric_buckets

  name             = each.value
  org_id           = data.influxdb_organization.monitoring.id
  description      = "Proxmox metric server: ${each.key == "cluster" ? "cluster" : each.key}"
  retention_period = var.pve_metrics.retention_days * 86400
}

# pvestatd -> Telegraf -> Prometheus (modules/services/monitoring/pvestatd.tf): one metric server
# per monitoring backend, on the cluster and on each standalone host, pointing at that backend's
# pvestatd Telegraf. Every backend gets the writes, so both
# Prometheus replicas see the same data. Type "influxdb" is the protocol; nothing is stored in
# InfluxDB (the bucket name is required by PVE and ignored by the listener). They're created
# after the backends' deploy, so the listener already answers.
resource "random_password" "pvestatd" {
  length  = 40
  special = false
}

locals {
  pvestatd_backends = { for name in keys(local.monitoring_vms) : name => coalesce(local.monitoring_address[name], "0.0.0.0") }
  pvestatd_standalone = merge([for host in local.standalone_pve : {
    for name, address in local.pvestatd_backends : "${host}/${name}" => { host = host, backend = name, address = address }
  }]...)
}

resource "proxmox_metrics_server" "pvestatd" {
  for_each = local.pvestatd_backends

  name                = "pvestatd-${each.key}"
  server              = each.value
  port                = var.pve_metrics.pvestatd_port
  type                = "influxdb"
  influx_db_proto     = "http"
  influx_organization = var.settings.influxdb_org
  influx_bucket       = "pvestatd"
  influx_token        = random_password.pvestatd.result
  disable             = !var.pve_metrics.enabled

  depends_on = [terraform_data.backend]
}

resource "proxmox_metrics_server" "pvestatd_standalone" {
  for_each = local.pvestatd_standalone
  provider = proxmox.greatfox

  name                = "pvestatd-${each.value.backend}"
  server              = each.value.address
  port                = var.pve_metrics.pvestatd_port
  type                = "influxdb"
  influx_db_proto     = "http"
  influx_organization = var.settings.influxdb_org
  influx_bucket       = "pvestatd"
  influx_token        = random_password.pvestatd.result
  disable             = !var.pve_metrics.enabled

  depends_on = [terraform_data.backend]
}
