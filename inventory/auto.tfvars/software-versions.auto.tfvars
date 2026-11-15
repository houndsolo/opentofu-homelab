# Every pinned software version the OpenTofu roots deploy: container images and Debian packages. Change a version
# here, plan the roots named in the section, apply. Schema: inventory/schema/software-versions.tf.
#
# Not covered here: dark-triage (built on the VM from its git commit, var.ticketing.commit); the PVE nodes' Alloy (a
# .deb pinned by ALLOY_VERSION + ALLOY_SHA256 in roots/monitoring-config/log-senders/pve-alloy-install.sh, run by
# hand: keep it in step with containers.alloy); the OpenTofu providers (inventory/versions/).

# Container images: key = { image, version[, digest] }. version is the tag; digest (sha256:...) pins the exact image
# when the tag moves (BIND's "9.20" is the only tag ISC publishes). Plan services-config and monitoring-config:
# every VM running that container gets the new image on apply.
containers = {
  # Prometheus stack (monitoring-config)
  prometheus        = { image = "docker.io/prom/prometheus", version = "v3.15.1" }
  alertmanager      = { image = "docker.io/prom/alertmanager", version = "v0.34.1" }
  blackbox_exporter = { image = "docker.io/prom/blackbox-exporter", version = "v0.29.1" }
  snmp_exporter     = { image = "docker.io/prom/snmp-exporter", version = "v0.30.1" }
  pve_exporter      = { image = "docker.io/prompve/prometheus-pve-exporter", version = "3.10.2" }
  telegraf          = { image = "docker.io/library/telegraf", version = "1.40.3" }

  # Grafana, metrics and logs (monitoring-config)
  grafana = { image = "docker.io/grafana/grafana", version = "13.2.5" }
  mimir   = { image = "docker.io/grafana/mimir", version = "3.2.4" } # classic architecture (no Kafka)
  loki    = { image = "docker.io/grafana/loki", version = "3.7.9" }
  haproxy = { image = "docker.io/library/haproxy", version = "3.2.26" } # LTS branch

  # Postgres (monitoring-config); the database itself is a Debian package, see packages below
  postgres_exporter = { image = "quay.io/prometheuscommunity/postgres-exporter", version = "v0.20.1" }

  # On every VM (both roots)
  node_exporter = { image = "docker.io/prom/node-exporter", version = "v1.12.1" }
  alloy         = { image = "docker.io/grafana/alloy", version = "v1.21.3" } # PVE nodes: pve-alloy-install.sh (.deb)

  # Services (services-config)
  bind9 = { # BIND 9.20.30 (named -v); ISC moves the 9.20 tag, the digest pins this build
    image   = "docker.io/internetsystemsconsortium/bind9"
    version = "9.20"
    digest  = "sha256:66092edb53c081fa11b1fa8219e99065b0f497cb38f568ba789702a4c10e2590"
  }
  bind_exporter  = { image = "docker.io/prometheuscommunity/bind-exporter", version = "v0.8.0" }
  nginx          = { image = "docker.io/library/nginx", version = "1.30.6" } # nginx stable
  nginx_exporter = { image = "docker.io/nginx/nginx-prometheus-exporter", version = "1.5.3" }
  netbox         = { image = "docker.io/netboxcommunity/netbox", version = "v4.7-5.1.1" }
  redis_exporter = { image = "docker.io/oliver006/redis_exporter", version = "v1.97.0" }
}

# Debian packages: name = version, the upstream version ("18.6" = any Debian revision of 18.6) or a full Debian version
# ("18.6-1.pgdg13+2"). Plan monitoring-config. A changed version is installed on apply (exactly the newest apt version
# that matches), but the running services keep the old binaries until they are restarted: finish with a rolling
# restart (runbook-postgres.md, "Minor upgrade"). Every deploy also fails if an installed version doesn't match.
packages = {
  # Patroni cluster on pg01-03. postgresql: PGDG postgresql-<major> + postgresql-client-<major>. Changing the MAJOR
  # (18 -> 19) is not an upgrade: it builds a new cluster (scope/stanza lylat-pg<major>, new data dir), then
  # dump/restore (README "Postgres HA", DT-046). Minor versions (18.6 -> 18.7) upgrade in place.
  postgresql = "18.6"   # PGDG
  patroni    = "4.1.5"  # PGDG; PostgreSQL 18 needs >= 4.1
  etcd       = "3.5.16" # Debian 13 (etcd-server + etcd-client)
  pgbackrest = "2.60.0" # PGDG
}
