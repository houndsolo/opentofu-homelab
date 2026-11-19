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
  prometheus        = { image = "docker.io/prom/prometheus", version = "v3.16.0" }
  alertmanager      = { image = "docker.io/prom/alertmanager", version = "v0.35.0" }
  blackbox_exporter = { image = "docker.io/prom/blackbox-exporter", version = "v0.29.1" }
  snmp_exporter     = { image = "docker.io/prom/snmp-exporter", version = "v0.31.0" }
  pve_exporter      = { image = "docker.io/prompve/prometheus-pve-exporter", version = "3.11.0" }
  telegraf          = { image = "docker.io/library/telegraf", version = "1.40.3" }

  # Grafana, metrics and logs (monitoring-config)
  grafana = { image = "docker.io/grafana/grafana", version = "13.3.1" }
  mimir   = { image = "docker.io/grafana/mimir", version = "3.2.5" } # classic architecture (no Kafka)
  loki    = { image = "docker.io/grafana/loki", version = "3.7.10" }
  haproxy = { image = "docker.io/library/haproxy", version = "3.2.26" } # LTS branch

  # Postgres (monitoring-config); the database itself is a Debian package, see packages below
  postgres_exporter = { image = "quay.io/prometheuscommunity/postgres-exporter", version = "v0.20.1" }

  # On every VM (both roots)
  node_exporter = { image = "docker.io/prom/node-exporter", version = "v1.12.1" }
  alloy         = { image = "docker.io/grafana/alloy", version = "v1.22.0" } # PVE nodes: pve-alloy-install.sh (.deb)

  # Services (services-config)
  bind9 = { # BIND 9.20.30 (named -v); ISC moves the 9.20 tag, the digest pins this build
    image   = "docker.io/internetsystemsconsortium/bind9"
    version = "9.20"
    digest  = "sha256:66092edb53c081fa11b1fa8219e99065b0f497cb38f568ba789702a4c10e2590"
  }
  bind_exporter  = { image = "docker.io/prometheuscommunity/bind-exporter", version = "v0.8.0" }
  nginx          = { image = "docker.io/library/nginx", version = "1.30.6" } # nginx stable
  nginx_exporter = { image = "docker.io/nginx/nginx-prometheus-exporter", version = "1.5.3" }
  freeradius     = { image = "docker.io/freeradius/freeradius-server", version = "3.2.10", digest = "sha256:337856ea35b77472f15dad159064ce46219a54b499bef5f6a7cba38aefd39fe9" } # Ubuntu-based; 3.2 = the stable line
  netbox         = { image = "docker.io/netboxcommunity/netbox", version = "v4.7.5-5.1.2" }
  nextcloud      = { image = "docker.io/library/nextcloud", version = "35.0.3-fpm" } # php-fpm variant (Debian trixie, PHP 8.5); one major at a time
  redis_exporter = { image = "docker.io/oliver006/redis_exporter", version = "v1.97.0" }
  forgejo        = { image = "codeberg.org/forgejo/forgejo", version = "17.0.2-rootless" }     # rootless image (uid 1000); forgejo.tf (git01/git02)
  sonarr         = { image = "lscr.io/linuxserver/sonarr", version = "4.0.20.3014-ls5" }       # arr.tf (arr01)
  radarr         = { image = "lscr.io/linuxserver/radarr", version = "7.0.3.10918-ls328" }     # arr.tf
  prowlarr       = { image = "lscr.io/linuxserver/prowlarr", version = "2.7.0.5723-ls168" }    # arr.tf
  bazarr         = { image = "lscr.io/linuxserver/bazarr", version = "v1.6.2-ls372" }          # arr.tf
  jellyfin       = { image = "docker.io/jellyfin/jellyfin", version = "12.4.20261026-211555" } # arr.tf
  seerr          = { image = "docker.io/seerr/seerr", version = "v3.5.2" }                     # arr.tf (Jellyseerr's successor)
  whisparr = {                                                                                 # Whisparr 3.6.5-release.1886 (arr.tf); hotio moves the v3 tag, the digest pins this build
    image   = "ghcr.io/hotio/whisparr"
    version = "v3"
    digest  = "sha256:6aa104ae061a577e733966276a2f7fd161990ed64611168c042d58b905c9fb49"
  }
  openbao = { image = "quay.io/openbao/openbao", version = "2.7.2" } # openbao.tf (bao01-03)
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
