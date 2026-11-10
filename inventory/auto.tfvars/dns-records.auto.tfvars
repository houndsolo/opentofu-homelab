# Custom records for lylat.space. Uncomment and replace example values.
# Proxmox management A records are generated automatically by services-config.
dns_hosts = {
  # greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  # www      = { CNAME = "greatfox.lylat.space." }
  # "@"      = { MX = "10 mail.lylat.space.", TXT = "example text" }
  # "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
  haygi = { A = "10.12.0.10"}
  v100 = { A = "10.12.0.10"}
  ai-v100 = { A = "10.12.0.10"}
  rx3080 = { A = "10.12.0.11"}
  ai-rx3080 = { A = "10.12.0.11"}
  rx6800xt = { A = "10.12.0.12"}
  ai-6800xt = { A = "10.12.0.12"}
  ai-rx6800xt = { A = "10.12.0.12"}
  fw-wan = { A = "10.20.10.255"}
  torrent = { A = "10.8.7.7"}
  automation0 = { A = "10.20.250.255"}
  nixos = { A = "10.20.250.255"}
  arch = { A = "10.9.9.69"}
  netbox = { A = "10.2.0.40"}

  # Monitoring stack (roots/monitoring-config). Hosts on their mgmt addresses.
  mon01  = { A = "10.20.11.30" }
  mon02  = { A = "10.20.11.31" }
  graf01 = { A = "10.20.11.32" }
  graf02 = { A = "10.20.11.33" }
  loki01 = { A = "10.20.11.34" }
  loki02 = { A = "10.20.11.35" }
  loki03 = { A = "10.20.11.36" }
  mim01  = { A = "10.20.11.37" }
  mim02  = { A = "10.20.11.38" }
  mim03  = { A = "10.20.11.39" }
  pg01   = { A = "10.20.11.40" }
  pg02   = { A = "10.20.11.41" }
  pg03   = { A = "10.20.11.42" }
  # Grafana's Postgres: the Patroni leader's VIP (keepalived on pg01-03) on the isolated
  # backend VLAN 13 (lylat_monitor VRF): only reachable from that VLAN.
  postgres = { A = "10.13.11.104" }
  # Backend UIs on the monitoring network (vmbr100): Prometheus :9090,
  # Alertmanager :9093, InfluxDB :8086. The unsuffixed names stay on mon01,
  # except influxdb: the monitoring VIP (keepalived on mon01/mon02).
  prometheus         = { A = "10.5.11.30" }
  alertmanager       = { A = "10.5.11.30" }
  influxdb           = { A = "10.5.11.102" }
  prometheus-mon02   = { A = "10.5.11.31" }
  alertmanager-mon02 = { A = "10.5.11.31" }
  influxdb-mon01     = { A = "10.5.11.30" }
  influxdb-mon02     = { A = "10.5.11.31" }
  # Loki/Alloy VIP (keepalived on loki01-03) on the monitoring network: syslog
  # TCP/UDP 514 from devices and PVE nodes.
  logs = { A = "10.5.11.101" }
}

# Use this list for multiple records with the same owner/type or custom TTLs.
dns_records = [
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  # { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
  # { name = "@", type = "TXT", data = "another text value" },

  # Grafana :3000 on VLAN 2: the keepalived VIP held by graf01 or graf02
  # (monitoring-config grafana_vrrp). Matches grafana_root_url.
  { name = "grafana", type = "A", data = "10.2.11.100" },
]
