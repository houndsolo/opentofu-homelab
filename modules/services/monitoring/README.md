# services/monitoring

Renders the monitoring stack for one backend VM and any number of Grafana VMs,
and outputs one self-contained `deploy.sh` per VM. It has no providers and
changes nothing itself. The [monitoring-config](../../../roots/monitoring-config/README.md)
root runs the scripts over SSH and documents the behaviour.

- `main.tf`: Prometheus, Alertmanager, blackbox, pve-exporter, Grafana
  datasource and dashboard-provider configs (built as HCL objects and `yamlencode`d), the Quadlet
  units, and the file/directory/validation/health lists for each VM.
- `templates/container.tftpl`: a generic Quadlet `.container` unit.
- `templates/monitoring.network`: the backend's Podman bridge network.
- `templates/deploy.sh.tftpl`: unpack, pull, validate, install changed files,
  prune files that are no longer managed (dashboards), restart/start/reload
  services, health-check. `deploy.sh check` stops after validation.
- `dashboards/<Folder>/*.json`: Grafana dashboards. They're minified, which also
  checks the JSON, and installed on every Grafana VM under
  `provisioning/dashboards/files`, with a file provider (`dashboards.yml`) that
  makes each subdirectory a folder. `dashboards/update.py` downloads the pinned
  grafana.com revisions and adapts them to the provisioned datasource. See the
  root README's [Dashboards](../../../roots/monitoring-config/README.md#dashboards).

Outputs: `backend_deployment` and `grafana_deployments` (sensitive: they embed
secrets), plus `prometheus_config`, `datasources_config`, `dashboard_providers_config`,
`dashboards`, `units` and `backend_services` for review and tests.
