# Proxmox external metric servers -> InfluxDB on mon01.
#
# pvestatd on every node pushes node, guest (VM/LXC) and storage stats every ~10 s
# over HTTP (InfluxDB v2 API) to mon01's monitoring-network address. The cluster
# and each standalone host get their own bucket and a token that can only write
# to it. The metric server entries are cluster-wide (/etc/pve/status.cfg), so the
# cluster has one, managed through its API, and greatfox has its own. Both were
# first created by hand and imported (tofu import proxmox_metrics_server.cluster influxdb).

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

resource "influxdb_authorization" "pve" {
  for_each = local.pve_metric_buckets

  org_id      = data.influxdb_organization.monitoring.id
  description = "Proxmox metric server (${each.key}) -> ${each.value}, write only"
  permissions = [{
    action = "write"
    resource = {
      type   = "buckets"
      id     = influxdb_bucket.pve[each.key].id
      org_id = data.influxdb_organization.monitoring.id
    }
  }]
}

locals {
  pve_metric_server = {
    name                = "influxdb"
    server              = coalesce(try(local.monitoring_address[local.backend_name], null), "0.0.0.0")
    port                = 8086
    type                = "influxdb"
    influx_db_proto     = "http"
    influx_organization = var.settings.influxdb_org
    disable             = !var.pve_metrics.enabled
  }
}

resource "proxmox_metrics_server" "cluster" {
  name                = local.pve_metric_server.name
  server              = local.pve_metric_server.server
  port                = local.pve_metric_server.port
  type                = local.pve_metric_server.type
  influx_db_proto     = local.pve_metric_server.influx_db_proto
  influx_organization = local.pve_metric_server.influx_organization
  influx_bucket       = influxdb_bucket.pve["cluster"].name
  influx_token        = influxdb_authorization.pve["cluster"].token
  disable             = local.pve_metric_server.disable
}

resource "proxmox_metrics_server" "standalone" {
  for_each = toset(local.standalone_pve)
  provider = proxmox.greatfox

  name                = local.pve_metric_server.name
  server              = local.pve_metric_server.server
  port                = local.pve_metric_server.port
  type                = local.pve_metric_server.type
  influx_db_proto     = local.pve_metric_server.influx_db_proto
  influx_organization = local.pve_metric_server.influx_organization
  influx_bucket       = influxdb_bucket.pve[each.key].name
  influx_token        = influxdb_authorization.pve[each.key].token
  disable             = local.pve_metric_server.disable
}

# pvestatd -> Telegraf -> Prometheus (modules/services/monitoring/pvestatd.tf): one more metric
# server per monitoring backend, on the cluster and on each standalone host, pointing at that
# backend's pvestatd Telegraf instead of InfluxDB. Every backend gets the writes, so both
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
