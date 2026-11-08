# monitoring-config

This root deploys the monitoring stack onto the VMs that
[services-vms](../services-vms/README.md) creates with `role = "monitoring"`
(one backend) and `role = "grafana"` (any number of front ends). It uses the
same mechanism as BIND in [services-config](../services-config/README.md#how-bind-is-deployed):
OpenTofu SSHes to each VM and runs a generated `deploy.sh`, which installs
**Podman Quadlet** units, so every container is an ordinary systemd service.
No compose tool is needed. The VM image already has Podman.

The rendering lives in [modules/services/monitoring](../../modules/services/monitoring/);
this root picks the VMs, derives the scrape targets from the inventory,
generates the secrets and does the SSH deployment.

## What runs where

| VM | Services (systemd units) | Listens on |
| --- | --- | --- |
| backend (mon01) | `prometheus`, `alertmanager`, `influxdb` | monitoring network (`10.5.11.30`) and backend VLAN (`10.13.11.30`): 9090, 9093, 8086 |
| | `postgres` (shared Grafana database) | backend VLAN only: `10.13.11.30:5432` |
| | `snmp-exporter`, `blackbox-exporter`, `pve-exporter` | not published; Prometheus reaches them by name on the `monitoring` Podman network |
| | `node-exporter` | `10.5.11.30:9100` |
| | `monitoring-network` | the Podman bridge network itself |
| grafana VMs (graf01/02) | `grafana` | 3000 on every address (VLAN 2 for users; a future VIP), 9094 (alerting HA gossip) on the backend VLAN |
| | `node-exporter` | backend VLAN address, port 9100 |

The **backend VLAN** (VLAN 13, 10.13.0.0/16, VRF `lylat_monitor`) is isolated:
it routes to no other VRF. Grafana uses it for its datasources, its Postgres
database and alerting HA. The **monitoring network** (vmbr100, 10.5.0.0/16) is
where you open the Prometheus/Alertmanager/InfluxDB UIs and where the Proxmox
nodes push metrics.

Both Grafana VMs share one Postgres database, so users, sessions, dashboards
and alert state are the same on either. Datasources and [dashboards](#dashboards)
are provisioned from files, so a rebuilt VM comes back identical. Grafana's unified alerting peers over the
backend VLAN, so an alert isn't sent twice. There is no VIP yet (keepalived is a
later step).

## How a deployment works

There's one `terraform_data` per VM: `terraform_data.backend["mon01"]` and
`terraform_data.grafana["graf01"]`/`["graf02"]`. The Grafana ones wait for the
backend. Each uploads `deploy.sh` to a private `/tmp` directory, runs it with
`sudo -n`, and deletes it. The script:

1. Unpacks its embedded files into a private staging directory.
2. Pulls the images.
3. **Validates** in throwaway containers with no network: `promtool check config`
   (with the rules), `amtool check-config`, and the blackbox exporter's
   `--config.check`. A broken config never gets installed.
4. Creates the directories. Data directories are owned by the user each image
   runs as (looked up from the image), so non-root containers can write them.
   Postgres and InfluxDB start as root and drop to their `postgres`/`influxdb`
   user, so their data directories are owned by that user, looked up in the image
   (their entrypoints only fix ownership when the container starts, so any other
   owner would lock out a server this deployment doesn't restart).
5. Installs only files that changed (content, mode or owner), and records which
   services those files belong to. Under the dashboards directory, files that are
   no longer in the module are deleted.
6. Stops and removes Quadlet units it used to manage but no longer does (for
   example, `pve-exporter` after you remove the token).
7. Runs `systemctl daemon-reload`, then for each service in order:
   **restarts** it if its unit, env file or a restart-type config changed;
   **starts** it if it isn't running; **reloads** it (SIGHUP) if only a
   reloadable config changed. Prometheus, Alertmanager and blackbox reload, so
   editing scrape targets doesn't restart Prometheus.
8. Waits up to two minutes for every service to be active and for its health
   checks (`/-/ready`, `/health`, `pg_isready`, Grafana `/api/health`) to pass.
   If not, it prints the failing units' journal and exits non-zero.

`deploy.sh check` runs steps 1–3 and lists the files that would change or be
removed, without installing anything. If `deploy.sh` fails, the apply fails and
the `terraform_data` resource is tainted, so the next apply retries it.

**When it redeploys:** whenever a rendered file or image changes, or the VM's
management address, VM ID or `ssh_username`, or `deploy_revision`. Secrets are
part of the rendered files, but they're generated once and kept in state.

### What ends up on the VMs

| Path | What it is |
| --- | --- |
| `/etc/containers/systemd/*.container`, `monitoring.network` | The Quadlet units (`<name>.service`) |
| `/etc/monitoring/prometheus/prometheus.yml`, `rules/basic.yml` | Prometheus config and alert rules |
| `/etc/monitoring/alertmanager/alertmanager.yml` | Alertmanager config |
| `/etc/monitoring/blackbox/config.yml` | Blackbox modules: `icmp`, `http_2xx`, `dns_soa` |
| `/etc/monitoring/pve-exporter/pve.yml` | PVE API token (mode 0640, only with a token) |
| `/etc/monitoring/influxdb.env`, `postgres.env` | Initial credentials (mode 0600) |
| `/var/lib/monitoring/{prometheus,alertmanager,influxdb,postgres}` | Data |
| `/etc/grafana-container/provisioning/datasources/datasources.yml` | Grafana datasources (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/dashboards.yml` | Grafana dashboard provider (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/files/<Folder>/*.json` | Provisioned dashboards (graf VMs) |
| `/etc/grafana-container/grafana.env` | Grafana secrets (mode 0600) |
| `/var/lib/grafana-container` | Grafana plugins/cache; real state is in Postgres |

Logs: `journalctl -u prometheus` (and so on). Status: `systemctl status prometheus`.

## Scrape targets

They come from the same inventory the other roots use. Adding a node, leaf or
service VM updates Prometheus on the next apply.

| Job | Targets | From |
| --- | --- | --- |
| `node` | backend (monitoring address), grafana VMs (backend VLAN), DNS VMs (mgmt), Proxmox nodes (`cidrhost(vmbr100 prefix, id)`) | `vms`, `nodes`, `pve_network` |
| `vyos-node` (:9100), `vyos-frr` (:9342) | every leaf (mgmt), DHCP VMs (mgmt), `vyos_extra_targets` (fw-wan) | `fabric`, `nodes`, `vms` |
| `snmp-<name>` | `snmp_targets`: FS switches, CRS317s and spines on their monitoring-network (10.5/16) addresses, where the MikroTiks bind their SNMP agent; the C9800 WLCs (10.5.1.1/.2) over SNMPv3 (`snmp_v3_auths`) | variables |
| `pve` | cluster nodes' API, through pve-exporter (only with a token; standalone greatfox is left out) | `nodes` |
| `blackbox-icmp`, `blackbox-http_2xx` | `blackbox_icmp_targets`, `blackbox_http_targets` | variables |
| `blackbox-dns_soa` | each DNS VM's service address, `SOA lylat.space` | `vms` |
| `grafana` | each Grafana VM's `/metrics` on the backend VLAN | `vms` |

Most targets **don't run an exporter yet**, so they show as down (`up == 0`)
until they do. See [Next steps](#next-steps).

## Dashboards

Dashboards are JSON files in
[modules/services/monitoring/dashboards](../../modules/services/monitoring/dashboards/).
Each subdirectory becomes a Grafana folder. A file provider loads them, so:

- **Adding or changing a JSON file needs no restart.** Grafana polls the
  directory every 30 s. Only a change to the provider file restarts Grafana.
- **Deleting a file deletes the dashboard.** `deploy.sh` removes JSON files the
  module no longer has.
- **The UI can't save over them** (`allowUiUpdates: false`). You can still edit a
  panel to explore, or "Save as" a copy. Permanent changes go into the JSON.
- Both Grafanas provision the same files into the shared database. Grafana
  compares checksums, so they don't overwrite each other.

| Folder | Dashboard (uid) | Source | Shows |
| --- | --- | --- | --- |
| Network | SNMP Device Summary (`snmp-device-summary`) | [grafana.com 12489](https://grafana.com/grafana/dashboards/12489) rev 5 | Per device: interfaces up/down, top talkers, traffic on all interfaces, interface table (uptime for jobs with the `system` module) |
| Network | SNMP Interface Detail (`snmp-interface-detail`) | [grafana.com 12492](https://grafana.com/grafana/dashboards/12492) rev 4 | Per interface: status, speed, traffic, unicast/multicast/broadcast packets, errors, discards |
| Network | Mikrotik monitoring (`mikrotik-snmp`) | [grafana.com 14420](https://grafana.com/grafana/dashboards/14420) rev 9 | MikroTik `mikrotik` module: board/firmware, CPU temperature, per-interface traffic and Ethernet error counters, interface table, neighbors (MNDP/LLDP) |

The first two need only `if_mib`, so they work for every SNMP job. A dropdown in
the top bar ("SNMP dashboards") switches between them and keeps the selected
device and time range. The device picker shows each target's `host` label.

Some Mikrotik monitoring panels stay empty here. CPU load, RAM, disk, uptime,
model and identity need the `hrDevice`, `hrStorage` and `system` modules, which
the MikroTik jobs in `snmp_targets` don't include. The Wi-Fi, CAPsMAN, 60 GHz,
PoE and queue panels don't apply to CRS switches.

To update or add a community dashboard, edit the list in
[`dashboards/update.py`](../../modules/services/monitoring/dashboards/update.py)
and run `python3 -I modules/services/monitoring/dashboards/update.py`. The script
downloads the pinned revision and points every query at the provisioned
Prometheus datasource (uid `prometheus`). It also drops the import-time
datasource inputs and variables, and sets the device picker, uid, tag and links.
Review the diff, then apply. File and folder names must not contain spaces.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Key for `config.ssh_username` on the VMs (needs passwordless sudo) |
| `deploy_revision` | `"1"` | Change to force a redeploy, e.g. after rebuilding a VM |
| `backend_vlan_id` | `13` | VLAN whose NIC address Grafana and Postgres use |
| `monitoring_bridge` | `vmbr100` | Bridge of the backend's monitoring-network NIC |
| `pve_monitoring_bridge` | `"100"` | `pve_network.bridges` key for the Proxmox nodes' scrape addresses |
| `images` | pinned tags | Container images; override one key at a time |
| `settings` | see `variables.tf` | Prometheus retention (90d / 120GB), InfluxDB org/bucket/retention, Grafana root URL, DNS probe zone |
| `pve_exporter_token` | `null` | PVE API token; `null` leaves pve-exporter out |
| `grafana_admin_password`, `influxdb_admin_password` | `null` (generated) | Fixed UI passwords; set them in a git-ignored `*.secret.auto.tfvars`. Only used when Grafana/InfluxDB first initialise. InfluxDB needs 8+ characters |
| `snmp_v3_auths` | `{}` | SNMPv3 credentials for snmp_exporter (git-ignored `*.secret.auto.tfvars`); written to `/etc/monitoring/snmp-exporter/auths.yml` and loaded as a second exporter config file. The WLCs' `lylat_v3` lives here |
| `vyos_extra_targets`, `node_extra_targets`, `snmp_targets`, `blackbox_icmp_targets`, `blackbox_http_targets` | see `variables.tf` | Targets outside the inventory |

## Running it

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config init'
nix-shell --run 'tofu -chdir=roots/monitoring-config plan'
nix-shell --run 'tofu -chdir=roots/monitoring-config apply'
tofu -chdir=roots/monitoring-config output -raw grafana_admin_password
```

Then open Grafana on `http://10.2.11.31:3000` (or `.32`) as `admin`, and
Prometheus on `http://10.5.11.30:9090`.

### Optional: the PVE exporter token

On a cluster node:

```sh
pveum user add prometheus@pve
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token add prometheus@pve exporter --privsep 0
```

Put the token in `roots/monitoring-config/pve.secret.auto.tfvars` (Git ignores
`*.secret.auto.tfvars`):

```hcl
pve_exporter_token = { user = "prometheus@pve", token_name = "exporter", value = "<uuid>" }
```

## Things to know

- **InfluxDB and Postgres read their credentials only on first start**, when
  their data directories are empty. The generated values never change, but if
  you replace the `random_password` resources, wipe the data directories too.
- **Grafana uses the InfluxDB operator token for now** (`influxdb_admin_token`
  output). Replace it with a read-only token later.
- **Alertmanager routes everything to a `null` receiver.** Alerts are visible in
  Alertmanager and Grafana but not sent anywhere until you add a receiver.
- **Postgres is reachable only on the backend VLAN**, which no other VRF routes to.
- **The Proxmox metric server isn't configured here.** Point it at
  `influxdb_url` (InfluxDB, HTTP, org `lylat`, bucket `proxmox`, token from
  `influxdb_admin_token`).

## Next steps

1. Exporters on the remaining targets: `prometheus-node-exporter` on the
   Proxmox nodes and DNS VMs, and node/frr exporters on fw-wan (not managed by
   this repo). The leaves get theirs from `fabric.settings.leaf_prometheus_exporters`
   (fabric-leaves) and the DHCP VMs from `dhcp_prometheus_exporters`
   (services-config).
2. Proxmox metric server → InfluxDB.
3. keepalived VIP for Grafana on the backend VLAN.
4. More dashboards (node exporter, VyOS/FRR, blackbox, Proxmox) under
   `modules/services/monitoring/dashboards/`.

## Tests

`tests/monitoring.tftest.hcl` plans against the real inventory with a mocked
`random` provider. It checks the derived targets and URLs, that pve-exporter
appears only with a token (and the token stays out of `prometheus.yml`), the
unit contents (Postgres bound to the backend VLAN, Grafana HA peers), the
Postgres/InfluxDB data-directory owners, the dashboard provider and files (every
query uses the provisioned Prometheus datasource, no import-time placeholders,
no restart for JSON changes, stale files pruned), and that a missing backend NIC
fails the plan.

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config test'
```
