# Custom records for lylat.space. Uncomment and replace example values.
# Proxmox management A records are generated automatically by services-config.
dns_hosts = {
  # greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  # www      = { CNAME = "greatfox.lylat.space." }
  # "@"      = { MX = "10 mail.lylat.space.", TXT = "\"example text\"" }
  # "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
  # "@"      = { CAA = "0 issue \"letsencrypt.org\"" }
}

# Use this list for multiple records with the same owner/type or custom TTLs.
dns_records = [
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  # { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
  # { name = "@", type = "TXT", data = "\"another text value\"" },
  # RFC 3597 example for an unknown/private RR type (two data bytes):
  # { name = "opaque", type = "TYPE65280", data = "\\# 2 ABCD" },
]
