output "prometheus_url" {
  description = "Prometheus UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9090"
}

output "alertmanager_url" {
  description = "Alertmanager UI on the backend's monitoring-network address."
  value       = "http://${module.monitoring.backend_url_host}:9093"
}

output "influxdb_url" {
  description = "InfluxDB UI/API on the primary. The Proxmox metric servers (pve-metrics.tf) write here, and to each replica (influxdb-replica.tf)."
  value       = "http://${module.monitoring.backend_url_host}:8086"
}

output "backend_urls" {
  description = "Backend VM name => Prometheus, Alertmanager and InfluxDB UIs on its monitoring-network address."
  value = {
    for name, host in module.monitoring.backend_url_hosts : name => {
      prometheus   = "http://${host}:9090"
      alertmanager = "http://${host}:9093"
      influxdb     = "http://${host}:8086"
    }
  }
}

output "monitoring_vips" {
  description = "keepalived VIPs on the backends: monitoring (InfluxDB, the VyOS relay) and backend (Grafana's InfluxDB/Alertmanager datasources). null without backend_vrrp."
  value       = module.monitoring.backend_vips
}

output "vyos_telegraf_influxdb" {
  description = "Where VyOS Telegraf writes (service monitoring telegraf influxdb url/port): the relay on the monitoring VIP, which copies into bucket vyos on every backend. Same token as before (vyos_telegraf_token). null without the relay."
  value = var.vyos_influx_relay_port == null ? null : {
    url    = "http://${try(module.monitoring.backend_vips.monitoring, module.monitoring.backend_url_host)}"
    port   = var.vyos_influx_relay_port
    bucket = var.vyos_telegraf_bucket
  }
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

output "wlc_telemetry_receiver" {
  description = "Where the C9800s send model-driven telemetry: address = the host of their one receiver (\"mon01\") on every telemetry ietf subscription (the monitoring VIP once both backends run Telegraf, which then write to both InfluxDBs; else the primary), receivers = every backend's own listener, and the InfluxDB bucket. null when wlc_telemetry is off."
  value = var.wlc_telemetry == null ? null : {
    address = coalesce(module.monitoring.wlc_receiver, module.monitoring.backend_url_host)
    # Telegraf listens on each backend's own address too (the replica's once influxdb_replica_ready).
    receivers = { for name, host in module.monitoring.backend_url_hosts : name => host if name == local.backend_name || local.replica_influxdb }
    port      = var.wlc_telemetry.port
    bucket    = var.wlc_telemetry.bucket
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
