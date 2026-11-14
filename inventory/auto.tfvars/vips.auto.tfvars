# keepalived VIPs, keyed by DNS name (see inventory/schema/vips.tf). services-config publishes the
# A/PTR records; the services' keepalived settings are checked against this list.
# Every VIP is named <service>-vip. Web UIs behind the reverse proxy use the plain name for the proxy
# (grafana, netbox, dark-triage: CNAMEs to proxy-vip.lylat.space, generated from services-config
# var.proxy.hosts); nginx forwards to their <name>-vip.
vips = {
  grafana-vip = {
    address     = "10.52.11.100/16"
    vrid        = 100
    role        = "grafana"
    description = "Grafana :3000 (graf01/02), monitoring-config grafana_vrrp; users go through https://grafana.lylat.space (proxy)"
  }
  logs-vip = {
    address     = "10.5.11.101/16"
    vrid        = 101
    role        = "logging"
    description = "Loki/Alloy on the monitoring network: syslog TCP/UDP 514 (loki01-03), monitoring-config logging_settings.vips.monitoring"
  }
  loki-vip = {
    address     = "10.54.18.101/16"
    vrid        = 101
    role        = "logging"
    description = "Loki in lylat-obs: Grafana's Loki datasource (loki01-03), monitoring-config logging_settings.vips.backend"
  }
  wlc-telemetry-vip = {
    address     = "10.5.11.102/16"
    vrid        = 102
    role        = "monitoring"
    description = "C9800 telemetry receiver on the monitoring network (the WLC Telegraf on mon01/02; the WLCs dial 10.5.11.102:57500), monitoring-config backend_vrrp.vips.monitoring"
  }
  monitoring-vip = {
    address     = "10.54.16.102/16"
    vrid        = 102
    role        = "monitoring"
    description = "Grafana's Alertmanager datasource and the wlc scrape (:9275) in lylat-obs (mon01/02), monitoring-config backend_vrrp.vips.backend"
  }
  mimir-vip = {
    address     = "10.54.17.103/16"
    vrid        = 103
    role        = "metrics"
    description = "Mimir in lylat-obs (mim01-03), monitoring-config metrics_settings.vip"
  }
  postgres-vip = {
    address     = "10.56.14.104/16"
    vrid        = 104
    role        = "postgres"
    description = "Patroni leader in lylat-data (pg01-03), monitoring-config postgres_settings.vip"
  }
  dark-triage-vip = {
    address     = "10.52.13.105/16"
    vrid        = 105
    role        = "ticketing"
    description = "dark-triage helpdesk :80 (triage01/02), services-config ticketing.vip; users go through https://dark-triage.lylat.space (proxy)"
  }
  netbox-vip = {
    address     = "10.52.12.106/16"
    vrid        = 106
    role        = "netbox"
    description = "NetBox :80 (netbox01/02), services-config netbox.vip; users go through https://netbox.lylat.space (proxy)"
  }
  proxy-vip = {
    address     = "10.2.11.107/16"
    vrid        = 107
    role        = "proxy"
    description = "nginx reverse proxy (proxy01/02), services-config proxy.vip: https://<name>.lylat.space for var.proxy.hosts (CNAMEs to this name)"
  }
  dns-vip = {
    address     = "10.8.53.53/16"
    vrid        = 53
    role        = "dns"
    description = "DNS resolver VIP (dns01/02), services-config dns_vrrp"
  }
  dns-zone-vip = {
    address     = "10.53.53.53/16"
    vrid        = 53
    role        = "dns"
    description = "DNS resolver VIP in lylat-dns (dns01/02, VLAN 1301), same VRRP instance as dns-vip; services-config dns_vrrp.zone_vip"
  }
}
