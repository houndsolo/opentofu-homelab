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

output "vyos_telegraf_token" {
  description = "Write-only InfluxDB token for Telegraf on the VyOS routers: tofu output -raw vyos_telegraf_token"
  value       = influxdb_authorization.vyos.token
  sensitive   = true
}

output "loki_url" {
  description = "Loki on the backend VIP (Grafana's Loki datasource; Alloy on mon01/graf pushes here)."
  value       = module.monitoring.loki_url
}

output "logging_vips" {
  description = "Logging VIPs per network (VRRP, all held by the same logging VM). Syslog senders use monitoring/mgmt (UDP 514 RFC 3164, TCP 514 RFC 5424)."
  value       = var.logging_settings.vips
}

output "loki_urls" {
  description = "Each Loki on its logging VM's backend-VLAN address (for debugging; use loki_url)."
  value       = { for name, vm in local.logging_nic : name => "http://${try(vm.backend.address, "0.0.0.0")}:3100" }
}
