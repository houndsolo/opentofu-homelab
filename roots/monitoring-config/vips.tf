# The monitoring stack's keepalived VIPs must match the VIP inventory
# (inventory/auto.tfvars/vips.auto.tfvars, which services-config also publishes in DNS). The
# settings stay where the services read them; this only keeps both places identical.
locals {
  vip_inventory_checks = [
    { name = "grafana-vip", vip = try(var.grafana_vrrp.vip, null), vrid = try(var.grafana_vrrp.router_id, null), role = "grafana" },
    { name = "logs-vip", vip = try(var.logging_settings.vips.monitoring, null), vrid = try(var.logging_settings.vrrp_router_id, null), role = "logging" },
    { name = "loki-vip", vip = try(var.logging_settings.vips.backend, null), vrid = try(var.logging_settings.vrrp_router_id, null), role = "logging" },
    { name = "influxdb-vip", vip = try(var.backend_vrrp.vips.monitoring, null), vrid = try(var.backend_vrrp.router_id, null), role = "monitoring" },
    { name = "monitoring-vip", vip = try(var.backend_vrrp.vips.backend, null), vrid = try(var.backend_vrrp.router_id, null), role = "monitoring" },
    { name = "mimir-vip", vip = try(var.metrics_settings.vip, null), vrid = try(var.metrics_settings.vrrp_router_id, null), role = "metrics" },
    { name = "postgres-vip", vip = try(var.postgres_settings.vip, null), vrid = try(var.postgres_settings.vrrp_router_id, null), role = "postgres" },
  ]
  vip_inventory_mismatches = [
    for c in local.vip_inventory_checks : c.name
    if c.vip != null && !try(var.vips[c.name].address == c.vip && var.vips[c.name].vrid == c.vrid && var.vips[c.name].role == c.role, false)
  ]
}

check "vips_match_monitoring_config" {
  assert {
    condition     = length(local.vip_inventory_mismatches) == 0
    error_message = "monitoring-config VIP settings differ from inventory/auto.tfvars/vips.auto.tfvars for: ${join(", ", local.vip_inventory_mismatches)}. Keep them identical."
  }
}
