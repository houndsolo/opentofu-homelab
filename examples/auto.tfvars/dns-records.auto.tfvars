# Names are relative to lylat.space. This map replaces generated records for
# the same owner, so include A here if you also want to add AAAA to that host.
dns_hosts = {
  greatfox    = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  www         = { CNAME = "greatfox.lylat.space." } # Absolute target ends in a dot.
  mail        = { A = "10.8.25.1" }
  "@"         = { MX = "10 mail.lylat.space.", TXT = "v=spf1 -all" }
  "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." } # priority weight port target
}

# Use the list for multiple values of one type, or a custom TTL (seconds).
# Records sharing an owner/type must share a TTL; a CNAME has only one target.
dns_records = [
  { name = "app", type = "A", data = "10.8.100.5", ttl = 60 },
  { name = "app", type = "A", data = "10.8.100.6", ttl = 60 },
  { name = "delegated", type = "NS", data = "dns01.lylat.space.", ttl = 300 },
]
# Supported: A, AAAA, CNAME, TXT, MX, NS, PTR, SRV. PTR needs the appropriate
# reverse zone to provide reverse lookup; this root only manages lylat.space.
# SOA, apex NS, and dns01/dns02 A records are managed by the bootstrap.
