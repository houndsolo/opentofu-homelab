output "prometheus_url" {
  description = "Prometheus UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9093"
}

output "backend_urls" {
  description = "Backend VM name => Prometheus and Alertmanager UIs on its monitoring-network address."
  value = {
    for name, host in module.monitoring.backend_url_hosts : name => {
      prometheus   = "http://${host}:9090"
      alertmanager = "http://${host}:9093"
    }
  }
}

output "monitoring_vips" {
  description = "keepalived VIPs on the backends: monitoring (the C9800s' telemetry receiver) and backend (Grafana's Alertmanager datasource, the wlc scrape). null without backend_vrrp."
  value       = module.monitoring.backend_vips
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

output "prometheus_config" {
  description = "Rendered prometheus.yml."
  value       = module.monitoring.prometheus_config
}

output "wlc_telemetry_receiver" {
  description = "Where the C9800s send model-driven telemetry: address = the host of their one receiver (\"mon01\") on every telemetry ietf subscription (the monitoring VIP when both backends run Telegraf with keepalived; else the primary), receivers = every backend's own listener. null when wlc_telemetry is off."
  value = var.wlc_telemetry == null ? null : {
    address   = coalesce(module.monitoring.wlc_receiver, module.monitoring.backend_url_host)
    receivers = module.monitoring.backend_url_hosts
    port      = var.wlc_telemetry.port
  }
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
