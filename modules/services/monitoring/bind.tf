# BIND on dns01/02 (deployed by services-config main.tf, behind keepalived's dns-vip 10.8.53.53).
# bind_exporter runs on each VM (services-config dns-bind-exporter.tf) on the management address,
# :9119, reading BIND's statistics channel. node_exporter is in the node job, the SOA probes in
# blackbox-dns_soa.
locals {
  bind_scrape_configs = length(var.targets.bind) == 0 ? [] : [{
    job_name       = "bind"
    static_configs = [for t in var.targets.bind : { targets = ["${t.address}:9119"], labels = { host = t.host } }]
  }]

  # The zones OpenTofu serves (primary on dns01, secondary on dns02); the automatic empty zones all have serial 0.
  bind_zones = "lylat.space|10.in-addr.arpa"

  bind_rules = length(var.targets.bind) == 0 ? [] : [{
    name = "bind"
    rules = [
      {
        # The exporter answers but BIND's statistics channel doesn't (bind_up 0), or the exporter is gone (up 0).
        alert       = "BindDown"
        expr        = "bind_up{job=\"bind\"} == 0 or up{job=\"bind\"} == 0"
        for         = "2m"
        labels      = { severity = "warning" }
        annotations = { summary = "BIND or its exporter on {{ $labels.host }} is down (check the SOA probe: if it still answers, only the exporter is)" }
      },
      {
        alert       = "BindAllDown"
        expr        = "sum(bind_up{job=\"bind\"}) == 0 or absent(bind_up{job=\"bind\"})"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "No BIND server is up: lylat.space names and recursion fail for every client" }
      },
      {
        # Share of answers that are SERVFAIL (forwarder or DNSSEC trouble), with a floor so a handful of
        # queries on a quiet server can't trip it.
        alert       = "BindHighServfailRate"
        expr        = "sum by (host) (rate(bind_response_rcodes_total{job=\"bind\", rcode=\"SERVFAIL\"}[10m])) / sum by (host) (rate(bind_response_rcodes_total{job=\"bind\"}[10m])) > 0.05 and sum by (host) (rate(bind_response_rcodes_total{job=\"bind\"}[10m])) > 0.2"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "{{ $value | humanizePercentage }} of the answers from {{ $labels.host }} are SERVFAIL: are the forwarders (1.1.1.1/1.0.0.1) reachable?" }
      },
      {
        # dns02 normally catches up within seconds of a NOTIFY; 15 minutes apart means transfers stopped.
        alert       = "BindZoneSerialMismatch"
        expr        = "max by (zone_name) (bind_zone_serial{job=\"bind\", zone_name=~\"${local.bind_zones}\"}) - min by (zone_name) (bind_zone_serial{job=\"bind\", zone_name=~\"${local.bind_zones}\"}) > 0"
        for         = "15m"
        labels      = { severity = "warning" }
        annotations = { summary = "Zone {{ $labels.zone_name }} has different serials on dns01 and dns02 (off by {{ $value }}): zone transfers are failing" }
      },
    ]
  }]
}
