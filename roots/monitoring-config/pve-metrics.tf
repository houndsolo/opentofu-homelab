# Proxmox external metric servers (pvestatd, every ~10 s).
#
# Since 2026-11-13 pvestatd writes only to the pvestatd Telegraf on each monitoring backend, which
# serves the data to Prometheus (below and modules/services/monitoring/pvestatd.tf). The InfluxDB
# metric servers, their write-only tokens and InfluxDB itself are retired (2026-11-13/14); the
# history from 2026-11-09 is backfilled into Mimir. influxdb.tf forgets the old buckets without
# deleting them.

locals {
  # PVE requires an organization and bucket on an "influxdb" metric server; the pvestatd Telegraf
  # ignores both.
  pvestatd_organization = "lylat"
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
  influx_organization = local.pvestatd_organization
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
  influx_organization = local.pvestatd_organization
  influx_bucket       = "pvestatd"
  influx_token        = random_password.pvestatd.result
  disable             = !var.pve_metrics.enabled

  depends_on = [terraform_data.backend]
}
