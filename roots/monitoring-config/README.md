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

Grafana's **home page** is the overview (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`
points at its provisioned file), until a user, team or org preference picks
another. Grafana serves that copy as `/d/default-home-dashboard`; the one in the
Overview folder (`lylat-overview`) is the same JSON. Every dashboard has a **Dashboards** dropdown in the top bar listing all
of them (they share the `lylat` tag); the overview shows them as buttons.

| Folder | Dashboard (uid) | Source | Shows |
| --- | --- | --- | --- |
| Overview | lylat.space overview (`lylat-overview`) | custom | Targets up/down (stats, per job, per target), firing alerts, Ceph health / raw used / client IOPS and throughput / OSDs down and PGs not clean (click through to Ceph cluster), probe status, BGP established/total and BFD up/total across the fabric, EVPN totals, a Proxmox row (PVE nodes up/down and guests over the cluster and greatfox, lylat CPU and memory, fullest storage; click through to Proxmox overview), an Edge row (fw-wan up, WAN in/out, VPN tunnels, firewall drops + rejects, conntrack; click through to the fw-wan dashboards), a host/router table (state, CPU, memory, disk, load, conntrack, uptime; click a host for Node Exporter Full), top 10 interfaces from node_exporter and SNMP |
| Hosts | Node Exporter Full (`node-exporter-full`) | [grafana.com 1860](https://grafana.com/grafana/dashboards/1860) rev 46 | Everything node_exporter collects, for one host. Pick the job (`node` for the VMs, `vyos-node` for the VyOS routers), then the host |
| Network | FRR / EVPN fabric (`frr-evpn-fabric`) | custom | BGP peer table (router, VRF, AFI/SAFI, peer, hostname, ASNs, state, uptime, prefixes rx/tx, message rates), session state timeline, established sessions per router, flaps in the time range, BFD peers, EVPN remote VTEPs/MACs/ARP-ND per router and per L2 VNI, routes per VRF, RIB vs FIB, BGP RIB, frr_exporter health. Router and VRF pickers |
| Network | SNMP Device Summary (`snmp-device-summary`) | [grafana.com 12489](https://grafana.com/grafana/dashboards/12489) rev 5 | Per device: interfaces up/down, top talkers, traffic on all interfaces, interface table (uptime for jobs with the `system` module) |
| Network | SNMP Interface Detail (`snmp-interface-detail`) | [grafana.com 12492](https://grafana.com/grafana/dashboards/12492) rev 4 | Per interface: status, speed, traffic, unicast/multicast/broadcast packets, errors, discards |
| Edge | fw-wan overview (`fw-wan-overview`) | custom (Prometheus + InfluxDB) | The VyOS edge router. **Status:** ICMP, exporters, uptime, WAN address, WAN in/out (sparklines), CPU, memory, conntrack table, BGP sessions, VPN tunnels, VyOS services, systemd units failed/restarting, firewall drops + rejects. **Traffic:** WAN (in up, out down), traffic per VRF (VRF devices), top interfaces with their VRF. **Firewall:** rule matches by action, drops + rejects per chain. **VPNs:** tunnel state timeline, VTI/WireGuard traffic. **System:** CPU by mode, memory, temperatures, softnet drops, load, units not active. Collapsed: interface table (VRF, description, state, MTU, speed, in/out, errors, drops), router syslog |
| Edge | fw-wan firewall (`fw-wan-firewall`) | custom (Prometheus + InfluxDB) | fw-wan's named IPv4 chains (Telegraf per-rule nftables counters): matches per second by action, drops + rejects and logged packets in range, conntrack usage, rules missing from the snapshot; chain activity timeline, packets and traffic per chain; rule table (chain, rule, action, match, packets/s, packets and bytes in range, totals), top rules, drops and rejects per rule, default actions hit, traffic dropped; conntrack entries, new connections, insert failures/drops/invalid; firewall log from the syslog (time, chain, rule, action, in/out, proto, addresses and ports) and logged packets per rule; collapsed rule and NAT reference |
| Edge | fw-wan VPNs (`fw-wan-vpn`) | custom (Prometheus + InfluxDB) | IPsec connections, IKE state, CHILD SAs, WireGuard peers, BGP over the tunnels, vpn-metrics.py health; SA state timeline, SA age, rekeys in range, CHILD SA traffic and packets; VTI/WireGuard interface traffic, errors and drops, link state, tunnel interface table; WireGuard handshake age and peer traffic; BGP peers in `vpn_*` VRFs, prefixes, routes; VPN firewall chains; collapsed strongSwan log |
| Edge | fw-wan VRFs & routing (`fw-wan-routing`) | custom | Router picker (default fw-wan, works for the leaves and DHCP VMs) and VRF picker: BGP/BFD summary, routes, VRFs, route changes, RIB not in FIB; routing table per VRF (IPv4/IPv6 RIB and FIB, BGP RIB, sessions up, changes), routes and route changes per VRF; BGP peer table (state, uptime, prefixes, messages, flaps), session state, BGP RIB, prefixes rx/tx, messages; traffic per VRF, interface traffic and table with the VRF (fw-wan); collapsed BFD peers and frr_exporter collectors |
| Network | Mikrotik monitoring (`mikrotik-snmp`) | [grafana.com 14420](https://grafana.com/grafana/dashboards/14420) rev 9 | MikroTik `mikrotik` module: board/firmware, CPU temperature, per-interface traffic and Ethernet error counters, interface table, neighbors (MNDP/LLDP) |
| Probes | Blackbox probes (`blackbox-probes`) | custom | ICMP/HTTP/DNS SOA probes: status, availability over the time range, duration, ICMP RTT and hop limit, HTTP status/phases (no TLS)/size, DNS query time, SOA serial and drift between the DNS servers |
| Monitoring | Monitoring stack (`monitoring-stack`) | custom | Component status and versions, config reloads; Prometheus targets per job, scrape duration, samples, head series, TSDB size, ingestion, rule evaluation, query latency; Alertmanager alerts, silences, notifications; Grafana requests, latency, datasource queries, DB connections, alerting; SNMP/FRR/node exporter scrape times; process memory and CPU |
| Storage | Ceph cluster (`ceph-cluster`) | custom | The PVE Ceph cluster at a glance. **Status:** health, active health checks and their history, raw used gauge, OSDs up/in/down/out, mons in quorum, active/standby mgr and MDS, PGs not clean, sparkline stats for client read/write IOPS, throughput and latency, recovery and objects at risk. **Capacity:** raw total/used/available, pool usage bars, data per pool (donut), fullest OSD and when it reaches nearfull, raw used forecast in 30 days, pool table (PGs, objects, stored, raw, % used, max available, 30-day forecast, IOPS), raw capacity with nearfull line and forecast. **Client I/O:** IOPS/throughput (reads up, writes down), OSD op latency, per pool. **PGs and recovery:** non-zero PG states, PGs not clean by state, scrubbing, recovery/backfill rate, degraded/misplaced/unfound objects, OSD flags. **OSDs:** colour status grid (host · OSD), OSD hosts table, OSD table (host, disk, model, state, reweight, PGs, size, used, apply/commit/read/write latency, IOPS, slow ops; click for Ceph OSD), state history, per-OSD commit/read/write latency, utilization, PGs, IOPS, throughput. **Slow ops and BlueStore:** BLUESTORE_SLOW_OP_ALERT, daemons with slow ops, slow ops per daemon, BlueStore slow ops per OSD (24 h, the alert's window), kv commit latency, BlueStore latency breakdown, fragmentation, onode cache hits, RocksDB size. Collapsed rows: **Monitors and managers** (quorum, sessions, elections, mgr roles and modules, daemon versions, paxos latency, mgr scrape targets), **CephFS** (active/standby MDS, clients, caps, files, requests, reply latency by op, cache, journal, pools), **OSD hosts** (node_exporter: CPU, memory, load, OSD disk busy % and await). **RBD images:** per-image IOPS/throughput/latency over the time range with the VM id parsed from the image name, top 10 images by IOPS, throughput and latency |
| Storage | Ceph OSD (`ceph-osd`) | custom | One OSD (picker): state, host, disk and model, class, used, size/PGs/reweight, apply/commit/read/write latency, slow ops; IOPS, throughput, op latency (total vs processing), ops in flight, recovery; BlueStore latency breakdown, slow-op counters, space, onode cache, fragmentation; scrubs; the disk from node_exporter |
| Storage | Ceph cluster advanced (mixin) (`ceph-cluster-advanced`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | The official cluster dashboard: health, capacity, throughput and IOPS, OSD/mgr/mon counts, firing alerts, per-pool usage, objects and quotas, PG states and stuck PGs, recovery, OSD apply/commit/read/write latency distributions (heatmaps), versions |
| Storage | Ceph OSDs overview (mixin) (`ceph-osds-overview`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | Read/write latency (avg, max, p95) and the slowest OSDs, OSD types and sizes, PGs per OSD, onode hit ratio, read/write profile, top slow ops |
| Storage | Ceph OSD device details (mixin) (`ceph-osd-device-details`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | One OSD: op latency and IOPS/throughput (the physical-device panels need node_exporter, see below) |
| Storage | Ceph pools overview (mixin) (`ceph-pools-overview`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | Pool count, raw capacity and consumption, logical stored, compression savings, pool table, top pools by client IOPS and bandwidth, raw usage per pool |
| Storage | Ceph pool details (mixin) (`ceph-pool-details`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | One pool: capacity used, time till full, object ingress/egress, client IOPS and throughput, objects |
| Storage | Ceph RBD overview (mixin) (`ceph-rbd-overview`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | RBD IOPS/throughput/latency totals and the top images |
| Storage | Ceph RBD details (mixin) (`ceph-rbd-details`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | One image: IOPS, throughput, latency |
| Storage | Ceph filesystem (mixin) (`ceph-filesystem`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | CephFS: metadata/data pool usage and I/O, MDS requests, sessions, caps, cache, journal, reply latency |
| Proxmox | Proxmox overview (`proxmox-overview`) | custom (InfluxDB) | **Cluster:** nodes up/down, guests (running VMs/CTs, stopped, templates), CPU and memory over all nodes (sparklines), vCPUs and memory allocated to running guests vs the nodes' cores and RAM. **Nodes:** table (state, uptime, CPU, cores, load per core, IO wait, memory, RAM, swap, root FS, guests, physical NIC in/out; click for Proxmox node). **Node trends:** CPU, memory, load per core, physical NIC traffic, IO wait per node. **Guests:** top 10 by CPU, memory, disk I/O and network, running guests over time, guest CPU per node. **Storage:** used % per storage (shared ones once) and over time |
| Proxmox | Proxmox node (`proxmox-node`) | custom (InfluxDB + Prometheus) | One node (picker): state, uptime, CPU/memory/swap/root FS gauges, load per core, guests, cores/RAM/swap/disk, node_exporter state (click for Node Exporter Full); CPU and IO wait, load averages vs cores; memory (used/available, ZFS ARC where there is one), swap, root FS; physical NICs, bridges and bonds, interface table; its guests (table, click for Proxmox guests; stacked CPU, memory, disk I/O and network); its storages; collapsed: temperatures and disk busy from node_exporter |
| Proxmox | Proxmox guests (`proxmox-guest`) | custom (InfluxDB) | Every guest on the selected nodes (table: type, node, status, uptime, vCPUs, CPU, memory used/configured, disk size, disk and net rates, tags), then one guest (picker by name, value = vmid): status, type, node, uptime, vCPUs, memory, disk size, tags, CPU/memory/balloon/CT root disk gauges, pressure (PSI), QEMU version and machine; CPU, memory (used, host, configured, balloon target), pressure; disk throughput, per-disk IOPS, latency and throughput, CT root disk, I/O errors; network total and per NIC; collapsed: balloon, guest page faults and swap |
| Proxmox | Proxmox storage (`proxmox-storage`) | custom (InfluxDB + Prometheus) | Used % per storage (shared ones once, local ones per node), count/inactive/fullest, Ceph health and raw used (click for Ceph cluster); storage table (type, shared, content, used, available, total, %, growth per day over the time range, when it's full at that rate; click: Ceph storages open Ceph cluster, local ones their node); used, used % and free over time; collapsed: local storage used per node. Storage picker |
| Proxmox | Proxmox cluster [Flux] (community) (`proxmox-cluster-flux`) | [grafana.com 15356](https://grafana.com/grafana/dashboards/15356) rev 14 | The most used PVE/InfluxDB 2 dashboard: per-node summary rows (repeated per server: CPU, cores, memory, swap, load, IO wait, storage pools), running VMs/LXCs, host CPU and memory, VM and LXC CPU, memory, disk I/O and traffic. Cluster (bucket) and server pickers |

The SNMP dashboards need only `if_mib`, so they work for every SNMP job. A dropdown
in the top bar ("SNMP dashboards") switches between them and keeps the selected
device and time range. The device and host pickers show each target's `host` label.
The Ceph dashboards (`ceph` tag) likewise share a "Ceph dashboards" dropdown.

The Proxmox dashboards (`proxmox` tag) read what `pvestatd` pushes to InfluxDB (see
[Things to know](#things-to-know)) through the provisioned InfluxDB datasource (uid
`influxdb`, Flux). A **Cluster** picker selects the bucket: `pve_cluster` (the lylat
cluster) or `pve_greatfox` (the standalone greatfox). They share a "Proxmox dashboards"
dropdown that carries the selected cluster, node and guest along (the community one
calls its picker `Bucket`, so it starts on the lylat cluster). Values shown "now" are the
newest sample within the last 2 minutes of the time range, so deleted or migrated guests
drop out; a node counts as down once it hasn't reported for a minute.

The fw-wan dashboards (`fw-wan` tag, folder Edge) share a "fw-wan dashboards" dropdown and
read Prometheus (jobs `vyos-node`, `vyos-frr`, `vyos-telegraf`, `blackbox-icmp`) plus the
syslog in the InfluxDB bucket `vyos` (firewall log, router log, strongSwan log). What a
firewall rule does isn't in the counters, so
[`dashboards/fwwan_snapshot.py`](../../modules/services/monitoring/dashboards/fwwan_snapshot.py)
holds chain/rule → action and match, interface → VRF and the NAT rules, read from fw-wan's
config by [`fwwan_config.py`](../../modules/services/monitoring/dashboards/fwwan_config.py)
(see [Changing the dashboards](#changing-the-dashboards)). The firewall dashboard's "Rules not
in snapshot" turns orange when fw-wan has rules the snapshot doesn't know.

The Ceph dashboards read the mgr prometheus module (job `ceph`) plus node_exporter on the
PVE nodes. Neither is managed by OpenTofu; this was done by hand on the cluster (2026-11-08):

```sh
# Once, on any PVE node: the mgr exporter (port 9283 on every mgr; only the active one
# returns metrics, standbys answer with an empty 200).
ceph mgr module enable prometheus
ceph config set mgr mgr/prometheus/exclude_perf_counters false  # per-daemon perf counters (no ceph-exporter on PVE)
ceph config set mgr mgr/prometheus/rbd_stats_pools ceph_rbd     # per-image (per VM disk) RBD stats

# On each Ceph node: node_exporter (:9100, job `node`, role `proxmox`) with the SMART
# textfile collector (prometheus-node-exporter-smartmon.timer, every 15 min).
apt-get install -y --no-install-recommends prometheus-node-exporter prometheus-node-exporter-collectors
```

`ceph_mgr_nodes` lists the mgr hosts to scrape; update it if mgrs move. `ceph-exporter`
is deliberately not used: the perf counters come from the mgr instead, and PVE's package
crash-loops on the keyring path (PVE bug 6816).

Panels that stay empty, and why:

- **Node Exporter Full:** swap (none configured), zswap, processes/PIDs/threads,
  systemd, TCP connection states, IRQ detail, CPU frequency and throttling,
  EDAC, power supply, fans and cooling. These need node_exporter collectors that
  aren't enabled (`processes`, `systemd`, `tcpstat`, `interrupts`) or hardware a VM
  doesn't have. On VyOS, "Root FS" is empty because the overlay root isn't
  reported; the persistence partition shows under the filesystem panels.
  Temperatures show only for the bare-metal leaves (leaf-18, leaf-19, leaf-42);
  the other routers are VMs without hwmon sensors.
- **Mikrotik monitoring:** CPU load, RAM, disk, uptime, model and identity need the
  `hrDevice`, `hrStorage` and `system` modules, which the MikroTik jobs in
  `snmp_targets` don't include. The Wi-Fi, CAPsMAN, 60 GHz, PoE and queue panels
  don't apply to CRS switches.
- **FRR / EVPN fabric:** "Flaps per session in range" says "No BGP flaps in range"
  when there were none.
- **Ceph cluster / Ceph OSD:** PG states, "PGs not clean, by state", slow ops per
  daemon, BlueStore slow ops and scrub bars only show something when it's non-zero.
  The forecasts (fullest OSD nearfull in, raw used in 30 days, pool "Stored in 30 d")
  use 7 days of history and are rough until Prometheus has that much; "Fullest OSD
  nearfull in" says "not filling up" when the fullest OSD isn't growing. CephFS
  reply latency and per-op request latency are empty while the MDS is idle.
  "OSD hosts", "OSD disk utilization/await" and the Ceph OSD "Disk" row need
  node_exporter on the PVE nodes (job `node`, role `proxmox`); they join it on
  `host` = PVE hostname and `device` = the OSD's disk from `ceph_disk_occupation`.
- **Ceph mixin dashboards:** the physical-device panels of "OSD device details" join
  node_exporter on `instance` (ours is `host:port`), so they stay empty even with
  node_exporter; use the Ceph OSD dashboard instead. Compression panels are empty
  (no pool uses compression); "PGs State" Unclean/Backfill and the filesystem's
  "Pool storage" raw used query metrics Ceph 20 no longer exports; MDS CPU/open
  requests need the mgr `stats` module (disabled); RGW versions are empty (no RGW);
  the OSD size buckets skip 10-12 TB, where these 10.9 TiB OSDs fall.
- **fw-wan dashboards:** Telegraf only exports counters for the named chains, not for the
  base input/forward filter rules or NAT, so those have no panels (the rule reference lists
  NAT). There's no OSPF anywhere and no BFD on fw-wan. Firewall log panels show only rules
  with `log` (deny_data 22 and 23). Road-warrior WireGuard peers and the VPS IPsec
  connection are DOWN while not connected, and "Rekeys in range" counts a reconnect too.
  The VRF column of the interface tables is fw-wan only (from the snapshot).
- Hosts without an exporter yet (DNS VMs, the standalone greatfox) show as DOWN in
  the target tables and are left out of everything else.
- **Proxmox dashboards:** the PVE metric servers started writing on 2026-11-09, so trends,
  growth and "Full in" need a few days of history to mean much. PVE reports no disk usage
  inside VMs (`disk` is 0 without a guest agent query), so "Root disk (CT)" and "Root disk
  used (CT)" are containers only, and the per-disk IOPS/latency, per-NIC, QEMU, balloon and
  "I/O errors" panels are VMs only (container NICs are veths on the node). Latency and the
  top-guest disk/network bars are empty while nothing does I/O. The balloon page-fault and
  swap panels need the guest's balloon driver to report stats (empty for the C9800 WLCs).
  There is no KSM or per-node pressure data in pvestatd's output, and no ZFS on the cluster
  nodes (ARC stays hidden). node_exporter panels on the node dashboard are empty for
  greatfox (no exporter). In the community dashboard, the LXC panels are empty for nodes
  without running containers.

### Changing the dashboards

- **Community dashboards:** edit the list in
  [`dashboards/update.py`](../../modules/services/monitoring/dashboards/update.py)
  and run `python3 -I modules/services/monitoring/dashboards/update.py`. The script
  downloads the pinned revision (grafana.com revision, or the ceph-mixin commit
  `CEPH_MIXIN_COMMIT` on the tentacle branch) and points every query at the provisioned
  Prometheus datasource (uid `prometheus`; InfluxDB ones at uid `influxdb`, with the
  bucket picker limited to the PVE buckets). It also drops the import-time
  datasource inputs and variables, and sets the host picker, uid, tags and links.
- **Custom dashboards:** edit
  [`dashboards/custom.py`](../../modules/services/monitoring/dashboards/custom.py)
  and run `python3 -I modules/services/monitoring/dashboards/custom.py`. It writes
  the JSON offline. Don't edit the generated JSON by hand. The Proxmox dashboards' builders
  (Flux queries) live in [`dashboards/pve.py`](../../modules/services/monitoring/dashboards/pve.py),
  which `custom.py` imports and runs; the fw-wan ones' in
  [`dashboards/fwwan.py`](../../modules/services/monitoring/dashboards/fwwan.py). After
  changing fw-wan's firewall, NAT, interfaces or VRFs, refresh the snapshot first (reads the
  config over `ssh vyos@10.20.10.255`, keeps only those paths) and commit both:
  `python3 -I modules/services/monitoring/dashboards/fwwan_config.py`, then `custom.py`.

Review the diff, then apply. File and folder names must not contain spaces.

## fw-wan (VyOS edge router, configured by hand)

fw-wan isn't managed by this repo, so its monitoring was set up by hand (2026-11-09).
Prometheus scrapes it through `vyos_extra_targets` (node :9100 and FRR :9342 on the
mgmt VRF, 10.20.10.255) and `vyos_telegraf_targets` (job `vyos-telegraf`, :9273 on
`lylat_service`, 10.5.0.255). Telegraf also writes to the InfluxDB bucket `vyos`
(`telegraf.tf`): VyOS only enables its exec inputs, including the per-rule nftables
counters (`nftables_pkts`/`nftables_bytes{chain,ruleid}`), when the influxdb output
is set. [`vyos/vpn-metrics.py`](vyos/vpn-metrics.py) runs every minute from the task
scheduler and writes IPsec (VICI) and WireGuard state to node_exporter's textfile
collector (`vyos_ipsec_*`, `vyos_wireguard_*`).

```
set service monitoring prometheus node-exporter listen-address '10.20.10.255'
set service monitoring prometheus node-exporter vrf 'mgmt'
set service monitoring prometheus node-exporter collectors textfile
set service monitoring prometheus frr-exporter listen-address '10.20.10.255'
set service monitoring prometheus frr-exporter vrf 'mgmt'
set service monitoring prometheus frr-exporter collector bgp-l2-vpn
set service monitoring prometheus frr-exporter collector bgp peer-hostname
set service monitoring prometheus frr-exporter collector bgp peer-description 'plain-text'
set service monitoring prometheus frr-exporter collector bgp peer-type
set service monitoring telegraf vrf 'lylat_service'
set service monitoring telegraf influxdb url 'http://10.5.11.30'
set service monitoring telegraf influxdb port '8086'
set service monitoring telegraf influxdb bucket 'vyos'
set service monitoring telegraf influxdb authentication organization 'lylat'
set service monitoring telegraf influxdb authentication token '<tofu output -raw vyos_telegraf_token>'
set service monitoring telegraf prometheus-client listen-address '10.5.0.255'
set service monitoring telegraf prometheus-client port '9273'
set service monitoring telegraf prometheus-client allow-from '10.5.11.30/32'
set firewall ipv4 input filter rule 9100 action 'accept'
set firewall ipv4 input filter rule 9100 destination port '9100,9342'
set firewall ipv4 input filter rule 9100 protocol 'tcp'
set firewall ipv4 input filter rule 9100 source address '10.20.11.30'
set firewall ipv4 input filter rule 9273 action 'accept'
set firewall ipv4 input filter rule 9273 destination port '9273'
set firewall ipv4 input filter rule 9273 protocol 'tcp'
set firewall ipv4 input filter rule 9273 source address '10.5.11.30'
set system task-scheduler task vpn-metrics interval '1m'
set system task-scheduler task vpn-metrics executable path '/config/scripts/vpn-metrics.py'
```

Install the script with `sudo install -m 0755 vpn-metrics.py /config/scripts/` on the router.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Key for `config.ssh_username` on the VMs (needs passwordless sudo) |
| `deploy_revision` | `"1"` | Change to force a redeploy, e.g. after rebuilding a VM |
| `backend_vlan_id` | `13` | VLAN whose NIC address Grafana and Postgres use |
| `monitoring_bridge` | `vmbr100` | Bridge of the backend's monitoring-network NIC |
| `pve_monitoring_bridge` | `"100"` | `pve_network.bridges` key for the Proxmox nodes' scrape addresses |
| `images` | pinned tags | Container images; override one key at a time |
| `settings` | see `variables.tf` | Prometheus retention (90d / 120GB), InfluxDB org/initial bucket/retention, the Grafana InfluxDB datasource's default bucket (`pve_cluster`), Grafana root URL, DNS probe zone |
| `pve_api_token`, `greatfox_api_token` | required | Proxmox API tokens for the metric servers, from the linked `proxmox.secret.auto.tfvars` |
| `pve_api_node` | `null` (`nodes.cluster_api_node`) | Cluster node whose API manages the cluster's metric server; set another node if that one is unreachable |
| `pve_metrics` | see `variables.tf` | Proxmox metric servers: `enabled`, bucket names (`pve_cluster`, `pve_<standalone host>`), `retention_days` (90) |
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
- **The Proxmox metric servers are managed here** ([`pve-metrics.tf`](pve-metrics.tf)).
  The cluster and the standalone greatfox each have a PVE metric server called
  `influxdb` (`/etc/pve/status.cfg`) that `pvestatd` uses to push node, guest (VM/LXC)
  and storage stats every ~10 s over HTTP to InfluxDB on mon01's monitoring
  address. Each writes to its own bucket (`pve_cluster`, `pve_greatfox`; 90-day
  retention) with its own write-only token. Buckets and tokens are created through
  the InfluxDB API by the `komminarlabs/influxdb` provider, so mon01 must be
  deployed before they can be planned; the metric servers go through the bpg
  provider (cluster API and the `proxmox.greatfox` alias), which needs
  `proxmox.secret.auto.tfvars` linked into this root:
  `ln -s ../../inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars roots/monitoring-config/`.
  The InfluxDB setup's initial bucket (`proxmox`) is unused.

## Next steps

1. Exporters on the remaining targets: `prometheus-node-exporter` on greatfox
   and the DNS VMs. The leaves get theirs from `fabric.settings.leaf_prometheus_exporters`
   (fabric-leaves) and the DHCP VMs from `dhcp_prometheus_exporters`
   (services-config).
2. keepalived VIP for Grafana on the backend VLAN.
3. A pve-exporter token, for VM/HA state in Prometheus.

## Tests

`tests/monitoring.tftest.hcl` plans against the real inventory with a mocked
`random` provider. It checks the derived targets and URLs, that pve-exporter
appears only with a token (and the token stays out of `prometheus.yml`), the
unit contents (Postgres bound to the backend VLAN, Grafana HA peers), the
Postgres/InfluxDB data-directory owners, the dashboard provider and files (the
expected files and uids per folder, every query uses the provisioned Prometheus
datasource, no import-time placeholders, every dashboard in the `lylat` links
dropdown, the Ceph dashboards' `ceph` tag and dropdown with no `$datasource` left, the Proxmox
dashboards' `proxmox` tag and dropdown, InfluxDB datasource and PVE-only bucket picker, the fw-wan
dashboards' `fw-wan` tag and dropdown and the routing one's fw-wan default, Node Exporter Full's job and host pickers, the overview as home
dashboard, no restart for JSON changes, stale files pruned), and that a missing
backend NIC fails the plan.

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config test'
```
