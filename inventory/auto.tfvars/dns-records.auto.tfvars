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
}

# Use this list for multiple records with the same owner/type or custom TTLs.
dns_records = [
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  # { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
  # { name = "@", type = "TXT", data = "another text value" },
]
