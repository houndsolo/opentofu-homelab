# nginx reverse proxy (proxy01/02 behind proxy-vip; deployed by services-config proxy.tf).
# nginx-prometheus-exporter runs on each VM (services-config proxy-monitoring.tf) on the management
# address, :9113, reading nginx's stub_status. node_exporter is in the node job.
locals {
  nginx_scrape_configs = length(var.targets.nginx) == 0 ? [] : [{
    job_name       = "nginx"
    static_configs = [for t in var.targets.nginx : { targets = ["${t.address}:9113"], labels = { host = t.host } }]
  }]

  nginx_rules = concat(length(var.targets.nginx) == 0 ? [] : [{
    name = "nginx"
    rules = [
      {
        # The exporter answers but nginx doesn't (nginx_up 0), or the exporter itself is gone (up 0).
        alert       = "NginxProxyNodeDown"
        expr        = "nginx_up{job=\"nginx\"} == 0 or up{job=\"nginx\"} == 0"
        for         = "2m"
        labels      = { severity = "warning" }
        annotations = { summary = "nginx reverse proxy on {{ $labels.host }} is down (the other node holds the VIP)" }
      },
      {
        alert       = "NginxProxyAllDown"
        expr        = "sum(nginx_up{job=\"nginx\"}) == 0 or absent(nginx_up{job=\"nginx\"})"
        for         = "1m"
        labels      = { severity = "critical" }
        annotations = { summary = "No nginx reverse proxy is up: https://grafana/netbox/dark-triage.lylat.space are unreachable" }
      },
    ]
    }], length(lookup(var.targets.blackbox, "https", [])) == 0 ? [] : [{
    # The Let's Encrypt wildcard (roots/certs) as the sites serve it, from the blackbox-https probes. The
    # certs root renews from 30 days left (ARI window), so < 14 days means renewals stopped running.
    name = "tls"
    rules = [
      {
        alert       = "TLSCertExpiringSoon"
        expr        = "min by (instance) (probe_ssl_earliest_cert_expiry{job=\"blackbox-https\"}) - time() < 14 * 86400"
        for         = "1h"
        labels      = { severity = "warning" }
        annotations = { summary = "TLS certificate of {{ $labels.instance }} expires in {{ $value | humanizeDuration }}: is the certs renewal running?" }
      },
      {
        alert       = "TLSCertExpiryCritical"
        expr        = "min by (instance) (probe_ssl_earliest_cert_expiry{job=\"blackbox-https\"}) - time() < 3 * 86400"
        for         = "10m"
        labels      = { severity = "critical" }
        annotations = { summary = "TLS certificate of {{ $labels.instance }} expires in {{ $value | humanizeDuration }}" }
      },
    ]
  }])
}
