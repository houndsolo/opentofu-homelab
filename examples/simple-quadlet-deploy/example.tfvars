hosts = {
  mon-test = { address = "192.0.2.10" }
}

images = {
  prometheus    = "docker.io/prom/prometheus:v3.16.0"
  grafana       = "docker.io/grafana/grafana:13.3.1"
  node_exporter = "docker.io/prom/node-exporter:v1.12.1"
}

scrape_targets = {
  node = ["192.0.2.10:9100"]
}

grafana_admin_password = "change-me"
