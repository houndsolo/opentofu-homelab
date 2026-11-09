output "prometheus_url" {
  description = "Prometheus UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9093"
}

output "influxdb_url" {
  description = "InfluxDB UI/API. The Proxmox metric servers (pve-metrics.tf) write here."
  value       = "http://${module.monitoring.backend_url_host}:8086"
}

output "grafana_urls" {
  description = "Each Grafana front end on its user-facing address (the NIC with the default gateway). Port 3000 also answers on the VM's other addresses."
  value = {
    for name in keys(local.grafana_vms) : name => "http://${try(split("/", [
      for nic in local.nics[name] : nic.ipv4_address if nic.ipv4_gateway != null && nic.ipv4_address != null
    ][0])[0], local.mgmt[name])}:3000"
  }
}

output "grafana_admin_password" {
  description = "Grafana 'admin' password: tofu output -raw grafana_admin_password"
  value       = coalesce(var.grafana_admin_password, random_password.grafana_admin.result)
  sensitive   = true
}

output "influxdb_admin_token" {
  description = "InfluxDB operator token (also used by Grafana for now; the Proxmox metric servers have their own write-only tokens)."
  value       = random_password.influxdb_token.result
  sensitive   = true
}

output "prometheus_config" {
  description = "Rendered prometheus.yml."
  value       = module.monitoring.prometheus_config
}

output "pve_metric_buckets" {
  description = "InfluxDB bucket per Proxmox metric server: cluster and each standalone host."
  value       = local.pve_metric_buckets
}
