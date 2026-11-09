# services/monitoring

Renders the monitoring stack for one backend VM, any number of Grafana VMs and
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
- `templates/container.tftpl`: a generic Quadlet `.container` unit.
- `templates/config.alloy.tftpl`, `keepalived.conf.tftpl`, `haproxy.cfg.tftpl`,
  `logging-guard.nft.tftpl`, `logging-guard.service`: the logging configs.
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
  monitoring stack). `Overview/overview.json` is set as Grafana's home dashboard.
  See the root README's [Dashboards](../../../roots/monitoring-config/README.md#dashboards).

Outputs: `backend_deployment`, `grafana_deployments` and `logging_deployments`
(sensitive: they embed secrets), plus `prometheus_config`, `prometheus_rules`,
`datasources_config`, `dashboard_providers_config`, `dashboards`, `units`,
`backend_services`, `loki_configs`, `alloy_configs`, `haproxy_configs` and `loki_url`
for review and tests.
