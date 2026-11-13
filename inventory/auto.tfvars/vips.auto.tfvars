# keepalived VIPs, keyed by DNS name (see inventory/schema/vips.tf). services-config publishes the
# A/PTR records; the services' keepalived settings are checked against this list.
vips = {
  grafana = {
    address     = "10.2.11.100/16"
    vrid        = 100
    role        = "grafana"
    description = "Grafana UI :3000 (graf01/02), monitoring-config grafana_vrrp"
  }
  logs = {
    address     = "10.5.11.101/16"
    vrid        = 101
    role        = "logging"
    description = "Loki/Alloy on the monitoring network: syslog TCP/UDP 514 (loki01-03), monitoring-config logging_settings.vips.monitoring"
  }
  loki = {
    address     = "10.13.11.101/16"
    vrid        = 101
    role        = "logging"
    description = "Loki on the backend VLAN: Grafana's Loki datasource (loki01-03), monitoring-config logging_settings.vips.backend"
  }
  influxdb = {
    address     = "10.5.11.102/16"
    vrid        = 102
    role        = "monitoring"
    description = "InfluxDB and the VyOS InfluxDB relay on the monitoring network (mon01/02), monitoring-config backend_vrrp.vips.monitoring"
  }
  monitoring = {
    address     = "10.13.11.102/16"
    vrid        = 102
    role        = "monitoring"
    description = "Grafana's InfluxDB/Alertmanager datasources on the backend VLAN (mon01/02), monitoring-config backend_vrrp.vips.backend"
  }
  mimir = {
    address     = "10.13.11.103/16"
    vrid        = 103
    role        = "metrics"
    description = "Mimir on the backend VLAN (mim01-03), monitoring-config metrics_settings.vip"
  }
  postgres = {
    address     = "10.13.11.104/16"
    vrid        = 104
    role        = "postgres"
    description = "Patroni leader on the backend VLAN (pg01-03), monitoring-config postgres_settings.vip"
  }
  dark-triage = {
    address     = "10.2.11.105/16"
    vrid        = 105
    role        = "ticketing"
    description = "dark-triage helpdesk (triage01/02), services-config ticketing.vip"
  }
  netbox = {
    address     = "10.2.11.106/16"
    vrid        = 106
    role        = "netbox"
    description = "NetBox (netbox01/02), services-config netbox.vip"
  }
  proxy = {
    address     = "10.2.11.107/16"
    vrid        = 107
    role        = "proxy"
    description = "nginx reverse proxy for *.svc.lylat.space (proxy01/02), services-config proxy.vip"
  }
  dns = {
    address     = "10.8.53.53/16"
    vrid        = 53
    role        = "dns"
    description = "DNS resolver VIP (dns01/02), services-config dns_vrrp"
  }
}
