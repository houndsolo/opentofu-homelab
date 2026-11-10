# services/monitoring

Renders the monitoring stack for the backend VMs (a primary with Postgres and replicas), any number of Grafana VMs and
the logging VMs (Loki HA), and outputs one self-contained `deploy.sh` per VM. It has no providers and
changes nothing itself. The [monitoring-config](../../../roots/monitoring-config/README.md)
root runs the scripts over SSH and documents the behaviour.

- `main.tf`: Prometheus, Alertmanager, blackbox, pve-exporter, Grafana
  datasource and dashboard-provider configs (built as HCL objects and `yamlencode`d), the Quadlet
  units, and the file/directory/validation/health lists for each VM.
- `logging.tf`: the logging VMs (`var.logging`): Loki config per VM (ring on the HA
  address), ruler rules, haproxy (S3 -> RGWs), keepalived, the nftables guard, their
  units and `deploy.sh`; Alloy for every VM (journal, plus the syslog receiver on the
  logging VMs); the `loki`/`alloy`/`haproxy` scrape jobs, the `logging` alert group and
  the Loki datasource, which `main.tf` merges in.
- `metrics.tf`: the Mimir VMs (`var.metrics`; empty or `metrics_secrets = null` leaves Mimir
  out): Mimir config per VM (rings and memberlist on the HA address, HA tracker, limits, S3 via
  haproxy), haproxy, keepalived (VIP), the nftables guard (`metrics-guard`), their units and
  `deploy.sh`; the `mimir`/`haproxy-mimir` scrape jobs and the `metrics` alert group (merged in
  `main.tf`), and the `mimir_remote_write`, `mimir_query_url` and `mimir_datasource_json` locals
  that `main.tf` uses for Prometheus' `remote_write` and Grafana's `prometheus` datasource.
- `postgres.tf`: the Patroni cluster (`var.postgres`; empty or `postgres_secrets = null` leaves it out):
  Patroni and etcd configs per member (HA VLAN), pgBackRest (S3 via a TLS haproxy), keepalived on Patroni's
  `/primary` (VIP), the nftables guard (`postgres-guard`), the leader-setup and backup scripts/units, their
  `deploy.sh` (Debian packages for Postgres/Patroni/etcd/pgBackRest, containers for the exporters); the
  `patroni`/`etcd`/`postgres`/`haproxy-postgres` scrape jobs and the `postgres` alert group, and
  `grafana_db_host`/`grafana_db_env`/`legacy_postgres`, which `main.tf` uses for Grafana's database and
  mon01's Postgres container (`postgres_settings.grafana_on_cluster` / `legacy_on_primary`).
- `rgw.tf`: the `ceph-rgw-buckets` alert group (`var.rgw_bucket_alerts`; only with `targets.ceph`) on the
  per-bucket RGW metrics from `roots/monitoring-config/pve-collectors` (dashboard `dashboards/rgw.py`).
- `backends.tf`: backend HA (`var.backends`, `primary_backend`): the Alertmanager cluster (gossip on the
  HA VLAN), keepalived and its VIPs (`backend_vrrp`, with `ip_nonlocal_bind` so containers publish on the
  VIPs), the InfluxDB write relay (`influx_relay`: Telegraf copying writes into every backend's InfluxDB),
  their scrape job and the `monitoring-ha` alert group. `main.tf` renders every backend's units and
  `deploy.sh` (Postgres on the primary only) and one `prometheus.yml` per backend (`__replica__`).
- `templates/monitoring-keepalived.conf.tftpl`: the backends' VRRP instance.
- `telemetry.tf`: Telegraf on the backend (`var.wlc_telemetry`; null leaves it out): the
  C9800 WLCs' model-driven telemetry (gRPC dial-out) into an InfluxDB bucket, its unit,
  `telegraf.conf`, env file (write token), config check, health checks, the `telegraf`
  scrape job and the `wlc-telemetry` alert group, which `main.tf` merges in. With two or more
  Telegraf backends and keepalived it fans out: every Telegraf also listens on the monitoring
  VIP (the WLCs' one receiver) and writes the bucket on every backend's InfluxDB.
- `templates/container.tftpl`: a generic Quadlet `.container` unit.
- `templates/config.alloy.tftpl`, `keepalived.conf.tftpl`, `haproxy.cfg.tftpl`,
  `logging-guard.nft.tftpl`, `logging-guard.service`: the logging configs (`haproxy.cfg.tftpl` is
  shared with the Mimir VMs); `metrics-keepalived.conf.tftpl`, `metrics-guard.nft.tftpl`,
  `metrics-guard.service`: the Mimir VMs' configs.
- `templates/monitoring.network`: the backend's Podman bridge network.
- `templates/deploy.sh.tftpl`: unpack, pull, validate, install changed files,
  prune files that are no longer managed (dashboards), restart/start/reload
  services, health-check. Optional Debian `packages` (installed in deploy mode
  only) and `post_install` commands (after `daemon-reload`). `deploy.sh check`
  stops after validation.
- `dashboards/<Folder>/*.json`: Grafana dashboards. They're minified, which also
  checks the JSON, and installed on every Grafana VM under
  `provisioning/dashboards/files`, with a file provider (`dashboards.yml`) that
  makes each subdirectory a folder. `dashboards/update.py` downloads the pinned
  grafana.com revisions and adapts them to the provisioned datasource;
  `dashboards/custom.py` generates the custom ones (overview, FRR/EVPN, probes,
  monitoring stack, Ceph, and through `pve.py`, `fwwan.py`, `logs.py` and `wireless.py` the
  Proxmox, fw-wan, log and C9800 wireless dashboards). `Overview/overview.json` is set as Grafana's home dashboard.
  See the root README's [Dashboards](../../../roots/monitoring-config/README.md#dashboards).

Outputs: `backend_deployments`, `grafana_deployments` and `logging_deployments`
(sensitive: they embed secrets), plus `prometheus_config`, `prometheus_rules`,
`prometheus_configs`, `backend_services_by_host`, `backend_url_hosts`, `backend_vips`,
`backend_keepalived_configs` (sensitive), `influx_relay_configs`, `wlc_telegraf_configs`, `wlc_receiver`, `alertmanager_targets`, `datasources_config`, `dashboard_providers_config`, `dashboards`, `units`,
`backend_services`, `loki_configs`, `alloy_configs`, `haproxy_configs` and `loki_url`
for review and tests. Mimir: `metrics_deployments` and `mimir_keepalived_configs` (sensitive),
`mimir_configs`, `mimir_haproxy_configs`, `mimir_url`.
