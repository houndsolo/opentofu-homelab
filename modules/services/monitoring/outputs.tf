output "backend_deployment" {
  description = "deploy.sh for the backend VM. Contains secrets."
  value       = local.backend_deployment
  sensitive   = true
}

output "grafana_deployments" {
  description = "Grafana VM name => deploy.sh. Contains secrets."
  value       = local.grafana_deployments
  sensitive   = true
}

output "prometheus_config" {
  description = "Rendered prometheus.yml (no secrets)."
  value       = local.prometheus_yml
}

output "datasources_config" {
  description = "Rendered Grafana datasource provisioning (the InfluxDB token stays an env reference)."
  value       = local.datasources_yml
}

output "backend_services" {
  description = "systemd services on the backend, in restart order."
  value       = concat(["monitoring-network"], local.backend_order)
}

output "backend_url_host" {
  description = "Backend address users reach the UIs on (the monitoring-network address)."
  value       = var.backend.monitoring_address
}

output "units" {
  description = "Rendered Quadlet .container units (no secrets): VM name => service => unit text."
  value = merge(
    { (var.backend.name) = local.backend_units },
    local.grafana_units,
  )
}

output "dashboard_providers_config" {
  description = "Rendered Grafana dashboard provider (provisioning/dashboards/dashboards.yml)."
  value       = local.dashboard_providers_yml
}

output "dashboards" {
  description = "Provisioned dashboards: path under dashboards/ (folder/name.json) => minified JSON."
  value       = local.dashboards
}
