# services/monitoring

Renders the monitoring stack for one backend VM and any number of Grafana VMs,
and outputs one self-contained `deploy.sh` per VM. It has no providers and
changes nothing itself. The [monitoring-config](../../../roots/monitoring-config/README.md)
root runs the scripts over SSH and documents the behaviour.

- `main.tf`: Prometheus, Alertmanager, blackbox, pve-exporter and Grafana
  datasource configs (built as HCL objects and `yamlencode`d), the Quadlet
  units, and the file/directory/validation/health lists for each VM.
- `templates/container.tftpl`: a generic Quadlet `.container` unit.
- `templates/monitoring.network`: the backend's Podman bridge network.
- `templates/deploy.sh.tftpl`: unpack, pull, validate, install changed files,
  restart/start/reload services, health-check. `deploy.sh check` stops after
  validation.

Outputs: `backend_deployment` and `grafana_deployments` (sensitive: they embed
secrets), plus `prometheus_config`, `datasources_config`, `units` and
`backend_services` for review and tests.
