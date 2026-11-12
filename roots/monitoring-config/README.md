# monitoring-config

This root deploys the monitoring stack onto the VMs that
[services-vms](../services-vms/README.md) creates with `role = "monitoring"`
(the backends: mon01 primary, mon02 replica, see [Backend HA](#backend-ha-mon01--mon02)), `role = "grafana"` (any number of front ends) and `role = "logging"`
([Loki HA](#logging-loki-ha), loki01-03). It uses the
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
| backends (mon01 primary, mon02 replica; [Backend HA](#backend-ha-mon01--mon02)) | `prometheus`, `alertmanager`, `influxdb` | monitoring network (`10.5.11.30`/`.31`) and backend VLAN (`10.13.11.30`/`.31`): 9090, 9093, 8086; InfluxDB also on both VIPs (`10.5.11.102`, `10.13.11.102`), Alertmanager on `10.13.11.102`; Alertmanager gossip 9094 on the ha_monitor VLAN 215 (`10.21.13.30`/`.31`) |
| | `postgres` (shared Grafana database), **mon01 only** | backend VLAN only: `10.13.11.30:5432` |
| | `snmp-exporter`, `blackbox-exporter`, `pve-exporter` | not published; Prometheus reaches them by name on the `monitoring` Podman network |
| | `telegraf` ([C9800 telemetry](#c9800-telemetry-model-driven-dial-out), `wlc_telemetry`) | gRPC MDT receiver on the monitoring network only: `10.5.11.30:57500` (mon02: `.31`, once `influxdb_replica_ready`; then also the VIP `10.5.11.102:57500`, where the WLCs send); its own metrics on the backend VLAN, 9273 |
| | `influx-relay` (Telegraf, `vyos_influx_relay_port`) | InfluxDB v2 write listener 8087 on the monitoring address and VIP `10.5.11.102`; its own metrics on the backend VLAN, 9274 |
| | `keepalived` (Debian package) | VRRP (router id 102) unicast over VLAN 215; VIPs `10.5.11.102/16` (vmbr100 NIC) and `10.13.11.102/16` (VLAN 13 NIC) |
| | `node-exporter` | monitoring address, 9100 |
| | `monitoring-network` | the Podman bridge network itself |
| grafana VMs (graf01/02) | `grafana` | 3000 on every address (VLAN 2 for users, VIP `10.2.11.100` included), 9094 (alerting HA gossip) on the Grafana HA VLAN 213 |
| | `keepalived` (Debian package) | VRRP (router id 100) unicast over VLAN 213 (`10.21.11.32/.33`); VIP `10.2.11.100/16` on the VLAN 2 NIC |
| | `node-exporter` | backend VLAN address, port 9100 |
| backend and grafana VMs | `alloy` (journal -> Loki VIP) | backend VLAN address, port 12345 (metrics) |
| logging VMs (loki01-03) | `loki` | 3100 (HTTP) on every address, limited by `logging-guard` to loopback and the backend VLAN; ring (gRPC 9095, memberlist 7946) on the HA VLAN 214 |
| | `alloy` (syslog receiver + journal) | syslog on every address (VIPs included): TCP 514 (RFC 5424), UDP 514 (RFC 3164), UDP 1514 (raw); 12345 on the backend VLAN |
| | `haproxy` (S3 to the Ceph RGWs) | `127.0.0.1:7480`; stats/metrics on the backend VLAN, 8405 |
| | `keepalived` (Debian package), `logging-guard` (nftables) | VRRP over the HA VLAN; VIPs `10.13.11.101`, `10.5.11.101`, `10.20.11.101` (router id 101) |
| | `node-exporter` | backend VLAN address, port 9100 |
| Mimir VMs (mim01-03) | `mimir` ([Mimir HA](#metrics-mimir-ha)) | 8080 (HTTP) on every address (VIP `10.13.11.103` included), limited by `metrics-guard` to loopback and the backend VLAN; ring (gRPC 9095, memberlist 7946) on the HA VLAN 216 |
| | `haproxy` (S3 to the Ceph RGWs) | `127.0.0.1:7480`; stats/metrics on the backend VLAN, 8405 |
| | `keepalived` (Debian package), `metrics-guard` (nftables) | VRRP (router id 103) over VLAN 216; VIP `10.13.11.103/16` on the backend NIC |
| | `alloy` (journal -> Loki VIP), `node-exporter` | backend VLAN address, ports 12345 and 9100 |

The **backend VLAN** (VLAN 13, 10.13.0.0/16, VRF `lylat_monitor`) is isolated:
it routes to no other VRF. Grafana uses it for its datasources, its Postgres
database and alerting HA. The **monitoring network** (vmbr100, 10.5.0.0/16) is
where you open the Prometheus/Alertmanager/InfluxDB UIs and where the Proxmox
nodes push metrics.

Both Grafana VMs share one Postgres database, so users, sessions, dashboards
and alert state are the same on either. Datasources and [dashboards](#dashboards)
are provisioned from files, so a rebuilt VM comes back identical. Grafana's unified alerting peers over the
Grafana HA VLAN (213, L2VNI `ha_grafana`, `10.21.11.32/.33:9094`), so an alert isn't sent twice.
keepalived (`grafana_vrrp`, router id 100) holds the VIP `10.2.11.100/16` (`grafana.lylat.space`) on the
VLAN 2 NIC: adverts go unicast over VLAN 213, both VMs start BACKUP with `nopreempt` (graf01 wins the
first election), and a failing `/api/health` check puts a VM in FAULT, which releases the VIP. If a Grafana
VM has no addressed NIC on `grafana_ha_vlan_id`, gossip falls back to the backend VLAN and the plan
fails while `grafana_vrrp` is set.

## How a deployment works

There's one `terraform_data` per VM: `terraform_data.backend["mon01"]`/`["mon02"]` and
`terraform_data.grafana["graf01"]`/`["graf02"]`. The Grafana ones wait for the
backends. Each uploads `deploy.sh` to a private `/tmp` directory, runs it with
`sudo -n`, and deletes it. The script:

1. Unpacks its embedded files into a private staging directory.
2. Pulls the images.
3. **Validates** in throwaway containers with no network: `promtool check config`
   (with the rules), `amtool check-config`, the blackbox exporter's
   `--config.check` and `telegraf config check`. A broken config never gets installed.
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
| `/etc/monitoring/telegraf/telegraf.conf`, `/etc/monitoring/telegraf.env` | Telegraf (C9800 telemetry) config, and its InfluxDB write token (mode 0600) |
| `/var/lib/monitoring/{prometheus,alertmanager,influxdb,postgres}` | Data |
| `/etc/grafana-container/provisioning/datasources/datasources.yml` | Grafana datasources (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/dashboards.yml` | Grafana dashboard provider (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/files/<Folder>/*.json` | Provisioned dashboards (graf VMs) |
| `/etc/grafana-container/grafana.env` | Grafana secrets (mode 0600) |
| `/var/lib/grafana-container` | Grafana plugins/cache; real state is in Postgres |
| `/etc/alloy/config.alloy`, `/var/lib/alloy` | Alloy config and positions (every VM) |
| `/etc/logging/loki/loki.yaml`, `loki/rules/fake/*.yaml`, `/etc/logging/loki.env` | Loki config, ruler rules, S3 keys (mode 0600) (logging VMs) |
| `/var/lib/logging/loki` | Loki WAL, TSDB index cache, compactor and ruler state (chunks are in S3) |
| `/etc/logging/haproxy/haproxy.cfg` | haproxy (S3 -> RGWs) |
| `/etc/keepalived/keepalived.conf` | VRRP (mode 0600: the VRRP password) |
| `/etc/logging/guard.nft`, `/etc/systemd/system/logging-guard.service` | nftables table `inet logging_guard` for Loki's ports |

Logs: `journalctl -u prometheus` (and so on). Status: `systemctl status prometheus`.

## Scrape targets

They come from the same inventory the other roots use. Adding a node, leaf or
service VM updates Prometheus on the next apply.

| Job | Targets | From |
| --- | --- | --- |
| `node` | backend (monitoring address), grafana VMs (backend VLAN), DNS VMs (mgmt), Proxmox nodes (`cidrhost(vmbr100 prefix, id)`) | `vms`, `nodes`, `pve_network` |
| `vyos-node` (:9100), `vyos-frr` (:9342) | every leaf (mgmt), DHCP VMs (mgmt), `vyos_extra_targets` (fw-wan) | `fabric`, `nodes`, `vms` |
| `snmp-<name>` | `snmp_targets`: FS switches, CRS317s and spines on their monitoring-network (10.5/16) addresses, where the MikroTiks bind their SNMP agent; the C9800 WLCs (10.5.1.1/.2) over SNMPv3 (`snmp_v3_auths`). The MikroTik jobs use a 20 s `scrape_timeout` (RouterOS walks take 8-10 s) | variables |
| `pve` | cluster nodes' API, through pve-exporter (only with a token; standalone greatfox is left out) | `nodes` |
| `blackbox-icmp`, `blackbox-http_2xx` | `blackbox_icmp_targets`, `blackbox_http_targets` | variables |
| `blackbox-dns_soa` | each DNS VM's service address, `SOA lylat.space` | `vms` |
| `grafana` | each Grafana VM's `/metrics` on the backend VLAN | `vms` |
| `telegraf` | Telegraf's own `internal_*` metrics (`telegraf:9273` on the Podman network), with `wlc_telemetry` | variables |

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
| Edge | fw-wan overview (`fw-wan-overview`) | custom (Prometheus + InfluxDB) | The VyOS edge router. **Status:** ICMP, exporters, uptime, WAN address, WAN in/out (sparklines), CPU, memory, conntrack table, BGP sessions, VPN tunnels, VyOS services, systemd units failed/restarting, firewall drops + rejects. **Traffic:** WAN (in up, out down), traffic per VRF (VRF devices), top interfaces with their VRF. **Firewall:** final verdicts (accept/drop/reject), drops + rejects per chain, NAT connections. **VPNs:** tunnel state timeline, VTI/WireGuard traffic. **System:** CPU by mode, memory, temperatures, softnet drops, load, units not active. Collapsed: interface table (VRF, description, state, MTU, speed, in/out, errors, drops), router syslog |
| Edge | fw-wan firewall (`fw-wan-firewall`) | custom (Prometheus + InfluxDB) | Every IPv4/IPv6 filter chain (nft-metrics.py counters). **Summary:** final verdicts (accept/drop/reject per second), dropped + rejected in range, default-action drops per base chain, logged lines, rules missing from the snapshot, counter age. **Base chains:** input/forward/output verdicts by rule action (accept, → named chain, default drop/accept), default-action drops, what is being dropped (every drop/reject rule and default action). **Chains:** activity timeline, packets and traffic per chain. **Rules:** table (family, kind, chain, rule, action, jump target, match, packets/s, packets and bytes in range, totals), top rules, default actions hit. **NAT:** rule table (match/translation, connections per minute, in range, total) and connections per rule; conntrack entries, new connections, insert failures/drops/invalid; firewall log from the syslog (time, chain, rule, action, in/out, proto, addresses and ports) and logged packets per rule; collapsed rule and NAT reference |
| Edge | fw-wan VPNs (`fw-wan-vpn`) | custom (Prometheus + InfluxDB) | IPsec connections, IKE state, CHILD SAs, WireGuard peers, BGP over the tunnels, vpn-metrics.py health; SA state timeline, SA age, rekeys in range, CHILD SA traffic and packets; VTI/WireGuard interface traffic, errors and drops, link state, tunnel interface table; WireGuard handshake age and peer traffic; BGP peers in `vpn_*` VRFs, prefixes, routes; VPN firewall chains; collapsed strongSwan log |
| Edge | fw-wan VRFs & routing (`fw-wan-routing`) | custom | Router picker (default fw-wan, works for the leaves and DHCP VMs) and VRF picker: BGP/BFD summary, routes, VRFs, route changes, RIB not in FIB; routing table per VRF (IPv4/IPv6 RIB and FIB, BGP RIB, sessions up, changes), routes and route changes per VRF; BGP peer table (state, uptime, prefixes, messages, flaps), session state, BGP RIB, prefixes rx/tx, messages; traffic per VRF, interface traffic and table with the VRF (fw-wan); collapsed BFD peers and frr_exporter collectors |
| Network | Wireless (C9800) (`wireless-overview`) | custom (InfluxDB + Prometheus) | The C9800 WLCs' [model-driven telemetry](#c9800-telemetry-model-driven-dial-out). **Status:** clients, APs joined, radios up/total and down, WLANs with clients, telemetry age per WLC, SNMP up. **Controllers:** table (HA role, clients, radios, Linux CPU, IOSd CPU, load, memory; click a WLC for its logs), CPU per core, memory, IOSd CPU and load. **Access points:** AP table (state, clients, IP, model, serial, software, mode, uptime, joined for, uplink state and speed, tags, last disconnect reason; click an AP for its join/leave lines), radio table (band, state, channel and bonded channels, width, tx power and level, clients, channel busy, tx/rx/non-Wi-Fi airtime, tx/rx traffic, last channel change, BSS color), channel busy, clients, traffic, channel, tx power and retries/failures per radio. **RF environment:** airtime breakdown per radio, AP uplink traffic, noise floor / strongest other network / other networks' airtime / other APs per scanned channel. **SSIDs:** WLAN table (clients, random-MAC clients, download/upload), clients per WLAN, traffic per SSID. **Clients:** table (MAC, IP, AP, SSID, band, protocol, channel, RSSI, SNR, PHY rate, MCS, streams, download/upload, retries, state, security, connected for; click a client for its history), clients per WLC and by band/protocol, RSSI and throughput per client. Collapsed: the WLCs' own interfaces from SNMP. WLC picker |
| Network | Wireless client (C9800) (`wireless-client`) | custom (InfluxDB) | One client (MAC picker): its row of the clients table, RSSI/SNR, PHY rate and spatial streams, throughput and packets (download up, upload down), retries/drops/decrypt and MIC errors, and a timeline of its AP, SSID and channel (roams) |
| Network | Mikrotik monitoring (`mikrotik-snmp`) | [grafana.com 14420](https://grafana.com/grafana/dashboards/14420) rev 9 | MikroTik `mikrotik` module: board/firmware, CPU temperature, per-interface traffic and Ethernet error counters, interface table, neighbors (MNDP/LLDP) |
| Probes | Blackbox probes (`blackbox-probes`) | custom | ICMP/HTTP/DNS SOA probes: status, availability over the time range, duration, ICMP RTT and hop limit, HTTP status/phases (no TLS)/size, DNS query time, SOA serial and drift between the DNS servers |
| Monitoring | Monitoring stack (`monitoring-stack`) | custom | Component status and versions, config reloads; Prometheus targets per job, scrape duration, samples, head series, TSDB size, ingestion, rule evaluation, query latency; Alertmanager alerts, silences, notifications; Grafana requests, latency, datasource queries, DB connections, alerting; **Loki and Alloy**: up, ACTIVE ring members per ring, unhealthy/memberlist members, RGWs UP per haproxy, flush failures, Alloy drops and syslog parse errors, lines/bytes received, Alloy sent/received, chunks flushed to S3, S3 requests and p95 latency, in-memory streams and flush queue; SNMP/FRR/node exporter scrape times; **Telegraf** (C9800 telemetry): metrics received per input, InfluxDB writes/drops/errors, output buffer; process memory and CPU |
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
| Logs | Logs overview (`logs-overview`) | custom (Loki) | Lines, lines/s, errors and warnings in range, hosts sending, syslog parse errors; lines by source, level and host, errors/warnings by host; noisiest hosts (click to filter) and apps, most errors; newest errors table; log browser. Source, host, app, level and search (regex) pickers |
| Logs | Network device logs (`logs-network`) | custom (Loki) | Leaves, fw-wan, MikroTik spines/CRS317, FS switches, C9800 WLCs: event counts (BGP/BFD, interface up/down, STP, auth failures, logins, config changes, AP join/leave, client failures), events per device (status history), events by category, lines per device; BGP and BFD session changes of the VyOS routers from frr_exporter (Prometheus: changed or restarted sessions, state timeline), RouterOS session state lines, interface events, STP, logins/auth failures/config changes, AP join/leave table, client failures, Cisco/FS message types; all device logs. Device and search pickers |
| Logs | fw-wan firewall & VPN logs (`logs-fw-wan`) | custom (Loki) | Firewall log parsed with LogQL (chain, rule, action, in/out, proto, addresses, ports): logged/dropped/rejected/accepted, distinct sources and ports, by rule/action/interface, top dropped sources, destinations, ports and rules, firewall log table; strongSwan IKE events (initiating, established, retransmits, failures, deletes), initiations per connection, charon log without packet traces, WireGuard; config commits and the rest of the router log. Action, address and search pickers |
| Logs | Proxmox & Ceph logs (`logs-proxmox`) | custom (Loki) | PVE nodes: errors, warnings, failed and started tasks, corosync, HA and auth events; lines by node and app; corosync events, corosync/pmxcfs and HA logs; tasks by type and task table; guest lifecycle, PVE daemons, kernel warnings. Ceph cluster log (one mon's copy): health checks raised/cleared, HEALTH_ERR, OSD events, slow ops; by severity, health checks per bucket and in range, health changes, OSD events and slow ops, the log without DBG, Ceph daemons and kernel client. Node, Ceph mon and search pickers |
| Logs | Services logs (`logs-services`) | custom (Loki) | BIND: transfers, notifies, DNSSEC validation and resolution errors, queries (if logged), messages by kind, zone transfer table, log. Kea: leases, NAKs, allocation failures, HA state changes and comms problems, messages by code, leases and HA transition tables, log. keepalived: who became MASTER of each VRRP instance, transitions, state change table. Monitoring stack containers: errors/warnings by container, haproxy, Loki/Alloy, Prometheus/Alertmanager and Grafana logs. Container and search pickers |

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
syslog in the InfluxDB bucket `vyos` (firewall log, router log, strongSwan log). The firewall
and NAT counters are nft-metrics.py's (see [fw-wan](#fw-wan-vyos-edge-router-configured-by-hand));
Telegraf's `nftables_*` series aren't used. What a firewall rule does isn't in the counters, so
[`dashboards/fwwan_snapshot.py`](../../modules/services/monitoring/dashboards/fwwan_snapshot.py)
holds family/chain/rule → action, jump target and match, interface → VRF and the NAT rules, read from fw-wan's
config by [`fwwan_config.py`](../../modules/services/monitoring/dashboards/fwwan_config.py)
(see [Changing the dashboards](#changing-the-dashboards)). The firewall dashboard's "Rules not
in snapshot" turns orange when fw-wan has rules the snapshot doesn't know.

The wireless dashboards (`wireless` tag, folder Network) share a "Wireless dashboards" dropdown and
read the C9800 telemetry in the InfluxDB bucket `wlc` (Flux, uid `influxdb`; see
[C9800 telemetry](#c9800-telemetry-model-driven-dial-out)). The **WLC** picker filters on the
telemetry's `source` tag, which equals the SNMP jobs' `host` label (`c9800-wlc-1/2`), so the SNMP
panels follow it too. "Now" values are the newest sample in the last 3 minutes of the time range:
clients and APs that leave just stop reporting, so they drop out. The APs refresh their counters
only every 90 s (client traffic, per-SSID stats) or 180 s (radio and uplink counters, RRM), and the
WLC re-sends the old value in between, so rates are taken over windows of at least 3 minutes and
channel utilization moves in 3-minute steps. Client traffic is from the AP's side: download is
`bytes_tx` (sent to the client). The tables link to the network device logs (WLC, AP join/leave)
and the client dashboard; the top bar links to the WLC logs and the SNMP dashboards. c9800-wlc-2
has no APs or clients, so it only shows up in the controller panels.

The log dashboards (`logs` tag, folder Logs) share a "Logs dashboards" dropdown and query the
Loki datasource (uid `loki`, see [Logging](#logging-loki-ha)). Podman logs a container's stderr
with priority err, so the dashboards rewrite `level` from the line itself (`level=`, `lvl=`,
`[NOTICE]`) for container lines and map everything to error/warning/notice/info/debug. Host pickers
match case-insensitively (Loki has `LEAF-11`, Prometheus `leaf-11`), so the Overview host table and
Node Exporter Full link to a host's logs, the Proxmox node dashboard to its node's logs, and the FRR
dashboard to the network device logs. The fw-wan logs dashboard is in the "fw-wan dashboards" dropdown,
the Proxmox & Ceph one in the "Ceph dashboards" dropdown. The fw-wan dashboards keep reading the firewall
and strongSwan log from InfluxDB, which has the history from before Loki.

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
- **fw-wan dashboards:** the nft-metrics.py counters start on 2026-11-09 ~16:30 UTC, and
  they restart at 0 whenever the firewall is recommitted (rate/increase handle that). NAT
  rules count connections (only a connection's first packet passes the NAT chains); bytes
  aren't shown. fw-wan has no output filter, so output only shows "default accept". The
  raw (notrack) chains are left out. There's no OSPF anywhere and no BFD on fw-wan. Firewall log panels show only rules
  with `log` (deny_data 22 and 23). Road-warrior WireGuard peers and the VPS IPsec
  connection are DOWN while not connected, and "Rekeys in range" counts a reconnect too.
  The VRF column of the interface tables is fw-wan only (from the snapshot).
- **Log dashboards:** Loki has logs from 2026-11-09 on. Event panels (BGP, interfaces, STP,
  AP/client, corosync, HA, Ceph health, IKE established) stay empty until such an event happens;
  WireGuard is always empty (the kernel module logs only with dynamic debug), and BIND queries
  unless query logging is on. VyOS sets FRR to `log syslog notifications`, so bgpd's %ADJCHANGE and
  bfdd's state changes (informational) never reach the syslog: the VyOS sessions' changes come from
  frr_exporter instead. The VyOS routers and DHCP VMs send every line twice (rsyslog reads both the
  journal and journald's syslog socket; that copy has a leading space): Alloy drops the copy with
  exactly one leading space for `logging_settings.syslog_dedup_hosts` (kernel lines excepted), so
  only lines from before that change are doubled. Indented continuation lines keep both copies, and
  the few lines that came only from the journal with one leading space (boot) are dropped too. The
  fw-wan Router log and charon tables (InfluxDB) skip the second copy in Flux. The Ceph cluster log arrives once per mon: pick
  one with the Ceph mon picker. BIND writes everything to stderr, so its BIND panels go by the
  line, not the level.
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
  [`dashboards/fwwan.py`](../../modules/services/monitoring/dashboards/fwwan.py), the log
  dashboards' (LogQL) in [`dashboards/logs.py`](../../modules/services/monitoring/dashboards/logs.py),
  the wireless ones' (Flux, C9800 telemetry) in
  [`dashboards/wireless.py`](../../modules/services/monitoring/dashboards/wireless.py), whose docstring
  lists the measurement and tag names it relies on. After
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
set system task-scheduler task nft-metrics interval '1m'
set system task-scheduler task nft-metrics executable path '/config/scripts/nft-metrics.py'
set system syslog remote 10.5.11.101 facility all level 'info'
set system syslog remote 10.5.11.101 port '514'
set system syslog remote 10.5.11.101 protocol 'tcp'
set system syslog remote 10.5.11.101 format include-timezone
set system syslog remote 10.5.11.101 format octet-counted
set system syslog remote 10.5.11.101 vrf 'lylat_service'
set system syslog remote 10.5.11.101 source-address '10.5.0.255'
```

The `system syslog remote` lines send fw-wan's log (firewall `log` rules, strongSwan, FRR,
`info` and up) to Loki through the Alloy VIP `10.5.11.101` (TCP 514, RFC 5424, octet-counted)
from `lylat_service`. The other hand-configured log senders (PVE nodes, CRS317s, FS
switches, WLCs) are in [log-senders](log-senders/README.md).

Install the scripts with `sudo install -m 0755 vpn-metrics.py nft-metrics.py /config/scripts/`
on the router. [`vyos/nft-metrics.py`](vyos/nft-metrics.py) adds per-rule counters for every
filter chain (input/forward/output base chains and their default actions, named chains,
IPv4 and IPv6) and NAT (`vyos_firewall_rule_{packets,bytes}_total{family,kind,chain,rule}`,
`vyos_nat_rule_{packets,bytes}_total{family,type,rule}`); Telegraf's VyOS script only
covers the named IPv4 chains. Telegraf's `syslog_*` series are dropped at scrape time.

## C9800 telemetry (model-driven, dial-out)

The two Cisco C9800-CL WLCs stream their operational data (YANG oper models: controller
CPU/memory, APs and radios, clients) with **model-driven telemetry** (MDT). Each WLC
**dials out**: it opens a gRPC connection to the receiver and pushes every subscription
periodically (yang-push, every 30 s, kvGPB encoding), so nothing polls the WLCs and no
credentials for them are stored here. The receiver is **Telegraf** on mon01
(`wlc_telemetry`, [`modules/services/monitoring/telemetry.tf`](../../modules/services/monitoring/telemetry.tf)):

- `inputs.cisco_telemetry_mdt` listens on gRPC `:57500`, published on mon01's monitoring
  address only (`10.5.11.30:57500`, `tofu output wlc_telemetry_receiver`). The WLCs send
  from their Vlan5 address (`10.5.1.1`, `10.5.1.2`) on the same 10.5/16, so no router or
  firewall is in the path, and mon01 has no host firewall.
- Two nested RRM lists (per-channel noise and foreign interference) get their `chan` key as a
  tag through `embedded_tags`, and the per-process CPU list is dropped (`fieldexclude`): it
  flattens into colliding fields.
- Every message becomes one InfluxDB measurement named after its YANG path (no aliases),
  e.g. `Cisco-IOS-XE-wireless-client-oper:client-oper-data/traffic-stats`, with the list keys
  as tags and the WLC as `source`. Telegraf writes them to the bucket `wlc` (90-day
  retention) with its own write-only token ([`telegraf.tf`](telegraf.tf)), reaching
  InfluxDB by container name on the `monitoring` Podman network.
- Telegraf's own `internal_*` metrics go to Prometheus (job `telegraf`): the Monitoring
  stack dashboard shows metrics received per input, InfluxDB writes and the output buffer,
  and `WlcTelemetryStopped` fires when no telemetry has arrived for 20 minutes.

The WLC side isn't managed by this repo. Both WLCs have the same 22 `telemetry ietf subscription`s
(ids 101-504, one per xpath: controller CPU/memory, AP, radio, RRM, client and global counts;
`encoding encode-kvgpb`, `stream yang-push`, `update-policy periodic 3000`, 6000 for the slower
trees) that point at one named receiver, `telemetry receiver protocol mon01` (port `57500`, `protocol grpc-tcp`,
no TLS), sent from each WLC's Vlan5 address. Its host is `tofu output wlc_telemetry_receiver` `.address`: the
monitoring VIP `10.5.11.102` with two backends (see [Backend HA](#backend-ha-mon01--mon02); set by
`~/network_automation/mon-ha/live/wlc-vip.sh`), else mon01's `10.5.11.30`. The exact CLI is in
`~/network_automation/wlc-telemetry/wlc-config.md`. The measurement, tag and field names (from a
real capture) are in `~/network_automation/wlc-telemetry/fields.md`, and the dashboards
([Wireless (C9800)](#dashboards)) use exactly those.
To check that data arrives: `journalctl -u telegraf` on mon01, or in Grafana's Explore
(InfluxDB): `import "influxdata/influxdb/schema" schema.measurements(bucket: "wlc")`.

## Backend HA (mon01 + mon02)

Every `role = "monitoring"` VM is a backend (at most two: `monitoring_primary`, default mon01, plus one
replica). They run the same stack from the same rendered files, except Postgres (primary only) and the
per-replica bits below. The rendering is in the module's `backends.tf`; the replica's InfluxDB objects in
[influxdb-replica.tf](influxdb-replica.tf).

- **Prometheus HA pair.** Both scrape every target with the same config; `external_labels` are
  `{site = "lylat", ha_cluster = "lylat", __replica__ = "<vm>"}`. With Mimir on ([Metrics: Mimir HA](#metrics-mimir-ha)) both
  remote_write to it and Mimir's HA tracker keeps one replica's samples, then drops `ha_cluster` and `site`. The
  `prometheus`, `alertmanager`, `telegraf` and `influx-relay` jobs target every backend by backend-VLAN address
  (label `host`), so each replica scrapes both and the deduplicated data still has every instance. Grafana has
  `Prometheus mon01`/`Prometheus mon02` datasources (uids `prometheus-mon01/-mon02`) to look at one replica directly.
- **Alertmanager cluster.** Gossip on the ha_monitor VLAN 215 (`monitoring_ha_vlan_id`, L2VNI `ha_monitor`),
  `10.21.13.30/.31:9094`, cluster label `lylat-alertmanager`. Both Prometheus (and the Loki ruler) send every alert to
  both Alertmanagers; `alert_relabel_configs` drops `__replica__`, so the two replicas' alerts are identical and the
  cluster notifies once. Without an address on VLAN 215 on every backend, gossip falls back to the backend VLAN.
- **keepalived** (`backend_vrrp`, router id 102): one instance, unicast adverts over VLAN 215, VIPs `10.5.11.102/16`
  (monitoring network: InfluxDB, the VyOS relay, `influxdb.lylat.space`) and `10.13.11.102/16` (backend VLAN: Grafana's
  InfluxDB and Alertmanager datasources). BACKUP + `nopreempt` (mon01 wins the first election), FAULT when InfluxDB
  `/health` or Alertmanager `/-/ready` fails locally. Containers publish on the VIPs too, so the backends set
  `net.ipv4.ip_nonlocal_bind = 1` (`/etc/sysctl.d/90-monitoring-vip.conf`). Alert `MonitoringVIPNotHeldOnce`.
- **InfluxDB on both.** Both are initialised with the same operator token (Grafana, the providers). Every writer
  writes to both: the Proxmox cluster and greatfox have a second metric server `influxdb-mon02`; the C9800s
  send to the WLC Telegraf on the monitoring VIP `10.5.11.102:57500`, and each Telegraf writes bucket `wlc` on
  both InfluxDBs (local by container name, the peer over the backend VLAN with that InfluxDB's token; alerts
  `WlcTelemetryStopped` over both, `WlcTelemetryWriteDropping`). A second named receiver per subscription
  doesn't work: IOS XE keeps only one receiver of a subscription active, the rest are standbys. VyOS Telegraf (one URL, one token) writes to `influx-relay` on the
  monitoring VIP, `http://10.5.11.102:8087`, with its existing token, and the relay copies every write into bucket
  `vyos` on both InfluxDBs (200k metrics buffered per output while a peer is down; alerts `InfluxRelayDropping`,
  `InfluxRelayBacklog`). Write tokens are generated per InfluxDB, which is why VyOS can't just use a VIP'd InfluxDB.
- **Two stages.** The `influxdb.replica` provider has to reach a running InfluxDB to plan, so mon02's buckets,
  tokens, metric servers and WLC Telegraf wait for `influxdb_replica_ready = true` (deploy mon02 first; until then the
  provider points at the primary and manages nothing). mon02's InfluxDB history can be copied from mon01 with Flux
  `to()` (runbook).
- **Grafana's database** is the Patroni cluster on pg01-03 (VIP 10.13.11.104) since 2026-11-10; mon01's
  Postgres container is gone (`postgres.auto.tfvars`). See [Postgres HA: Patroni](#postgres-ha-patroni).

## Logging (Loki HA)

Logs from the whole lab go to **Loki** on loki01-03 (`role = "logging"`, zoness/titania/fortuna),
through **Grafana Alloy**, and are queried from Grafana (datasource `Loki`, uid `loki`).
`terraform_data.logging["<vm>"]` deploys each VM like the others (generated `deploy.sh`, Quadlets).

```
devices / VyOS / PVE / DNS --syslog--> VIP 10.5.11.101 | 10.20.11.101 --> alloy (VIP holder)
mon01, graf01/02 alloy --journal----------> VIP 10.13.11.101:3100 ---------\
                                                                          v
alloy (each log VM, journal + syslog) --> local loki --(ring, RF 3, VLAN 214)--> all 3 lokis
                                          loki --S3--> 127.0.0.1:7480 haproxy --> RGW on macbeth/titania/venom (10.27.0.x)
Grafana --> VIP 10.13.11.101:3100 ;  Loki ruler --> both Alertmanagers (10.13.11.30/.31:9093)
```

**Networks on each log VM** (interface names from the NIC order: mgmt `eth0`, `network_devices[i]` = `eth<i+1>`):

| Network | loki01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.34-36 | SSH; VIP `10.20.11.101` for syslog from the VyOS leaves, DHCP and DNS VMs (mgmt VRF) |
| VLAN 2 (`eth1`) | 10.2.11.34-36 | default route: image and package pulls |
| VLAN 13 (`eth2`) | 10.13.11.34-36 | backend: Loki HTTP API, Alloy/haproxy/node_exporter metrics; VIP `10.13.11.101` (Grafana datasource, Alloy pushes from mon01/graf) |
| vmbr100 (`eth3`) | 10.5.11.34-36 | monitoring network: VIP `10.5.11.101` for syslog from switches, WLCs, fw-wan and the PVE nodes |
| vmbr27 (`eth4`) | 10.27.11.34-36 | Ceph public network: haproxy -> RGWs |
| VLAN 214 (`eth5`, L2VNI `ha_logging`) | 10.21.12.34-36 | HA: Loki memberlist and ingester gRPC (the ring), keepalived adverts |

### Loki

- **Monolithic** (`-target=all`) on each VM; the three form one ring over **memberlist** on the HA
  VLAN (`instance_addr`, `advertise_addr`, `join_members` = the VLAN 214 addresses, `cluster_label
  lylat-loki`). **replication_factor 3**: every stream is written to all three ingesters and a write
  needs two of them, so one VM can be down (or rebooting) without losing writes or queries.
- **Storage**: TSDB index, schema v13 (from `logging_settings.schema_start`; never change an existing
  period, add a new one), chunks and index in the S3 bucket `loki` on Ceph RGW. Each Loki talks to
  `http://127.0.0.1:7480`, the local **haproxy**, which balances the three RGWs and health-checks them
  (anonymous `GET /` must return 200), so any single RGW or PVE node can go down.
- **Retention**: `logging_settings.retention_period` (90d), applied by the compactor. Every instance
  runs a compactor, but they elect one through the ring (a single token), so only one compacts and
  deletes. Delete requests are stored in S3.
- **Ruler**: rules from `/etc/logging/loki/rules/fake/` (the same on all three), sharded over the ruler
  ring so each group is evaluated once, alerts to both Alertmanagers (the cluster dedups). One rule for now:
  `BGPSessionDownLogged` (an FRR `ADJCHANGE ... Down` in the syslog; VyOS doesn't send those at its FRR log
  level, so it doesn't fire for the VyOS routers).
- **Ports**: Loki runs with host networking and listens on every address, because the backend VIP
  moves between the VMs. `logging-guard` (an nftables table `inet logging_guard`, loaded by its own
  systemd unit) drops 3100 except from loopback and `logging_settings.loki_allowed_sources`
  (`10.13.0.0/16`), and 7946/9095 except from the three HA addresses. Nothing else is filtered.
- S3 keys live in `/etc/logging/loki.env` (0600) and are expanded by Loki (`-config.expand-env`);
  `loki.yaml` itself (output `loki_configs`) has no secrets.
- With RF 3 and no shared chunk cache, all three ingesters flush the same chunks (same object keys,
  so S3 holds one copy, but three writes).

### Alloy

- **log VMs**: syslog on every address (the VIPs included), pushed to the *local* Loki:

  | Listener | Format | Senders | Timestamp |
  | --- | --- | --- | --- |
  | TCP 514 | RFC 5424, octet-counted | VyOS leaves, DHCP VMs, fw-wan, PVE nodes and DNS VMs (rsyslog) | sender's |
  | UDP 514 | RFC 3164 | MikroTik CRS317/CRS326 | receive time (no year/zone) |
  | UDP 1514 | raw (unparsed line) | Cisco C9800 WLCs (IOS-XE), FS S3910, FS S3700: RFC 3164 parsing silently drops their messages (the S3700's end in a NUL byte) | receive time (switch-1 has no NTP) |

  The `raw` format is experimental in Alloy, so the log VMs run it with `--stability.level=experimental`
  (validation too: `alloy validate` doesn't check stability, `alloy run` refuses it).
  Labels: `source="syslog"`, `host` (message hostname, else the sender's IP), `app`, `level` (severity),
  `facility`. Known senders get a fixed `host` from their address, the same name Prometheus uses: every
  `snmp_targets` address, plus `logging_settings.syslog_host_overrides`. That's what names the raw
  lines and fixes generic hostnames ("Switch").
- **Every VM** (mon01, graf01/02, loki01-03): the journal, `source="journal"`, `host`=VM name, `unit`,
  `container` (Podman's journald driver: every Quadlet container), `app`, `level`. mon01 and the
  Grafana VMs push to the VIP `http://10.13.11.101:3100`.

### VIPs and failover (keepalived)

keepalived comes from the Debian package (installed by `deploy.sh`), not a container: it manages host
addresses (it needs host networking and NET_ADMIN anyway), its check scripts run curl on the host,
and Debian ships security updates for it. There's no trustworthy upstream keepalived image.

- **One VRRP instance** (`virtual_router_id 40`, VRRPv2 with a generated 8-character PASS,
  `random_password.vrrp`) with unicast adverts over the HA VLAN (`eth5`). It carries the three VIPs,
  each on its client NIC (`10.13.11.101/16 dev eth2`, `10.5.11.101/16 dev eth3`, `10.20.11.101/16 dev eth0`),
  so they always move together.
- All three start `BACKUP` with **`nopreempt`**. Priorities 150/100/50 (loki01/02/03) only decide the
  first election. A recovered VM doesn't take the VIPs back, so there's no second interruption.
- **Failover**: the holder goes to FAULT, and a peer takes the VIPs within ~15 s (checks every 5 s,
  3 failures), when Loki's `/ready` fails, Alloy's `/-/ready` fails, a client NIC goes down
  (`track_interface`), or the VM or keepalived stops (3 missed adverts, ~3 s). The new holder sends
  gratuitous ARPs (and every 60 s while it holds them), which the EVPN fabric learns as a MAC move.
- What senders see: UDP syslog sent during the switchover is lost. TCP senders (rsyslog, VyOS)
  reconnect and resend their queue. Grafana and the Alloys on mon01/graf retry.
- If all three fail their checks, nobody holds the VIPs (alert `LoggingVIPNotHeldOnce`).

### Adding a log sender

- Send syslog to `10.5.11.101` (monitoring network) or `10.20.11.101` (mgmt): **TCP 514 RFC 5424
  octet-counted** if the device can (rsyslog: `omfwd` with `RSYSLOG_SyslogProtocol23Format`,
  `TCP_Framing="octet-counted"`), otherwise **UDP 514 RFC 3164**, and **UDP 1514** if the device's
  format doesn't parse as RFC 3164 (it shows in `loki_source_syslog_parsing_errors_total`).
- If its messages carry no useful hostname, add its address to `snmp_targets` (if it's scraped) or
  `logging_settings.syslog_host_overrides`.
- A Linux VM with Podman: give it Alloy like mon01 (journal -> VIP 10.13.11.101) if it has a VLAN 13
  NIC, otherwise forward its journal as syslog.
- The hand-configured senders are in [log-senders](log-senders/README.md).

### Ceph RGW on the PVE nodes

The S3 endpoint is Ceph's RGW (`radosgw` from the PVE Ceph repo, pinned to the cluster version
20.2.2-pve1), one daemon each on macbeth, titania and venom (`client.rgw.<node>`, beast on the
node's Ceph public address `10.27.0.<id>:7480`, sections in `/etc/pve/ceph.conf`). It's not managed
by OpenTofu. The S3 user and bucket are both `loki`; their keys go into
`roots/monitoring-config/logging.secret.auto.tfvars` (git-ignored, mode 600):

```hcl
loki_s3 = { bucket = "loki", access_key = "...", secret_key = "..." }
```

`logging_settings.rgw_endpoints` lists the RGWs haproxy uses (default `10.27.0.12/13/17:7480`).

<!-- The exact install commands (radosgw, keyrings, pools, S3 user) are added here by the main session. -->

Per-bucket usage (size, objects, quotas of the `loki`, `mimir`, `postgres` buckets) comes from a
timer on the RGW nodes that writes `radosgw-admin bucket stats` into node_exporter's textfile
collector: [pve-collectors](pve-collectors/README.md) (installed by hand). Dashboard
**Storage → Ceph RGW buckets**, alert group `ceph-rgw-buckets` (growth, near quota, collector stale;
thresholds in `rgw_bucket_alerts`).

### Runbook

- **Which VM holds the VIPs:** `ip -br a | grep -E '\.40/'` on each log VM, or
  `node_network_address_info{address=~".*\\.40"}` in Prometheus. Logs: `journalctl -u keepalived`.
- **Move the VIPs off a VM** (maintenance): `sudo systemctl stop keepalived` there (they don't come
  back on start, `nopreempt`).
- **Ring state:** `curl -s http://10.13.11.34:3100/ring` (ingesters), `/memberlist`, `/compactor/ring`,
  `/ruler/ring`; ready: `/ready`. Each must show three ACTIVE members.
- **S3 path:** `curl -s http://10.13.11.34:8405/stats` (haproxy: which RGWs are UP);
  from a log VM, `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7480/` should be 200.
- **Is syslog arriving?** `sum by (host) (rate(loki_source_syslog_entries_total[5m]))` (job `alloy`),
  parse errors in `loki_source_syslog_parsing_errors_total`; in Grafana Explore: `{source="syslog"}`.
- **Rolling restart** of Loki after a config change: apply with `-parallelism=1`, so the log VMs
  deploy one at a time and each waits for `/ready` before the next restarts. A normal (parallel)
  apply restarts all three at once: writes fail for a minute and Alloy retries.
- **Rebuilt log VM:** its WAL is gone, but the other two hold the data (RF 3). Bump `deploy_revision`
  (or let the new VM ID trigger it) and apply. The ring forgets the old instance after its heartbeat
  times out.
- **Alerts** (Prometheus, group `logging`): `LokiRingUnhealthy`, `LokiRingMembersMissing`,
  `LokiIngesterFlushFailures` (S3 writes failing), `SyslogIngestStopped`, `AlloyLokiWriteDrops`,
  `RGWBackendDegraded`/`RGWBackendDown` (haproxy), `LoggingVIPNotHeldOnce` (per VIP, from
  node_exporter's `--collector.netdev.address-info`).

## Metrics: Mimir HA

Long-term metrics live in **Grafana Mimir** on mim01-03 (`role = "metrics"`, fichina/venom/eldarad),
deployed by `terraform_data.metrics["<vm>"]` like the Loki VMs ([`metrics.tf`](metrics.tf),
[module `metrics.tf`](../../modules/services/monitoring/metrics.tf)). Both Prometheus replicas
(mon01/mon02) `remote_write` everything to it, and Grafana's default datasource (uid `prometheus`)
queries it, so dashboards keep working when either Prometheus is down and reach back ~13 months.

```
Prometheus mon01 --remote_write--\                       /--> mimir (VIP holder): distributor -> 3 ingesters (RF 3, VLAN 216)
Prometheus mon02 --remote_write---> VIP 10.13.11.103:8080 ---> query-frontend -> queriers -> ingesters + store-gateways
Grafana (uid prometheus) --/prometheus------------------/     ingesters --2 h blocks--> 127.0.0.1:7480 haproxy --> RGWs (bucket mimir)
```

**Networks on each Mimir VM** (mgmt `eth0`, `network_devices[i]` = `eth<i+1>`):

| Network | mim01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.37-39 | SSH |
| VLAN 2 (`eth1`) | 10.2.11.37-39 | default route: image and package pulls |
| VLAN 13 (`eth2`) | 10.13.11.37-39 | backend: Mimir HTTP (push, queries), scrapes; VIP `10.13.11.103` |
| vmbr27 (`eth3`) | 10.27.11.37-39 | Ceph public network: haproxy -> RGWs |
| VLAN 216 (`eth4`, L2VNI `ha_mimir`) | 10.21.14.37-39 | HA: memberlist (7946), gRPC (9095), keepalived adverts |

### Mimir

- **Mimir 3.2.4, monolithic** (`-target=all`: distributor, ingester, querier, query-frontend and
  -scheduler, store-gateway, compactor, ruler) on each VM, **classic architecture**: Mimir 3.x
  still defaults to it in the binary (`ingest_storage.enabled: false`, set explicitly); the Kafka
  "ingest storage" architecture is only the Helm chart's default. No Kafka.
- The three form one set of rings over **memberlist** on VLAN 216 (`cluster_label lylat-mimir`, every
  ring's `instance_addr` is the HA address). **RF 3**: every series is on all three ingesters and a
  write needs two, so one VM can be down. Multitenancy is off (tenant `anonymous`).
- **Storage**: ingesters keep the WAL and the last 13 h on local disk (`/var/lib/metrics/mimir`) and
  ship 2 h TSDB blocks to the S3 bucket `mimir` through the local haproxy (same config as on the Loki
  VMs). The compactor (one at a time, through its ring) merges them and deletes blocks older than
  `metrics_settings.retention_period` (**396d**, ~13 months). The store-gateways serve the blocks.
- **HA tracker** (memberlist KV, the default since Mimir 3.0): the Prometheus `external_labels`
  carry `ha_cluster="lylat"` and `__replica__="<vm>"`; Mimir accepts one replica's samples and drops
  the other's (`cortex_distributor_deduped_samples_total`), failing over after 30 s without samples
  from the elected replica. After deduplication `drop_labels` removes `ha_cluster` and `site`, so the
  series in Mimir are the ones each Prometheus stores (and the backfilled history matches). `cluster`
  isn't used as the HA label because the ceph job has its own `cluster` target label.
- **Limits** (`metrics_settings`): 300k series (118k today; the default 150k is too tight),
  300k samples/s (4.2k today; see below), 40 labels per series (21 at most today), 10 min out-of-order window
  (a replica failover can resend slightly older samples), block upload on (backfill).
  The ingestion rate is a per-tenant *global* limit: each distributor enforces `ingestion_rate / healthy
  distributors` (burst not divided). All pushes go through the VIP to one distributor, so that one
  allows only a third: 100k/s. Prometheus treats a 429 as non-recoverable and drops the batch, so the
  limit must cover a WAL catch-up after an outage. At 40k (13.3k/s on the VIP holder), mon01 dropped
  ~1.08M samples catching up during the first deploy (2026-11-10 ~00:27 UTC). Mimir 3.2.4 has no
  option to answer rate limits with a retryable status.
- **Ports**: Mimir uses host networking and listens on every address (the VIP moves).
  `metrics-guard` (nftables table `inet metrics_guard`) drops 8080 except from loopback and
  `metrics_settings.allowed_sources` (`10.13.0.0/16`), and 7946/9095 except from loopback and the
  three HA addresses. gRPC must include loopback: in monolithic mode the query-frontend and querier
  reach the scheduler on `127.0.0.1:9095`.
- S3 keys live in `/etc/metrics/mimir.env` (0600, `-config.expand-env`); `mimir.yaml` (output
  `mimir_configs` of the module) has none.
- The ruler runs (it's part of `all`) with no rules; alerting stays in Prometheus. No Mimir
  Alertmanager.

### VIP (keepalived)

One VRRP instance (router id **103**, generated 8-character PASS `random_password.mimir_vrrp`),
unicast adverts over VLAN 216, VIP `10.13.11.103/16` on the backend NIC (`eth2`). Same rules as the
Loki VIPs: all `BACKUP` with `nopreempt`, priorities 150/100/50 for the first election, FAULT when
Mimir's `/ready` fails 3 times (5 s apart) or `eth2` goes down. Prometheus retries and replays its
WAL, so a failover only delays samples. Alert `MimirVIPNotHeldOnce`.

### Turning it on

Mimir is deployed only when `mimir_s3` is set. Without it (and with mim01-03 in the inventory) the
check `mimir_s3` warns, Prometheus has no `remote_write` and Grafana stays on Prometheus. Create the
RGW user and bucket (runbook in `~/network_automation/mon-ha/mimir-runbook.md`), then put the keys in
`roots/monitoring-config/metrics.secret.auto.tfvars` (git-ignored, mode 600):

```hcl
mimir_s3 = { bucket = "mimir", access_key = "...", secret_key = "..." }
```

### Runbook

- **Rings:** `http://10.13.11.37:8080/ingester/ring` (also `/store-gateway/ring`, `/compactor/ring`,
  `/distributor/ring`, `/memberlist`); each needs three ACTIVE members. `/ready` on each VM.
- **HA tracker:** `http://10.13.11.103:8080/distributor/ha_tracker` shows the elected replica;
  `cortex_ha_tracker_elected_replica_status` in Prometheus.
- **Who holds the VIP:** `ip -br a | grep 10.13.11.103`, `node_network_address_info{address="10.13.11.103"}`.
- **Rolling restart** after a config change: apply with `-parallelism=1` (each VM waits for `/ready`).
  A parallel apply restarts all three: pushes fail for a minute and Prometheus catches up from its WAL.
- **Rebuilt Mimir VM:** ingesters unregister on a clean shutdown, but a VM that died stays in the
  ingester ring as Unhealthy (`MimirRingUnhealthy`) and a freshly started Mimir won't report ready while
  the ring has an unhealthy member: click **Forget** for the old entry on `/ingester/ring`.
- **Is data arriving?** `sum(rate(cortex_distributor_received_samples_total[5m]))`,
  `prometheus_remote_storage_*` on each Prometheus (Monitoring stack dashboard, row Mimir).
- **Alerts** (group `metrics`): `MimirRingMembersMissing`, `MimirRingUnhealthy`, `MimirBlockUploadFailures`,
  `MimirCompactorNotRunning`, `MimirDiscardingSamples`, `PrometheusRemoteWriteFailing`,
  `PrometheusRemoteWriteBehind`, `MimirRGWBackendDown`, `MimirVIPNotHeldOnce`.
- **Backfill** of a Prometheus' local history (`mimirtool backfill`): see the runbook file above.

## Postgres HA: Patroni

Grafana's database moves from the single Postgres container on mon01 to a **Patroni cluster** on pg01-03
(`role = "postgres"`, titania/fortuna/venom), deployed by `terraform_data.postgres["<vm>"]`
([`postgres.tf`](postgres.tf), [module `postgres.tf`](../../modules/services/monitoring/postgres.tf)).
Live steps: `~/network_automation/mon-ha/runbook-postgres.md`.

```
graf01/02 --sslmode=require--> VIP 10.13.11.104:5432 (keepalived on the Patroni leader; check = Patroni /primary)
   leader pgNN: Postgres 18 <-- streaming replication (VLAN 217) -- 2 replicas (pg_rewind, slots)
   Patroni x3 <--> etcd x3 (DCS, VLAN 217)      archive_command / daily full backup --> pgBackRest
   --> https://127.0.0.1:7443 haproxy --> RGWs (bucket postgres, path /lylat-pg18, PITR 14 days)
```

| Network | pg01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.40-42 | SSH |
| VLAN 2 (`eth1`) | 10.2.11.40-42 | default route: Debian/PGDG packages, images |
| VLAN 13 (`eth2`) | 10.13.11.40-42 | backend: Grafana -> VIP `10.13.11.104`, scrapes (8008, 2381, 9187, 9100, 8405) |
| vmbr27 (`eth3`) | 10.27.11.40-42 | Ceph public network: haproxy -> RGWs |
| VLAN 217 (`eth4`, L2VNI `ha_postgres`) | 10.21.15.40-42 | replication, etcd (2379/2380), Patroni REST (8008), keepalived (vrid 104) |

- **Packages, not containers**, for the database: Patroni starts/stops Postgres itself and
  `archive_command` needs pgBackRest next to it; the only image with all of it is Spilo (Kubernetes-oriented,
  env-generated config, its own WAL-G cron). PostgreSQL 18 (`postgres_settings.pg_major`), Patroni 4.1 and
  pgBackRest 2.60 come from the PGDG repository (`apt.postgresql.org`, `trixie-pgdg`; Debian 13 has 17 only),
  etcd 3.5 from Debian. The deploy installs the PGDG source, key and an apt pin (only the Patroni stack from
  PGDG) before any package. `postgres_settings.package_versions` pins the series: a package outside it is
  upgraded to the apt candidate, and the deploy fails if that doesn't match either. Package scripts can't
  start or restart services during the deploy (`policy-rc.d`), unattended-upgrades skips the stack; upgrade
  minors rolling (runbook). haproxy, postgres_exporter, node_exporter and Alloy are Quadlet containers as
  everywhere else.
- **A new Postgres major is a rebuild**, not pg_upgrade: `pg_major` gives it its own Patroni scope and
  pgBackRest stanza (`<cluster_name><pg_major>`, now `lylat-pg18`) and data dir
  (`/var/lib/postgresql/patroni/<major>`); etcd keeps `cluster_name`. The data moves by dump/restore. The
  17 -> 18 run (2026-11-12): DT-046 (steps and rollback recipe in its description).
- **pgBackRest** only speaks HTTPS to S3, so each member's haproxy terminates TLS on `127.0.0.1:7443` with the
  host's snakeoil certificate (unverified: loopback). S3 keys: `postgres_s3` in `postgres.secret.auto.tfvars`
  (git-ignored), on the VMs only in `/etc/postgres-ha/s3.env` (0600).
- **Passwords** (`random_password.pg_*`): superuser, replication, REST API (`patroni.env`), `pgmon`
  (exporter); Grafana's role reuses Grafana's existing DB password. `pg-leader-setup` (oneshot, every deploy,
  leader only) creates the roles, database `grafana`, the stanza and the first full backup.
- **Deploys never restart Patroni** (it would stop Postgres, and fail over on the leader): its config is
  SIGHUP-reloaded; env/unit changes need a rolling restart. The first deploy must run all members together
  (etcd/Patroni bootstrap); later changes with `-parallelism=1`. `sudo pgctl ...` on a member wraps patronictl.
- **Cutover switches** (`postgres_settings`): `grafana_on_cluster = true` points both Grafanas at the VIP
  (after the runbook's dump/restore); `legacy_on_primary = false` (a separate apply after it) removes mon01's
  container (its data dir stays). A plan-time guard (`terraform_data.postgres_cutover`) refuses removing the
  container Grafana still uses. `bootstrap_from_backup` (+ `restore_target_time`) rebuilds a lost cluster
  from the repository.
- **Monitoring**: jobs `patroni`, `etcd`, `postgres`, `haproxy-postgres` (both Prometheus replicas), node
  targets `role=postgres` (pgBackRest results through the textfile collector), alert group `postgres`
  (no/split leader, members missing, replica not streaming/lagging, pending restart, WAL archive failing/stale,
  backup failed/too old, etcd no leader/quorum lost/members missing, RGW down, VIP not held once), and the
  "Postgres (Patroni, Grafana's database)" row on the Monitoring stack dashboard. Alloy ships the journal
  (Patroni and Postgres log there) to Loki.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Key for `config.ssh_username` on the VMs (needs passwordless sudo) |
| `deploy_revision` | `"1"` | Change to force a redeploy, e.g. after rebuilding a VM |
| `backend_vlan_id` | `13` | VLAN whose NIC address Grafana and Postgres use |
| `ha_vlan_id` | `214` | HA VLAN of the logging VMs (Loki ring, VRRP adverts); each logging VM needs one addressed NIC on it |
| `logging_settings` | see `variables.tf` | VIPs, VRRP router id (40), RGW endpoints, Loki retention (90d) and replication (3), schema start, sources allowed to Loki's HTTP port, extra syslog sender IP => host names |
| `loki_s3` | `null` (required with logging VMs) | Loki's S3 bucket and RGW keys, in the git-ignored `logging.secret.auto.tfvars` |
| `metrics_ha_vlan_id` | `216` | HA VLAN of the Mimir VMs (memberlist, gRPC, VRRP); each needs one addressed NIC on it |
| `metrics_settings` | see `variables.tf` | [Mimir](#metrics-mimir-ha): VIP (`10.13.11.103/16`), VRRP router id (103), RGW endpoints, RF (3), retention (396d), HA tracker labels, `drop_labels`, limits, sources allowed to Mimir's HTTP port |
| `mimir_s3` | `null` (Mimir off) | Mimir's S3 bucket and RGW keys, in the git-ignored `metrics.secret.auto.tfvars` |
| `monitoring_bridge` | `vmbr100` | Bridge of the backends' monitoring-network NIC |
| `monitoring_primary` | `"mon01"` | [Backend HA](#backend-ha-mon01--mon02): the backend with Postgres and the default `influxdb` provider; the other `role = "monitoring"` VM (at most one) is the replica |
| `monitoring_ha_vlan_id` | `215` | HA VLAN of the backends (L2VNI `ha_monitor`): keepalived adverts, Alertmanager gossip; each backend needs one addressed NIC on it |
| `backend_vrrp` | VIPs `10.5.11.102/16`, `10.13.11.102/16`, router id 102 | keepalived on the backends (password generated); `null` = no VIPs, Grafana uses the primary |
| `influxdb_replica_ready` | `false` | Stage 2: make mon02's buckets/tokens (provider `influxdb.replica`), its Proxmox metric servers and WLC Telegraf, and the relay's writes to it. Set once mon02's InfluxDB runs |
| `vyos_influx_relay_port` | `8087` | The InfluxDB write relay VyOS Telegraf uses (on the monitoring VIP); `null` leaves it out |
| `pve_monitoring_bridge` | `"100"` | `pve_network.bridges` key for the Proxmox nodes' scrape addresses |
| `images` | pinned tags | Container images; override one key at a time |
| `settings` | see `variables.tf` | Prometheus retention (90d / 120GB), InfluxDB org/initial bucket/retention, the Grafana InfluxDB datasource's default bucket (`pve_cluster`), Grafana root URL, DNS probe zone |
| `pve_api_token`, `greatfox_api_token` | required | Proxmox API tokens for the metric servers, from the linked `proxmox.secret.auto.tfvars` |
| `pve_api_node` | `null` (`nodes.cluster_api_node`) | Cluster node whose API manages the cluster's metric server; set another node if that one is unreachable |
| `pve_metrics` | see `variables.tf` | Proxmox metric servers: `enabled`, bucket names (`pve_cluster`, `pve_<standalone host>`), `retention_days` (90) |
| `pve_exporter_token` | `null` | PVE API token; `null` leaves pve-exporter out |
| `grafana_admin_password`, `influxdb_admin_password` | `null` (generated) | Fixed UI passwords; set them in a git-ignored `*.secret.auto.tfvars`. Only used when Grafana/InfluxDB first initialise. InfluxDB needs 8+ characters |
| `snmp_v3_auths` | `{}` | SNMPv3 credentials for snmp_exporter (git-ignored `*.secret.auto.tfvars`); written to `/etc/monitoring/snmp-exporter/auths.yml` and loaded as a second exporter config file. The WLCs' `lylat_v3` lives here |
| `wlc_telemetry` | `{ port = 57500, bucket = "wlc" }` | [C9800 telemetry](#c9800-telemetry-model-driven-dial-out): Telegraf's gRPC port on mon01 and its InfluxDB bucket (made here, with a write-only token; `pve_metrics.retention_days`). `null` leaves Telegraf, the bucket and the token out |
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

The logging VMs need `logging.secret.auto.tfvars` (see [Ceph RGW](#ceph-rgw-on-the-pve-nodes)) and
their VLAN 214 NIC before they can be planned. To dry-run a VM's deployment without installing
anything, copy its `deploy.sh` there and run `sudo bash deploy.sh check`: it pulls the images and
validates every config (`loki -verify-config`, `alloy validate`, `haproxy -c`, `nft -c`, and
`keepalived -t` once the package is installed).

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
- **greatfox unreachable = untargeted plans fail.** greatfox is a standalone PVE host (not in the
  cluster), reached on its own API. When it's down, any untargeted `plan`/`apply` of this root
  fails while refreshing `proxmox_metrics_server.standalone["greatfox"]` and
  `proxmox_metrics_server.standalone_replica["greatfox"]` (`dial tcp 10.20.7.20:8006`). Until it's
  back, exclude both:
  `tofu -chdir=roots/monitoring-config plan -exclude='proxmox_metrics_server.standalone' -exclude='proxmox_metrics_server.standalone_replica'`
  (same for `apply`). Nothing else here depends on them, so the rest of the root plans normally.
- **Grafana.com dashboard 12468** ("Cisco Catalyst 9800 - Client Stats") isn't provisioned: it is
  InfluxQL, which would need a DBRP mapping for `wlc` (the `komminarlabs/influxdb` provider has no
  resource for it) and a second, InfluxQL datasource. The measurements keep their YANG names, so it
  could still be added that way; the Wireless dashboards cover the same client stats.
- **The C9800 telemetry bucket and token come from the same API** ([`telegraf.tf`](telegraf.tf)),
  and the token is part of mon01's `deploy.sh`, so the backend deploy waits for them. On a
  freshly built mon01 (no InfluxDB yet), apply once with `wlc_telemetry = null`, then again
  without it.

## Next steps

1. Exporters on the remaining targets: `prometheus-node-exporter` on greatfox
   and the DNS VMs. The leaves get theirs from `fabric.settings.leaf_prometheus_exporters`
   (fabric-leaves) and the DHCP VMs from `dhcp_prometheus_exporters`
   (services-config).
2. keepalived VIP for Grafana on the backend VLAN.
3. A pve-exporter token, for VM/HA state in Prometheus.

## Tests

`tests/postgres.tftest.hcl` covers the Patroni cluster (Patroni/etcd configs on VLAN 217, pg_hba,
the guard, keepalived on `/primary` with vrid 104, pgBackRest via the TLS haproxy, deploy.sh packages/order,
scrapes/alerts, the Grafana cutover and mon01 container switches and their guard, `bootstrap_from_backup`).
`tests/metrics.tftest.hcl` covers Mimir (config per VM, HA tracker and limits, remote_write and the
datasource switch, keepalived, deploy.sh, and that nothing Mimir-related renders without `mimir_s3`).
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
dashboard, no restart for JSON changes, stale files pruned), that a missing
backend NIC fails the plan, and the logging stack: Loki's ring on the HA VLAN, RF 3, S3 through the
local haproxy, ruler to both Alertmanagers, no S3 keys in `loki.yaml`; the exact keepalived config per VM
(single instance over `eth5`, VIPs on the client NICs, priorities 150/100/50); Alloy's three syslog
listeners, `raw` with the experimental flag, sender-address host names from `snmp_targets`, journal-only
Alloy on mon01/graf pushing to the VIP; haproxy's RGW backends; the Loki/Alloy/haproxy/node scrape
jobs and logging alerts; the Loki datasource; the validations in each logging `deploy.sh`; and that a
missing `loki_s3` or VLAN 214 NIC fails the plan. For the C9800 telemetry (`wlc_telemetry`): the
bucket and its write-only token, Telegraf started right after InfluxDB, its unit (MDT port published
on the monitoring address only, `User=telegraf`, token from a 0600 env file, SIGHUP reload), the
config check and gRPC health check in `deploy.sh`, the `telegraf` scrape job and alert, and that
`wlc_telemetry = null` leaves all of it out. The two wireless dashboards carry the `wireless` tag and
dropdown, query only the provisioned InfluxDB datasource and the `wlc` bucket, and pick WLCs by the
`source` tag. Backend HA (`backend_ha`, `backend_replica_ready`, `backend_vrrp_disabled`,
`backend_ha_nic_required`): identical scrapes with per-replica `__replica__`, alerts without it to both
Alertmanagers, Postgres on mon01 only, Alertmanager gossip on VLAN 215, the keepalived config (VIPs on
eth2/eth3, adverts over eth4, vrid 102, mon01 first) and the VIP publishes, Grafana's VIP and per-replica
datasources, the replica's buckets/tokens/metric servers and WLC Telegraf only with `influxdb_replica_ready`,
the relay's outputs, and that a missing VLAN 215 NIC fails the plan.

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config test'
```
