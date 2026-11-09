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

output "prometheus_rules" {
  description = "Rendered Prometheus alert rules (rules/basic.yml)."
  value       = local.rules_yml
}

output "datasources_config" {
  description = "Rendered Grafana datasource provisioning (the InfluxDB token stays an env reference)."
  value       = local.datasources_yml
}

output "backend_services" {
  description = "systemd services on the backend, in restart order."
  value       = concat(["monitoring-network"], local.backend_order, ["alloy"])
}

output "backend_url_host" {
  description = "Backend address users reach the UIs on (the monitoring-network address)."
  value       = var.backend.monitoring_address
}

output "units" {
  description = "Rendered Quadlet .container units (no secrets): VM name => service => unit text."
  value = merge(
    { (var.backend.name) = merge(local.backend_units, { alloy = local.alloy_unit[var.backend.name] }) },
    { for name, units in local.grafana_units : name => merge(units, { alloy = local.alloy_unit[name] }) },
    local.logging_units,
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

output "logging_deployments" {
  description = "Logging VM name => deploy.sh. Contains secrets (S3 keys, VRRP password)."
  value       = local.logging_deployments
  sensitive   = true
}

output "loki_configs" {
  description = "Logging VM name => rendered loki.yaml (the S3 keys stay environment references, from loki.env)."
  value       = local.loki_yml
}

output "alloy_configs" {
  description = "VM name => rendered config.alloy (backend, Grafana and logging VMs)."
  value       = local.alloy_config
}

output "haproxy_configs" {
  description = "Logging VM name => rendered haproxy.cfg."
  value       = local.haproxy_cfg
}

output "loki_url" {
  description = "Loki on the backend VIP (Grafana datasource, Alloy pushes)."
  value       = local.loki_url
}
