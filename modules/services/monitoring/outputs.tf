output "backend_deployments" {
  description = "Backend VM name => deploy.sh. Contains secrets."
  value       = local.backend_deployments
  sensitive   = true
}

output "grafana_deployments" {
  description = "Grafana VM name => deploy.sh. Contains secrets."
  value       = local.grafana_deployments
  sensitive   = true
}

output "prometheus_config" {
  description = "The primary backend's rendered prometheus.yml (no secrets). The replicas' differ only in __replica__."
  value       = local.prometheus_yml[local.primary]
}

output "prometheus_configs" {
  description = "Backend VM name => rendered prometheus.yml."
  value       = local.prometheus_yml
}

output "prometheus_rules" {
  description = "Rendered Prometheus alert rules (rules/basic.yml)."
  value       = local.rules_yml
}

output "prometheus_ceph_rules" {
  description = "Rendered rules/ceph.yml: the ceph-mixin alerts, \"\" without Ceph targets."
  value       = local.ceph_alerts_yml
}

output "datasources_config" {
  description = "Rendered Grafana datasource provisioning (the InfluxDB token stays an env reference)."
  value       = local.datasources_yml
}

output "backend_services" {
  description = "systemd services on the primary backend, in restart order."
  value       = local.backend_services[local.primary]
}

output "backend_services_by_host" {
  description = "Backend VM name => systemd services, in restart order."
  value       = local.backend_services
}

output "backend_url_host" {
  description = "Primary backend address users reach the UIs on (the monitoring-network address)."
  value       = local.mon
}

output "backend_url_hosts" {
  description = "Backend VM name => monitoring-network address (UIs)."
  value       = { for name, b in var.backends : name => b.monitoring_address }
}

output "backend_vips" {
  description = "keepalived VIPs on the backends (monitoring, backend), or null without backend_vrrp."
  value       = local.backend_vrrp_enabled ? { monitoring = local.backend_vip_monitoring[0], backend = local.backend_vip_backend[0] } : null
}

output "backend_keepalived_configs" {
  description = "Rendered keepalived.conf per backend (null when backend_vrrp is off). Contains the VRRP password."
  value       = local.backend_keepalived_conf
  sensitive   = true
}

output "pvestatd_telegraf_config" {
  description = "The pvestatd Telegraf's telegraf.conf (the token stays an environment reference), \"\" when off."
  value       = local.pvestatd_telegraf_conf
}

output "wlc_telegraf_configs" {
  description = "Backend VM name => the WLC telemetry Telegraf's telegraf.conf (tokens stay environment references), \"\" when off."
  value       = local.telegraf_conf
}

output "wlc_receiver" {
  description = "Where the C9800s' telemetry receiver points: the monitoring VIP when the Telegrafs fan out to every backend (two or more with keepalived), else null (each backend's own monitoring address)."
  value       = local.wlc_vip ? local.backend_vip_monitoring[0] : null
}

output "alertmanager_targets" {
  description = "Every Alertmanager (backend VLAN address:port): Prometheus and the Loki ruler send to all of them."
  value       = local.alertmanager_targets
}

output "units" {
  description = "Rendered Quadlet .container units (no secrets): VM name => service => unit text."
  value = merge(
    { for name in local.backend_names : name => merge(local.backend_units[name], { alloy = local.alloy_unit[name] }) },
    { for name, units in local.grafana_units : name => merge(units, { alloy = local.alloy_unit[name] }) },
    local.logging_units,
    { for name, units in local.metrics_units : name => merge(units, { alloy = local.alloy_unit[name] }) if local.mimir_enabled }, # metrics.tf
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

output "logging_keepalived_configs" {
  description = "Rendered keepalived.conf per logging VM. Contains the VRRP password."
  value       = local.keepalived_conf
  sensitive   = true
}

output "logging_guard_config" {
  description = "Rendered logging-guard nftables ruleset (the same on every logging VM)."
  value       = local.guard_nft
}

output "grafana_keepalived_configs" {
  description = "Rendered keepalived.conf per Grafana VM (null when grafana_vrrp is off). Contains the VRRP password."
  value       = local.grafana_keepalived_conf
  sensitive   = true
}

output "metrics_deployments" {
  description = "Mimir VM name => deploy.sh (empty when Mimir is off). Contains secrets (S3 keys, VRRP password)."
  value       = local.metrics_deployments
  sensitive   = true
}

output "mimir_configs" {
  description = "Mimir VM name => rendered mimir.yaml (the S3 keys stay environment references, from mimir.env)."
  value       = local.mimir_enabled ? local.mimir_yml : {}
}

output "mimir_haproxy_configs" {
  description = "Mimir VM name => rendered haproxy.cfg."
  value       = local.mimir_enabled ? local.metrics_haproxy_cfg : {}
}

output "mimir_keepalived_configs" {
  description = "Mimir VM name => rendered keepalived.conf (empty when Mimir is off). Contains the VRRP password."
  value       = local.mimir_enabled ? local.metrics_keepalived_conf : {}
  sensitive   = true
}

output "mimir_url" {
  description = "Mimir on its VIP (Prometheus remote_write: /api/v1/push, Grafana: /prometheus); null when Mimir is off."
  value       = local.mimir_enabled ? local.mimir_url : null
}

output "postgres_deployments" {
  description = "Patroni member name => deploy.sh (empty when the cluster is off). Contains secrets (passwords, S3 keys)."
  value       = local.postgres_deployments
  sensitive   = true
}

output "patroni_configs" {
  description = "Patroni member name => rendered /etc/patroni/config.yml (no secrets: passwords come from patroni.env)."
  value       = local.postgres_enabled ? local.patroni_yml : {}
}

output "etcd_configs" {
  description = "Patroni member name => rendered /etc/etcd/etcd.yml."
  value       = local.postgres_enabled ? local.etcd_yml : {}
}

output "postgres_guard" {
  description = "Rendered postgres-guard nftables ruleset (the same on every member)."
  value       = local.postgres_enabled ? local.pg_guard_nft : null
}

output "postgres_keepalived_configs" {
  description = "Patroni member name => rendered keepalived.conf (contains the VRRP password)."
  value       = local.postgres_enabled ? local.pg_keepalived_conf : {}
  sensitive   = true
}

output "pgbackrest_conf" {
  description = "Rendered /etc/pgbackrest/pgbackrest.conf (no secrets: the S3 keys come from s3.env)."
  value       = local.postgres_enabled ? local.pgbackrest_conf : null
}

output "postgres_vip" {
  description = "Grafana's database endpoint on the Patroni cluster (the leader's VIP, host:port); null when the cluster is off."
  value       = local.postgres_enabled ? "${local.pg_vip}:5432" : null
}

output "grafana_db_host" {
  description = "Where Grafana's database is: the Patroni VIP after the cutover, the primary backend's Postgres before."
  value       = local.grafana_db_host
}
