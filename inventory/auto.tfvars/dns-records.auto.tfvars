# Hand-made records for lylat.space: only what the inventory doesn't know. services-config generates
# the rest (roots/services-config/dns-records.tf):
#   <vm>         every service/workload VM's service address (the NIC with the default gateway)
#   <vm>.mgmt    every VM's management address (also <node>.mgmt, leaf-<id>.mgmt, spine-<id>.mgmt)
#   <vip>        every keepalived VIP in vips.auto.tfvars (grafana, logs, loki, influxdb, monitoring,
#                mimir, postgres, dark-triage, netbox, dns)
#   <node>, leaf-<id>, spine-<id>, and the DNS servers' own records
# A name here that is also generated fails the dns_hosts_not_generated check.
dns_hosts = {
  triage = { CNAME = "dark-triage.lylat.space." } # short name for dark-triage
  # greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  # www      = { CNAME = "greatfox.lylat.space." }
  # "@"      = { MX = "10 mail.lylat.space.", TXT = "example text" }
  # "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
  haygi       = { A = "10.12.0.10" }
  v100        = { A = "10.12.0.10" }
  ai-v100     = { A = "10.12.0.10" }
  rx3080      = { A = "10.12.0.11" }
  ai-rx3080   = { A = "10.12.0.11" }
  rx6800xt    = { A = "10.12.0.12" }
  ai-6800xt   = { A = "10.12.0.12" }
  ai-rx6800xt = { A = "10.12.0.12" }
  fw-wan      = { A = "10.20.10.255" }
  torrent     = { A = "10.8.7.7" }
  automation0 = { A = "10.20.250.255" }
  nixos       = { A = "10.20.250.255" }
  arch        = { A = "10.9.9.69" }

  # Backend UIs on the monitoring network (vmbr100): Prometheus :9090,
  # Alertmanager :9093, InfluxDB :8086. The unsuffixed names stay on mon01
  # (influxdb is the monitoring VIP, see vips.auto.tfvars).
  prometheus         = { A = "10.5.11.30" }
  alertmanager       = { A = "10.5.11.30" }
  prometheus-mon02   = { A = "10.5.11.31" }
  alertmanager-mon02 = { A = "10.5.11.31" }
  influxdb-mon01     = { A = "10.5.11.30" }
  influxdb-mon02     = { A = "10.5.11.31" }
}

# Use this list for multiple records with the same owner/type or custom TTLs.
dns_records = [
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  # { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
  # { name = "@", type = "TXT", data = "another text value" },
]
