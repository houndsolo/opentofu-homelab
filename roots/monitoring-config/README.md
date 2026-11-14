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
| backends (mon01 primary, mon02 replica; [Backend HA](#backend-ha-mon01--mon02)) | `prometheus`, `alertmanager` | monitoring network (`10.5.11.30`/`.31`) and the backend NIC in lylat-obs (`10.54.16.30`/`.31`): 9090, 9093; Alertmanager also on the backend VIP `10.54.16.102`; Alertmanager gossip 9094 on the ha_monitor segment (VLAN 1016, `10.50.16.30`/`.31`) |
| | `postgres` (Grafana's old database), **mon01 only** | removed since the Patroni cutover (`postgres_settings.legacy_on_primary = false`); was backend address `:5432` |
| | `snmp-exporter`, `blackbox-exporter`, `pve-exporter` | not published; Prometheus reaches them by name on the `monitoring` Podman network |
| | `telegraf` ([C9800 telemetry](#c9800-telemetry-model-driven-dial-out), `wlc_telemetry`) | gRPC MDT receiver on the monitoring network only: `10.5.11.30:57500` (mon02: `.31`) and the monitoring VIP `10.5.11.102:57500` (`wlc-telemetry-vip`, where the WLCs send); its own metrics on the backend address, 9273; the `wlc_*` series on 9275 (all addresses) |
| | `keepalived` (Debian package) | VRRPv3 (router id 102) unicast over IPv6 on the ha_monitor segment (`fd69:5016::30`/`::31`); VIPs `10.5.11.102/16` (vmbr100 NIC, eth2) and `10.54.16.102/16` (lylat-obs NIC, eth1) |
| | `node-exporter` | lylat-telemetry address (`10.55.16.30`/`.31`), 9100 |
| | `monitoring-network` | the Podman bridge network itself |
| grafana VMs (graf01/02) | `grafana` | 3000 on every address (lylat-app NIC for the proxy, VIP `10.52.11.100` included), 9094 (alerting HA gossip) on the Grafana HA segment (VLAN 1011) |
| | `keepalived` (Debian package) | VRRPv3 (router id 100) unicast over IPv6 on VLAN 1011 (`fd69:5011::32`/`::33`); VIP `10.52.11.100/16` on the lylat-app NIC |
| | `node-exporter` | lylat-telemetry address, port 9100 |
| every VM of this root | `alloy` (journal -> Loki telemetry VIP `10.55.18.101`; the log VMs push to their local Loki) | lylat-telemetry address, port 12345 (metrics) |
| logging VMs (loki01-03) | `loki` | 3100 (HTTP) on every address, limited by `logging-guard` to loopback and `loki_allowed_sources` (lylat-app, lylat-obs, lylat-telemetry); ring (gRPC 9095, memberlist 7946) on the HA segment (VLAN 1018) |
| | `alloy` (syslog receiver + journal) | syslog on every address (VIPs included): TCP 514 (RFC 5424), UDP 514 (RFC 3164), UDP 1514 (raw); 12345 on the lylat-telemetry address |
| | `haproxy` (S3 to the Ceph RGWs) | `127.0.0.1:7480`; stats/metrics on the backend address, 8405 |
| | `keepalived` (Debian package), `logging-guard` (nftables) | VRRPv3 over IPv6 on the HA segment; VIPs `10.54.18.101` (lylat-obs), `10.5.11.101` (monitoring network), `10.55.18.101` (lylat-telemetry) (router id 101) |
| | `node-exporter` | lylat-telemetry address, port 9100 |
| Mimir VMs (mim01-03) | `mimir` ([Mimir HA](#metrics-mimir-ha)) | 8080 (HTTP) on every address (VIP `10.54.17.103` included), limited by `metrics-guard` to loopback and `metrics_settings.allowed_sources` (lylat-obs, lylat-app); ring (gRPC 9095, memberlist 7946) on the HA segment (VLAN 1017) |
| | `haproxy` (S3 to the Ceph RGWs) | `127.0.0.1:7480`; stats/metrics on the backend address, 8405 |
| | `keepalived` (Debian package), `metrics-guard` (nftables) | VRRPv3 (router id 103) over IPv6 on VLAN 1017; VIP `10.54.17.103/16` on the backend NIC (eth1) |
| | `node-exporter` | lylat-telemetry address, port 9100 |

Each VM's **backend NIC** is its zone segment (DT-090, `backend_vlan_ids`): lylat-obs (VLAN 1401,
10.54.0.0/16) for mon, Loki and Mimir, lylat-app (VLAN 1201, 10.52.0.0/16) for Grafana, lylat-data
(VLAN 1601, 10.56.0.0/16) for Postgres. It carries the default route (the zone's anycast gateway
`10.Z.0.1`); Grafana reaches its datasources and Postgres through the zones' route imports. Scrapes and
Alloy's log pushes use **lylat-telemetry** (VLAN 1501, 10.55.0.0/16, an isolated VRF). The **monitoring
network** (vmbr100, 10.5.0.0/16) is where you open the Prometheus/Alertmanager UIs and where the Proxmox
nodes and the C9800 WLCs push metrics.

Both Grafana VMs share one Postgres database, so users, sessions, dashboards
and alert state are the same on either. Datasources and [dashboards](#dashboards)
are provisioned from files, so a rebuilt VM comes back identical. Grafana's unified alerting peers over the
Grafana HA segment (VLAN 1011, L2VNI `ha_grafana`, `10.50.11.32/.33:9094`), so an alert isn't sent twice.
keepalived (`grafana_vrrp`, router id 100) holds the VIP `10.52.11.100/16` (`grafana-vip`; users go through
https://grafana.lylat.space on the proxy) on the lylat-app NIC: VRRPv3 adverts go unicast over IPv6 on VLAN 1011,
both VMs start BACKUP with `nopreempt` (graf01 wins the
first election), and a failing `/api/health` check puts a VM in FAULT, which releases the VIP. If a Grafana
VM has no addressed NIC on `grafana_ha_vlan_id`, gossip falls back to the backend NIC and the plan
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
   Postgres starts as root and drops to its `postgres` user, so its data directory
   is owned by that user, looked up in the image (the entrypoint only fixes
   ownership when the container starts, so any other owner would lock out a server
   this deployment doesn't restart).
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
   checks (`/-/ready`, `pg_isready`, Grafana `/api/health`, Telegraf's ports) to pass.
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
| `/etc/monitoring/postgres.env` | Initial credentials (mode 0600) |
| `/etc/monitoring/telegraf/telegraf.conf`, `wlc.star` | Telegraf (C9800 telemetry) config and its starlark reshaping |
| `/var/lib/monitoring/{prometheus,alertmanager,postgres}` | Data. `/var/lib/monitoring/influxdb` is the retired InfluxDB's data, left in place until it is removed by hand ([Retired: InfluxDB](#retired-influxdb)) |
| `/etc/grafana-container/provisioning/datasources/datasources.yml` | Grafana datasources (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/dashboards.yml` | Grafana dashboard provider (graf VMs) |
| `/etc/grafana-container/provisioning/dashboards/files/<Folder>/*.json` | Provisioned dashboards (graf VMs) |
| `/etc/grafana-container/grafana.env` | Grafana secrets (mode 0600) |
| `/var/lib/grafana-container` | Grafana plugins/cache; real state is in Postgres |
| `/etc/alloy/config.alloy`, `/var/lib/alloy` | Alloy config and positions (every VM) |
| `/etc/logging/loki/loki.yaml`, `loki/rules/fake/*.yaml`, `/etc/logging/loki.env` | Loki config, ruler rules, S3 keys (mode 0600) (logging VMs) |
| `/var/lib/logging/loki` | Loki WAL, TSDB index cache, compactor and ruler state (chunks are in S3) |
| `/etc/logging/haproxy/haproxy.cfg` | haproxy (S3 -> RGWs) |
| `/etc/keepalived/keepalived.conf` | VRRP (mode 0600) |
| `/etc/logging/guard.nft`, `/etc/systemd/system/logging-guard.service` | nftables table `inet logging_guard` for Loki's ports |

Logs: `journalctl -u prometheus` (and so on). Status: `systemctl status prometheus`.

## Scrape targets

They come from the same inventory the other roots use. Adding a node, leaf or
service VM updates Prometheus on the next apply.

| Job | Targets | From |
| --- | --- | --- |
| `node` | every service VM on its lylat-telemetry address (this root's VMs and services-config's DNS, Valkey, NetBox, proxy and ticketing VMs; label `role`), Proxmox nodes (`cidrhost(vmbr100 prefix, id)`) | `vms`, `nodes`, `pve_network` |
| `alloy` (:12345) | Alloy on every VM of this root, plus services-config's DNS, NetBox, proxy, Valkey and ticketing VMs (`targets.alloy`; services-config `alloy.tf`), all on their lylat-telemetry address | `vms` |
| `vyos-node` (:9100), `vyos-frr` (:9342) | every leaf (mgmt), DHCP VMs (mgmt), `vyos_extra_targets` (fw-wan) | `fabric`, `nodes`, `vms` |
| `snmp-<name>` | `snmp_targets`: FS switches, CRS317s and spines on their monitoring-network (10.5/16) addresses, where the MikroTiks bind their SNMP agent; the C9800 WLCs (10.5.1.1/.2) over SNMPv3 (`snmp_v3_auths`). The MikroTik jobs walk `mikrotik_lite` (below) and use a 30 s interval and 20 s `scrape_timeout` (RouterOS walks are slow) | variables |
| `pve` | cluster nodes' API, through pve-exporter (only with a token; standalone greatfox is left out) | `nodes` |
| `blackbox-icmp`, `blackbox-http_2xx` | `blackbox_icmp_targets`, `blackbox_http_targets` | variables |
| `blackbox-dns_soa` | each DNS VM's service address, `SOA lylat.space` | `vms` |
| `grafana` | each Grafana VM's `/metrics` on its backend (lylat-app) address | `vms` |
| `telegraf` | Telegraf's own `internal_*` metrics (`telegraf:9273` on the Podman network), with `wlc_telemetry` | variables |

Most targets **don't run an exporter yet**, so they show as down (`up == 0`)
until they do. See [Next steps](#next-steps).

### The `mikrotik_lite` SNMP module

The bundled `mikrotik` module in snmp_exporter's `snmp.yml` walks the whole MIKROTIK-MIB
(`1.3.6.1.4.1.14988`): ~2,400 PDUs per CRS3xx, including modem, CAPsMAN, GPS, partitions,
gauges, optics and 72 interface-stats columns. On RouterOS that took 5-17 s and pushed the
MikroTik jobs into their 20 s timeout (DT-023). The MikroTik jobs walk `mikrotik_lite` instead.

- **Contents:** the same metric definitions, but only for what the `mikrotik-snmp` dashboard queries:
  - the board/firmware/license scalars and health sensors, in one GET;
  - the MNDP/LLDP neighbor table;
  - the 34 interface-stats columns the dashboard's interface table shows.
- **Effect:** about half the PDUs. With `max_repetitions: 50`, the median walk went from 10.0 s to 5.5 s, and the max from 17.6 s to 8.0 s.
- **Files:**
  - `modules/services/monitoring/snmp/mikrotik_lite.yml` is generated; don't edit it.
  - `snmp/build-mikrotik-lite.sh` (its `KEEP` list) is the source.
  - The exporter loads the module as a second `--config.file` next to the bundled `snmp.yml`, and `deploy.sh` dry-runs that set before installing it.
- **To add a metric:** add its name to `KEEP`, then regenerate from the image's `snmp.yml` (the commands are at the top of the script) and apply. Also regenerate after bumping `images.snmp_exporter`.

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
| Overview | lylat.space overview (`lylat-overview`) | custom (Prometheus + Loki) | **Status:** targets up/down, firing alerts, failing probes, BGP and BFD across the fabric. **Services:** an HA services tile (Grafana, Prometheus, Alertmanager, Mimir, Loki, Alloy, Postgres, etcd, Valkey, NetBox, dark-triage, DNS, nginx proxy: OK / DEGRADED / DOWN by the share of members answering, Postgres and Valkey also need exactly one leader/primary; click a tile for its dashboard), the keepalived VIPs and which VM holds each (node_exporter address-info), the published HTTPS sites and the certificate's remaining lifetime. **Databases:** Postgres leader, replicas streaming and lag, commits/s, Valkey primary and memory, NetBox's queued RQ jobs. Then Ceph (health, raw used, client IOPS/throughput, OSDs down / PGs not clean), Proxmox (nodes, guests, lylat CPU/memory, fullest storage), Edge (fw-wan up, WAN, VPN tunnels, firewall drops, conntrack), targets per job / per target and the firing alerts, probe status, BGP/BFD over time and EVPN totals, the host/router table (state, CPU, memory, disk, load, conntrack, uptime; click a host for Node Exporter Full or its logs), the top 10 interfaces from node_exporter and SNMP, and log volume by source plus the noisiest hosts |
| Hosts | Node Exporter Full (`node-exporter-full`) | [grafana.com 1860](https://grafana.com/grafana/dashboards/1860) rev 46 | Everything node_exporter collects, for one host. Pick the job (`node` for the VMs, `vyos-node` for the VyOS routers), then the host |
| Network | FRR / EVPN fabric (`frr-evpn-fabric`) | custom | BGP peer table (router, VRF, AFI/SAFI, peer, hostname, ASNs, state, uptime, prefixes rx/tx, message rates), session state timeline, established sessions per router, flaps in the time range, BFD peers, EVPN remote VTEPs/MACs/ARP-ND per router and per L2 VNI, routes per VRF, RIB vs FIB, BGP RIB, frr_exporter health. Router and VRF pickers |
| Network | SNMP Device Summary (`snmp-device-summary`) | [grafana.com 12489](https://grafana.com/grafana/dashboards/12489) rev 5 | Per device: interfaces up/down, top talkers, traffic on all interfaces, interface table (uptime for jobs with the `system` module) |
| Network | SNMP Interface Detail (`snmp-interface-detail`) | [grafana.com 12492](https://grafana.com/grafana/dashboards/12492) rev 4 | Per interface: status, speed, traffic, unicast/multicast/broadcast packets, errors, discards |
| Edge | fw-wan overview (`fw-wan-overview`) | custom (Prometheus + Loki) | The VyOS edge router. **Status:** ICMP, exporters, uptime, WAN address, WAN in/out (sparklines), CPU, memory, conntrack table, BGP sessions, VPN tunnels, VyOS services, systemd units failed/restarting, firewall drops + rejects. **Traffic:** WAN (in up, out down), traffic per VRF (VRF devices), top interfaces with their VRF. **Firewall:** final verdicts (accept/drop/reject), drops + rejects per chain, NAT connections. **VPNs:** tunnel state timeline, VTI/WireGuard traffic. **System:** CPU by mode, memory, temperatures, softnet drops, load, units not active. Collapsed: interface table (VRF, description, state, MTU, speed, in/out, errors, drops), router syslog |
| Edge | fw-wan firewall (`fw-wan-firewall`) | custom (Prometheus + Loki) | Every IPv4/IPv6 filter chain (nft-metrics.py counters). **Summary:** final verdicts (accept/drop/reject per second), dropped + rejected in range, default-action drops per base chain, logged lines, rules missing from the snapshot, counter age. **Base chains:** input/forward/output verdicts by rule action (accept, → named chain, default drop/accept), default-action drops, what is being dropped (every drop/reject rule and default action). **Chains:** activity timeline, packets and traffic per chain. **Rules:** table (family, kind, chain, rule, action, jump target, match, packets/s, packets and bytes in range, totals), top rules, default actions hit. **NAT:** rule table (match/translation, connections per minute, in range, total) and connections per rule; conntrack entries, new connections, insert failures/drops/invalid; firewall log from the syslog (time, chain, rule, action, in/out, proto, addresses and ports) and logged packets per rule; collapsed rule and NAT reference |
| Edge | fw-wan VPNs (`fw-wan-vpn`) | custom (Prometheus + Loki) | IPsec connections, IKE state, CHILD SAs, WireGuard peers, BGP over the tunnels, vpn-metrics.py health; SA state timeline, SA age, rekeys in range, CHILD SA traffic and packets; VTI/WireGuard interface traffic, errors and drops, link state, tunnel interface table; WireGuard handshake age and peer traffic; BGP peers in `vpn_*` VRFs, prefixes, routes; VPN firewall chains; collapsed strongSwan log |
| Edge | fw-wan VRFs & routing (`fw-wan-routing`) | custom | Router picker (default fw-wan, works for the leaves and DHCP VMs) and VRF picker: BGP/BFD summary, routes, VRFs, route changes, RIB not in FIB; routing table per VRF (IPv4/IPv6 RIB and FIB, BGP RIB, sessions up, changes), routes and route changes per VRF; BGP peer table (state, uptime, prefixes, messages, flaps), session state, BGP RIB, prefixes rx/tx, messages; traffic per VRF, interface traffic and table with the VRF (fw-wan); collapsed BFD peers and frr_exporter collectors |
| Network | Wireless (C9800) (`wireless-overview`) | custom (Prometheus: `wlc_*`, job `wlc`) | The C9800 WLCs' [model-driven telemetry](#c9800-telemetry-model-driven-dial-out). **Status:** clients, APs joined, radios up/total and down, WLANs with clients, telemetry age per WLC, SNMP up. **Controllers:** table (HA role, clients, radios, Linux CPU, IOSd CPU, load, memory; click a WLC for its logs), CPU per core, memory, IOSd CPU and load. **Access points:** AP table (state, clients, IP, model, serial, software, mode, uptime, joined for, uplink state and speed, tags, last disconnect reason, certificate expiry; click an AP for its join/leave lines), radio table (band, state, channel and bonded channels, width, tx power and level, clients, channel busy, tx/rx/non-Wi-Fi airtime, tx/rx traffic, last channel change, BSS color), channel busy, clients, traffic, channel, tx power and retries/failures per radio. **RF environment:** airtime breakdown per radio, AP uplink traffic, noise floor / strongest other network / other networks' airtime / other APs per scanned channel. **SSIDs:** WLAN table (clients, random-MAC clients, download/upload), clients per WLAN, traffic per SSID. **Clients:** table (MAC, IP, AP, SSID, band, protocol, channel, RSSI, SNR, PHY rate, MCS, streams, download/upload, retries, state, security, connected for; click a client for its history), clients per WLC and by band/protocol, RSSI and throughput per client. Collapsed: the WLCs' own interfaces from SNMP. WLC picker |
| Network | Wireless client (C9800) (`wireless-client`) | custom (Prometheus: `wlc_*`, job `wlc`) | One client (MAC picker, most recently seen first): its row of the clients table, RSSI/SNR, PHY rate and spatial streams, throughput and packets (download up, upload down), retries/drops/decrypt and MIC errors, and a timeline of its AP, SSID (a row each) and channel (roams) |
| Network | Mikrotik monitoring (`mikrotik-snmp`) | [grafana.com 14420](https://grafana.com/grafana/dashboards/14420) rev 9 | MikroTik `mikrotik_lite` module: board/firmware, CPU temperature, per-interface traffic and Ethernet error counters, interface table, neighbors (MNDP/LLDP) |
| Probes | Blackbox probes (`blackbox-probes`) | custom | ICMP/HTTP/DNS SOA probes: status, availability over the time range, duration, ICMP RTT and hop limit, HTTP status/phases (no TLS)/size, DNS query time, SOA serial and drift between the DNS servers |
| Monitoring | Monitoring stack (`monitoring-stack`) | custom | Component status and versions, config reloads; Prometheus targets per job, scrape duration, samples, head series, TSDB size, ingestion, rule evaluation, query latency; Alertmanager alerts, silences, notifications; Grafana requests, latency, datasource queries, DB connections, alerting; **Loki and Alloy**: up, ACTIVE ring members per ring, unhealthy/memberlist members, RGWs UP per haproxy, flush failures, Alloy drops and syslog parse errors, lines/bytes received, Alloy sent/received, chunks flushed to S3, S3 requests and p95 latency, in-memory streams and flush queue; SNMP/FRR/node exporter scrape times; **Telegraf** (C9800 telemetry, pvestatd): metrics received per input, output buffer; process memory and CPU |
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
| Proxmox | Proxmox overview (`proxmox-overview`) | custom (Prometheus, job `pvestatd`) | **Cluster:** nodes up/down, guests (running VMs/CTs, stopped, templates), CPU and memory over all nodes (sparklines), vCPUs and memory allocated to running guests vs the nodes' cores and RAM. **Nodes:** table (state, uptime, CPU, cores, load per core, IO wait, memory, RAM, swap, root FS, guests, physical NIC in/out; click for Proxmox node). **Node trends:** CPU, memory, load per core, physical NIC traffic, IO wait per node. **Guests:** top 10 by CPU, memory, disk I/O and network, running guests over time, guest CPU per node. **Storage:** used % per storage (shared ones once) and over time |
| Proxmox | Proxmox node (`proxmox-node`) | custom (Prometheus, job `pvestatd`) | One node (picker): state, uptime, CPU/memory/swap/root FS gauges, load per core, guests, cores/RAM/swap/disk, node_exporter state (click for Node Exporter Full); CPU and IO wait, load averages vs cores; memory (used/available, ZFS ARC where there is one), swap, root FS; physical NICs, bridges and bonds, interface table; its guests (table, click for Proxmox guests; stacked CPU, memory, disk I/O and network); its storages; collapsed: temperatures and disk busy from node_exporter |
| Proxmox | Proxmox guests (`proxmox-guest`) | custom (Prometheus, job `pvestatd`) | Every guest on the selected nodes (table: type, node, status, uptime, vCPUs, CPU, memory used/configured, disk size, disk and net rates, tags), then one guest (picker by name, value = vmid): status, type, node, uptime, vCPUs, memory, disk size, tags, CPU/memory/balloon/CT root disk gauges, pressure (PSI); CPU, memory (used, host, configured, balloon target), pressure; disk throughput, per-disk IOPS, latency and throughput, CT root disk, I/O errors; network total and per NIC; collapsed: balloon, guest page faults and swap |
| Proxmox | Proxmox storage (`proxmox-storage`) | custom (Prometheus, job `pvestatd`) | Used % per storage (shared ones once, local ones per node), count/inactive/fullest, Ceph health and raw used (click for Ceph cluster); storage table (type, shared, content, used, available, total, %, growth per day over the time range, when it's full at that rate; click: Ceph storages open Ceph cluster, local ones their node); used, used % and free over time; collapsed: local storage used per node. Storage picker |
| Logs | Logs overview (`logs-overview`) | custom (Loki) | Lines, lines/s, errors and warnings in range, hosts sending, syslog parse errors; lines by source, level and host, errors/warnings by host; noisiest hosts (click to filter) and apps, most errors; newest errors table; log browser. Source, host, app, level and search (regex) pickers |
| Logs | Network device logs (`logs-network`) | custom (Loki) | Leaves, fw-wan, MikroTik spines/CRS317, FS switches, C9800 WLCs: event counts (BGP/BFD, interface up/down, STP, auth failures, logins, config changes, AP join/leave, client failures), events per device (status history), events by category, lines per device; BGP and BFD session changes of the VyOS routers from frr_exporter (Prometheus: changed or restarted sessions, state timeline), RouterOS session state lines, interface events, STP, logins/auth failures/config changes, AP join/leave table, client failures, Cisco/FS message types; all device logs. Device and search pickers |
| Logs | fw-wan firewall & VPN logs (`logs-fw-wan`) | custom (Loki) | Firewall log parsed with LogQL (chain, rule, action, in/out, proto, addresses, ports): logged/dropped/rejected/accepted, distinct sources and ports, by rule/action/interface, top dropped sources, destinations, ports and rules, firewall log table; strongSwan IKE events (initiating, established, retransmits, failures, deletes), initiations per connection, charon log without packet traces, WireGuard; config commits and the rest of the router log. Action, address and search pickers |
| Logs | Proxmox & Ceph logs (`logs-proxmox`) | custom (Loki) | PVE nodes: errors, warnings, failed and started tasks, corosync, HA and auth events; lines by node and app; corosync events, corosync/pmxcfs and HA logs; tasks by type and task table; guest lifecycle, PVE daemons, kernel warnings. Ceph cluster log (one mon's copy): health checks raised/cleared, HEALTH_ERR, OSD events, slow ops; by severity, health checks per bucket and in range, health changes, OSD events and slow ops, the log without DBG, Ceph daemons and kernel client. Node, Ceph mon and search pickers |
| Logs | Services logs (`logs-services`) | custom (Loki) | BIND: transfers, notifies, DNSSEC validation and resolution errors, queries (if logged), messages by kind, zone transfer table, log. Kea: leases, NAKs, allocation failures, HA state changes and comms problems, messages by code, leases and HA transition tables, log. keepalived: who became MASTER of each VRRP instance, transitions, state change table. Monitoring stack containers: errors/warnings by container, haproxy, Loki/Alloy, Prometheus/Alertmanager and Grafana logs. Container and search pickers |
| Databases | Postgres cluster (Patroni) (`postgres-cluster`) | custom (Prometheus + Loki) | The Patroni cluster behind Grafana, NetBox and dark-triage. **Status:** leader, VIP holder, a checks tile (one leader, VIP on the leader, replicas streaming and < 1 MiB behind, leader lock, auto failover, etcd quorum, WAL archived < 1 h, backup < 36 h, RGW reachable), timeline and leader changes in range, last full backup and last WAL archived, connections used, the leader's WAL rate. **Members** table (role, state, VIP, timeline, streaming, replay lag, pending restart, DCS key age, uptime, version, connections, WAL held by slots; click for the instance dashboard or logs). **Failover history:** role timeline and Patroni's promote/demote/switchover lines. **Replication:** replay lag in bytes and time, WAL written vs received, the leader's walsenders, WAL kept for slots. **Apps and connections:** app probes, connections per database and by state, commits and rows written per app database, longest open transaction, database size and growth. **WAL, archive and backups:** pgBackRest results, segments archived/failed, pg_wal vs max_wal_size, checkpoints and their write/sync time, RGWs behind haproxy. **etcd:** role timeline, WAL fsync/commit p99 against the 300 ms heartbeat, leader changes and failed proposals, peer RTT, Patroni's key age vs ttl, db size. **Hosts:** CPU, memory, vda busy/await, root FS. Collapsed: Postgres errors, Patroni/pgBackRest/etcd warnings. Cluster (scope) picker |
| Databases | Postgres instance (`postgres-instance`) | custom | One member (picker) and its databases (picker): role, exporter, version, uptime, connections, cache hit, commits, deadlocks/conflicts; backends by user, state and wait event, transactions, rows read/written; cache hit ratio, block reads vs hits, temp files, bgwriter/checkpointer, checkpoints, pg_wal; locks by mode, longest transaction, xid wraparound age; key settings and settings that differ between members; collapsed: postgres_exporter collectors |
| Databases | Prometheus (`prometheus-server`) | custom (Prometheus + Loki) | The HA pair mon01/mon02 (7 d / 20 GB local, remote_write to Mimir). **Status:** the replica Mimir keeps and HA failovers, a checks tile (13 tests mirroring the Prometheus alerts: config reload, TSDB/rule/scrape failures, remote_write behind, size < 80 % of 20 GB, both Alertmanagers seen), samples/s, head series, size vs the 20 GB cap, history vs 7 d, remote_write lag, alerts; replicas table. **TSDB head**, **storage and retention**, **WAL and compactions**, **scrapes** (per job: targets, samples, new series, slowest), **rules** (per group: duration, share of interval, misses), **remote write to Mimir** (sent/failed/retried, lag vs the 300 s alert, shards, pending), **Alertmanager notifications**, **queries and API**, **process**; collapsed: WARN/ERROR logs. Replica picker. Scrape/rule panels only show the replica Mimir keeps (Explore links for each replica) |
| Databases | Mimir (`mimir`) | custom (Prometheus + Loki) | mim01-03 (monolithic, HA tracker, S3 on Ceph RGW behind haproxy). **Status:** checks (ring members, one replica elected, discarded samples, remote_write, block uploads, compactor, RGW backend, VIP), active series vs the limit, samples/s, last compaction and block shipped, bucket size. **Ingestion** (pushed/stored/deduped, elected replica, discarded by reason), **series and limits**, **ingester storage and blocks to S3**, **compactor, retention and backfill uploads**, **store-gateway**, **queries** (by route, p50/p99, errors, scheduler), **object storage** (S3 ops/latency/failures, haproxy -> RGW), **rings and memberlist**, **process and VMs**; collapsed: warn/error logs. VM picker |
| Databases | Loki (`loki`) | custom (Prometheus + Loki) | loki01-03 (RF 3, chunks in RGW bucket loki) and the 24 Alloy senders. **Status:** VIP holders, elected compactor, checks mirroring the logging alerts, lines and bytes/s, streams, bucket size/objects, last retention run, discarded lines; instances table. **Ingestion** (per distributor, push status/p99, discards by reason, lines stored by host via LogQL), **ingesters and chunks**, **WAL and checkpoints**, **ring and memberlist**, **queries**, **object storage**, **compactor and retention**, **ruler**, **Alloy senders** (table, entries, drops/retries, push latency, journal/syslog input), **resources**; collapsed: Loki and Alloy logs. Instance and sender pickers. dns/proxy Alloys push to all three Lokis: per-sender panels use the max over endpoints |
| Databases | Telegraf (`telegraf`) | custom (Prometheus + Loki) | The WLC telemetry Telegraf on mon01/02 (gRPC dial-out to the monitoring VIP: VIP holder, telemetry received, `wlc_*` series per WLC, wlc.star processing), the pvestatd listener (writes, wrong-token rejections, PVE nodes, series by object) and fw-wan's VyOS Telegraf. Checks mirror WlcTelemetry*, PveMetrics*, TargetDown and MonitoringVIPNotHeldOnce. Per instance: inputs (gathered, errors, gather time), outputs (written, dropped, buffer fill, write time), the InfluxDB outputs until retired, what Prometheus scrapes per job, process; collapsed: E!/W! logs. Instance picker |
| Databases | Valkey (NetBox cache and queue) (`valkey`) | custom (Prometheus + Loki) | valkey01-03 and their Sentinels. **Status:** primary, the primary each Sentinel reports, a checks tile (one primary, replicas linked, Sentinels agree, quorum, all Sentinels seen, memory < 80 % of maxmemory, AOF/RDB writes, exporters), failovers in range, memory, NetBox clients and idle RQ workers, ops/s, keys per db, RQ jobs queued. **Nodes** table (role, link, bytes behind, Sentinel, memory, clients, keys, AOF, uptime, version). Role timeline and Sentinel +switch-master/+sdown/+odown lines; replica lag, what each Sentinel sees, resyncs; NetBox's commands/s and p99 latency per command (the exporters' own commands left out), hit ratio, network, connections and error replies; RQ queue, failed jobs and workers; memory vs maxmemory, keys, expired/evicted, AOF, fragmentation, last RDB save; hosts; collapsed log |
| Services | nginx reverse proxy (`nginx-proxy`) | custom (Prometheus + Loki) | proxy01/02 behind proxy-vip (services-config proxy.tf). **Status:** VIP holder, nginx up per proxy, the published sites probed over HTTPS by name (job blackbox-https), certificate expiry and subject/issuer, requests/s, active connections, 5xx share and requests in range. **Sites (access log, `log_format lylat` parsed with `| logfmt`):** requests per site, responses by status class, request and upstream time p95 per site, a per-site table (requests, 2xx/4xx/5xx, p95, bytes), top paths and clients, failed requests. **Connections (stub_status):** requests/s per proxy, connections by state, accepted vs dropped. **Probes:** probe time per site and by phase. **Proxy VMs:** CPU, memory, network, VIP moves. **Logs:** nginx's error log, keepalived |
| Services | DNS (BIND) (`dns-bind`) | custom (Prometheus + Loki) | dns01/02 behind dns-vip (services-config main.tf; job `bind` = bind_exporter on the mgmt address :9119 reading BIND's statistics channel, services-config dns-bind-exporter.tf). **Status:** VIP holder, BIND up per server, the SOA probes, time since the last config load, zone serials per server, queries/s, cache hit ratio, SERVFAIL and NXDOMAIN share. **Queries:** by type, responses by rcode, per server, SERVFAIL/NXDOMAIN share per server, rejected/failed queries. **Recursion and cache:** recursions and queries to the forwarders, forwarder RTT p50/p95, recursive clients, resolver errors, DNSSEC validation, cache RRsets. **Zones:** serials over time, transfers ok/failed/rejected. **Probes:** SOA query time, serial and a current table. **DNS VMs:** CPU, memory, network, VIP moves. **Logs:** bind9, keepalived |

The SNMP dashboards need only `if_mib`, so they work for every SNMP job. A dropdown
in the top bar ("SNMP dashboards") switches between them and keeps the selected
device and time range. The device and host pickers show each target's `host` label.
The Ceph dashboards (`ceph` tag) likewise share a "Ceph dashboards" dropdown.

The Proxmox dashboards (`proxmox` tag) read what `pvestatd` pushes (see
[Things to know](#things-to-know)) as `pvestatd_<measurement>_<field>` series (job `pvestatd`,
10 s) from the default Prometheus datasource (Mimir); their panels have a 10 s minimum
interval. A **Cluster** picker selects the lylat cluster (every node but greatfox) or the
standalone greatfox. They share a "Proxmox dashboards" dropdown that carries the selected
cluster, node and guest along. Values shown "now" are instant queries at the end of the time
range (a guest that stops being reported drops out a minute later, when the pvestatd Telegraf
expires it); a node counts as down once it hasn't reported for a minute.

The fw-wan dashboards (`fw-wan` tag, folder Edge) share a "fw-wan dashboards" dropdown and
read Prometheus (jobs `vyos-node`, `vyos-frr`, `vyos-telegraf`, `blackbox-icmp`) plus fw-wan's
syslog in Loki (firewall log, router log, strongSwan log; notice and up for the last two). The firewall
and NAT counters are nft-metrics.py's (see [fw-wan](#fw-wan-vyos-edge-router-configured-by-hand));
Telegraf's `nftables_*` series aren't used. What a firewall rule does isn't in the counters, so
[`dashboards/fwwan_snapshot.py`](../../modules/services/monitoring/dashboards/fwwan_snapshot.py)
holds family/chain/rule → action, jump target and match, interface → VRF and the NAT rules, read from fw-wan's
config by [`fwwan_config.py`](../../modules/services/monitoring/dashboards/fwwan_config.py)
(see [Changing the dashboards](#changing-the-dashboards)). The firewall dashboard's "Rules not
in snapshot" turns orange when fw-wan has rules the snapshot doesn't know.

The wireless dashboards (`wireless` tag, folder Network) share a "Wireless dashboards" dropdown and
read the C9800 telemetry's `wlc_*` series (job `wlc`) from the Prometheus datasource (PromQL, uid
`prometheus`; see [C9800 telemetry](#c9800-telemetry-model-driven-dial-out)); the history from the
retired InfluxDB (bucket `wlc`, from 2026-11-09 on) is backfilled into Mimir under the same names. String leaves (AP/client names,
SSIDs, states, IPs) are labels of `wlc_<short>_info` series, joined in with `group_left`; timestamps
are `<field>_seconds` (Unix time, 0 = unset), shown as `time() - (x > 0)` (AP uptime and joined for,
client connected for).
The **WLC** picker filters on the series' `host` label (the WLC, `c9800-wlc-1/2`, the same as the
SNMP jobs'), so the SNMP panels follow it too. "Now" values are instant queries: Telegraf drops a
series 150 s after its last push, so clients and APs that leave drop out. The APs refresh their
counters only every 90 s (client traffic, per-SSID stats) or 180 s (radio and uplink counters, RRM),
and the WLC re-sends the old value in between, so rate panels have a minimum interval that makes
`$__rate_interval` at least 3 (or 6) minutes, the tables use `[3m]`/`[6m]`, and channel utilization
moves in 3-minute steps. Client traffic is from the AP's side: download is
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
the Proxmox & Ceph one in the "Ceph dashboards" dropdown. The fw-wan dashboards read the firewall and
strongSwan log from Loki too (the old Telegraf copy in InfluxDB bucket `vyos` was retired on 2026-11-13).

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
  The fw-wan dashboards read Loki since 2026-11-13, so their log tables show the same doubles for older
  ranges. The Ceph cluster log arrives once per mon: pick
  one with the Ceph mon picker. BIND writes everything to stderr, so its BIND panels go by the
  line, not the level.
- Hosts without an exporter yet (the standalone greatfox) show as DOWN in
  the target tables and are left out of everything else.
- **Proxmox dashboards:** the `pvestatd_*` series start on 2026-11-13 10:10Z; the history from the
  retired InfluxDB (`pve_cluster`/`pve_greatfox`, since 2026-11-09) is backfilled into Mimir under the
  same names. Trends, growth and "Full in" need a few days of history to mean much. PVE reports no disk usage
  inside VMs (`disk` is 0 without a guest agent query), so "Root disk (CT)" and "Root disk
  used (CT)" are containers only, and the per-disk IOPS/latency, per-NIC, balloon and
  "I/O errors" panels are VMs only (container NICs are veths on the node). Latency and the
  top-guest disk/network bars are empty while nothing does I/O. The balloon page-fault and
  swap panels need the guest's balloon driver to report stats (empty for the C9800 WLCs).
  There is no KSM or per-node pressure data in pvestatd's output, and no ZFS on the cluster
  nodes (ARC stays hidden). node_exporter panels on the node dashboard are empty for
  greatfox (no exporter). pvestatd's strings aren't exported: a guest's status is running or
  stopped only (paused/suspended read stopped), the interface table's Type follows PVE's
  physical-NIC name rule, and the QEMU version/machine are not shown. A storage's `content`
  label arrives in a different order per push, so storage queries collapse it (max by host, nodename).

### Changing the dashboards

- **Community dashboards:** edit the list in
  [`dashboards/update.py`](../../modules/services/monitoring/dashboards/update.py)
  and run `python3 -I modules/services/monitoring/dashboards/update.py`. The script
  downloads the pinned revision (grafana.com revision, or the ceph-mixin commit
  `CEPH_MIXIN_COMMIT` on the tentacle branch) and points every query at the provisioned
  Prometheus datasource (uid `prometheus`). It also drops the import-time
  datasource inputs and variables, and sets the host picker, uid, tags and links.
- **Custom dashboards:** edit
  [`dashboards/custom.py`](../../modules/services/monitoring/dashboards/custom.py)
  and run `python3 -I modules/services/monitoring/dashboards/custom.py`. It writes
  the JSON offline. Don't edit the generated JSON by hand. The Proxmox dashboards' builders
  (PromQL on `pvestatd_*`) live in [`dashboards/pve.py`](../../modules/services/monitoring/dashboards/pve.py),
  which `custom.py` imports and runs; the fw-wan ones' in
  [`dashboards/fwwan.py`](../../modules/services/monitoring/dashboards/fwwan.py), the log
  dashboards' (LogQL) in [`dashboards/logs.py`](../../modules/services/monitoring/dashboards/logs.py),
  the wireless ones' (PromQL on the C9800 telemetry's `wlc_*`) in
  [`dashboards/wireless.py`](../../modules/services/monitoring/dashboards/wireless.py), whose docstring
  lists the metric and label names it relies on; the Databases ones (Postgres/Patroni, Valkey) in
  [`dashboards/databases.py`](../../modules/services/monitoring/dashboards/databases.py), the metrics and logs
  stores' deep dives in [`promtsdb.py`](../../modules/services/monitoring/dashboards/promtsdb.py), [`mimir.py`](../../modules/services/monitoring/dashboards/mimir.py),
  [`loki.py`](../../modules/services/monitoring/dashboards/loki.py) and [`telegraf.py`](../../modules/services/monitoring/dashboards/telegraf.py), the nginx
  reverse proxy's in [`dashboards/nginx.py`](../../modules/services/monitoring/dashboards/nginx.py), DNS
  (BIND)'s in [`dashboards/dns.py`](../../modules/services/monitoring/dashboards/dns.py). After
  changing fw-wan's firewall, NAT, interfaces or VRFs, refresh the snapshot first (reads the
  config over `ssh vyos@10.20.10.255`, keeps only those paths) and commit both:
  `python3 -I modules/services/monitoring/dashboards/fwwan_config.py`, then `custom.py`.

Review the diff, then apply. File and folder names must not contain spaces.

## fw-wan (VyOS edge router, configured by hand)

fw-wan isn't managed by this repo, so its monitoring was set up by hand (2026-11-09).
Prometheus scrapes it through `vyos_extra_targets` (node :9100 and FRR :9342 on the
mgmt VRF, 10.20.10.255) and `vyos_telegraf_targets` (job `vyos-telegraf`, :9273 on
`lylat-external` (formerly `lylat_service`, then `lylat_external` until 2026-11-14), 10.5.0.255). Telegraf has no InfluxDB output (since 2026-11-13; it used to
write bucket `vyos` through the InfluxDB relay): VyOS only runs its exec inputs (nftables
counters, interface and service state) while that output is set, and everything they gave
now comes from three scripts the task scheduler runs every minute, which write
node_exporter's textfile collector (job `vyos-node`):
[`vyos/vpn-metrics.py`](vyos/vpn-metrics.py) (IPsec via VICI and WireGuard:
`vyos_ipsec_*`, `vyos_wireguard_*`), [`vyos/nft-metrics.py`](vyos/nft-metrics.py) (firewall
and NAT rule counters, below) and [`vyos/status-metrics.py`](vyos/status-metrics.py)
(`vyos_interface_{state,link,info}`, `vyos_service_status`: it runs the two scripts VyOS ships
for Telegraf's exec input and converts their output). The router's log is in Loki only.

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
set service monitoring telegraf vrf 'lylat-external'
set service monitoring telegraf prometheus-client listen-address '10.5.0.255'
set service monitoring telegraf prometheus-client port '9273'
set service monitoring telegraf prometheus-client allow-from '10.5.11.30/32'
set service monitoring telegraf prometheus-client allow-from '10.5.11.31/32'
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
set system task-scheduler task status-metrics interval '1m'
set system task-scheduler task status-metrics executable path '/config/scripts/status-metrics.py'
set system syslog remote 10.5.11.101 facility all level 'info'
set system syslog remote 10.5.11.101 port '514'
set system syslog remote 10.5.11.101 protocol 'tcp'
set system syslog remote 10.5.11.101 format include-timezone
set system syslog remote 10.5.11.101 format octet-counted
set system syslog remote 10.5.11.101 vrf 'lylat-external'
set system syslog remote 10.5.11.101 source-address '10.5.0.255'
```

The `system syslog remote` lines send fw-wan's log (firewall `log` rules, strongSwan, FRR,
`info` and up) to Loki through the Alloy VIP `10.5.11.101` (TCP 514, RFC 5424, octet-counted)
from `lylat-external`. The other hand-configured log senders (PVE nodes, CRS317s, FS
switches, WLCs) are in [log-senders](log-senders/README.md).

Install the scripts with `sudo install -m 0755 vpn-metrics.py nft-metrics.py status-metrics.py
/config/scripts/` on the router. [`vyos/nft-metrics.py`](vyos/nft-metrics.py) adds per-rule counters for every
filter chain (input/forward/output base chains and their default actions, named chains,
IPv4 and IPv6) and NAT (`vyos_firewall_rule_{packets,bytes}_total{family,kind,chain,rule}`,
`vyos_nat_rule_{packets,bytes}_total{family,type,rule}`); Telegraf's VyOS script only
covers the named IPv4 chains. Telegraf's `syslog_*` series are dropped at scrape time.
The fw-wan dashboards read the firewall log, the router log and charon's log from Loki
(`{host="fw-wan"}`; firewall lines are `app="kernel"` with VyOS's `[ipv4-<hook>-<chain>-<rule>-<A|D|R>]`
prefix).

## C9800 telemetry (model-driven, dial-out)

The two Cisco C9800-CL WLCs stream their operational data (YANG oper models: controller
CPU/memory, APs and radios, clients) with **model-driven telemetry** (MDT). Each WLC
**dials out**: it opens a gRPC connection to the receiver and pushes every subscription
periodically (yang-push, every 30 s, kvGPB encoding), so nothing polls the WLCs and no
credentials for them are stored here. The receiver is **Telegraf** on mon01
(`wlc_telemetry`, [`modules/services/monitoring/telemetry.tf`](../../modules/services/monitoring/telemetry.tf)):

- `inputs.cisco_telemetry_mdt` listens on gRPC `:57500`, published on each backend's monitoring
  address and the monitoring VIP `10.5.11.102` (`tofu output wlc_telemetry_receiver`). The WLCs send
  from their Vlan5 address (`10.5.1.1`, `10.5.1.2`) on the same 10.5/16, so no router or
  firewall is in the path, and the backends have no host firewall.
- Two nested RRM lists (per-channel noise and foreign interference) get their `chan` key as a
  tag through `embedded_tags`, and the per-process CPU list is dropped (`fieldexclude`): it
  flattens into colliding fields.
- Every message arrives as one metric named after its YANG path (no aliases), e.g.
  `Cisco-IOS-XE-wireless-client-oper:client-oper-data/traffic-stats`, with the list keys as tags
  and the WLC as `source`. Telegraf clones it into `wlc_<short>` (below) and serves only the clones;
  the originals match no output. Until 2026-11-14 they went to the InfluxDB bucket `wlc`, whose
  history is backfilled into Mimir ([Retired: InfluxDB](#retired-influxdb)).
- Telegraf's own `internal_*` metrics go to Prometheus (job `telegraf`): the Monitoring
  stack dashboard shows metrics received per input and the output buffer,
  and `WlcTelemetryStopped` fires when no telemetry has arrived for 20 minutes.

The WLC side isn't managed by this repo. Both WLCs have the same 22 `telemetry ietf subscription`s
(ids 101-504, one per xpath: controller CPU/memory, AP, radio, RRM, client and global counts;
`encoding encode-kvgpb`, `stream yang-push`, `update-policy periodic 3000`, 6000 for the slower
trees) that point at one named receiver, `telemetry receiver protocol mon01` (port `57500`, `protocol grpc-tcp`,
no TLS), sent from each WLC's Vlan5 address. Its host is `tofu output wlc_telemetry_receiver` `.address`: the
monitoring VIP `10.5.11.102` with two backends (see [Backend HA](#backend-ha-mon01--mon02); set by
`~/network_automation/mon-ha/live/wlc-vip.sh`), else mon01's `10.5.11.30`. The exact CLI is in
`~/network_automation/wlc-telemetry/wlc-config.md`. The measurement, tag and field names (from a
real capture) are in `~/network_automation/wlc-telemetry/fields.md`. The dashboards
([Wireless (C9800)](#dashboards)) read the Prometheus copy of the same data: Telegraf clones every
message through [`telegraf/wlc.star`](../../modules/services/monitoring/telegraf/wlc.star) into
`wlc_<short>_<field>` series (string leaves as labels of `wlc_<short>_info`, the WLC as `host`),
served on `:9275` and scraped by both replicas as job `wlc`; `wireless.py`'s docstring has the names.
To check that data arrives: `journalctl -u telegraf` on the VIP holder, or in Grafana's Explore:
`count by (host) (wlc_client_live_run_state_clients)`.

## Backend HA (mon01 + mon02)

Every `role = "monitoring"` VM is a backend (at most two: `monitoring_primary`, default mon01, plus one
replica). They run the same stack from the same rendered files, except Postgres (primary only) and the
per-replica bits below. The rendering is in the module's `backends.tf`.

- **Prometheus HA pair.** Both scrape every target with the same config; `external_labels` are
  `{site = "lylat", ha_cluster = "lylat", __replica__ = "<vm>"}`. With Mimir on ([Metrics: Mimir HA](#metrics-mimir-ha)) both
  remote_write to it and Mimir's HA tracker keeps one replica's samples, then drops `ha_cluster` and `site`. The
  `prometheus`, `alertmanager` and `telegraf` jobs
  target every backend by backend address
  (label `host`), so each replica scrapes both and the deduplicated data still has every instance. Grafana has
  `Prometheus mon01`/`Prometheus mon02` datasources (uids `prometheus-mon01/-mon02`) to look at one replica directly.
- **Alertmanager cluster.** Gossip on the ha_monitor segment, VLAN 1016 (`monitoring_ha_vlan_id`, L2VNI `ha_monitor`),
  `10.50.16.30/.31:9094`, cluster label `lylat-alertmanager`. Both Prometheus (and the Loki ruler) send every alert to
  both Alertmanagers; `alert_relabel_configs` drops `__replica__`, so the two replicas' alerts are identical and the
  cluster notifies once. Without an address on VLAN 1016 on every backend, gossip falls back to the backend NIC.
- **keepalived** (`backend_vrrp`, router id 102): one VRRPv3 instance, unicast adverts over IPv6 on VLAN 1016, VIPs `10.5.11.102/16`
  (monitoring network: the C9800s' telemetry receiver, `wlc-telemetry-vip.lylat.space`) and `10.54.16.102/16`
  (lylat-obs, `monitoring-vip`: Grafana's Alertmanager datasource, the `wlc` scrape). BACKUP + `nopreempt` (mon01
  wins the first election), FAULT when the WLC Telegraf's `:9273/metrics` or Alertmanager `/-/ready` fails locally
  (the Telegraf check has no `init_fail`, so adding it by a reload doesn't drop the VIPs). Containers publish on the VIPs too, so the backends set
  `net.ipv4.ip_nonlocal_bind = 1` (`/etc/sysctl.d/90-monitoring-vip.conf`). Alert `MonitoringVIPNotHeldOnce`.
- **WLC Telegraf on both.** The C9800s send to the WLC Telegraf on the monitoring VIP `10.5.11.102:57500`, so only
  the VIP holder's Telegraf receives (alert `WlcTelemetryStopped` sums over both). A second named receiver per
  subscription doesn't work: IOS XE keeps only one receiver of a subscription active, the rest are standbys.
- **Grafana's database** is the Patroni cluster on pg01-03 (VIP 10.56.14.104) since 2026-11-10; mon01's
  Postgres container is gone (`postgres.auto.tfvars`). See [Postgres HA: Patroni](#postgres-ha-patroni).

## Logging (Loki HA)

Logs from the whole lab go to **Loki** on loki01-03 (`role = "logging"`, zoness/titania/fortuna),
through **Grafana Alloy**, and are queried from Grafana (datasource `Loki`, uid `loki`).
`terraform_data.logging["<vm>"]` deploys each VM like the others (generated `deploy.sh`, Quadlets).

```
devices / PVE --syslog--> VIP 10.5.11.101 ----------------------------\
VyOS leaves, DHCP VMs --syslog--> 10.20.11.34-36 (each, mgmt) ---------> alloy (VIP holder / each)
every other service VM alloy --journal--> telemetry VIP 10.55.18.101:3100 --\
                                                                            v
alloy (each log VM, journal + syslog) --> local loki --(ring, RF 3, VLAN 1018)--> all 3 lokis
                                          loki --S3--> 127.0.0.1:7480 haproxy --> RGW on macbeth/titania/venom (10.27.0.x)
Grafana --> VIP 10.54.18.101:3100 ;  Loki ruler --> both Alertmanagers (10.54.16.30/.31:9093)
```

**Networks on each log VM** (interface names from the NIC order: mgmt `eth0`, `network_devices[i]` = `eth<i+1>`):

| Network | loki01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.34-36 | SSH; syslog from the VyOS leaves and DHCP VMs (mgmt VRF; each sends to all three, no VIP on mgmt) |
| lylat-obs, VLAN 1401 (`eth1`) | 10.54.18.34-36 | backend and default route (gateway 10.54.0.1): Loki HTTP API, haproxy metrics; VIP `10.54.18.101` (Grafana datasource) |
| vmbr100 (`eth2`) | 10.5.11.34-36 | monitoring network: VIP `10.5.11.101` for syslog from switches, WLCs, fw-wan and the PVE nodes |
| vmbr27 (`eth3`) | 10.27.11.34-36 | Ceph public network: haproxy -> RGWs |
| VLAN 1018 (`eth4`, L2VNI `ha_logging`) | 10.50.18.34-36, fd69:5018::34-36 | HA: Loki memberlist and ingester gRPC (the ring), keepalived adverts (IPv6) |
| lylat-telemetry, VLAN 1501 (`eth5`) | 10.55.18.34-36 | Alloy/node_exporter metrics; VIP `10.55.18.101` (Alloy pushes from every other VM) |

### Loki

- **Monolithic** (`-target=all`) on each VM; the three form one ring over **memberlist** on the HA
  VLAN (`instance_addr`, `advertise_addr`, `join_members` = the VLAN 1018 addresses, `cluster_label
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
  ring so each group is evaluated once, alerts to both Alertmanagers (the cluster dedups). Group `logging`
  (`loki_rules_yml` in modules/services/monitoring/logging.tf): `RouterOSBGPNoBFD` (a spine logs "Cannot make
  BGP session. BFD session was not established", leaf-20 excluded), `SataLinkReset`, `KernelDiskIOError` and
  `KernelHardwareError` (kernel lines on the PVE nodes). The old `BGPSessionDownLogged` (FRR `ADJCHANGE`) could
  never fire: VyOS doesn't send those at its FRR log level; the leaves' sessions are alerted from frr_exporter
  metrics instead (`fabric` group, modules/services/monitoring/infra-alerts.tf).
- **Ports**: Loki runs with host networking and listens on every address, because the backend VIP
  moves between the VMs. `logging-guard` (an nftables table `inet logging_guard`, loaded by its own
  systemd unit) drops 3100 except from loopback and `logging_settings.loki_allowed_sources`
  (`10.52.0.0/16` for Grafana, `10.54.0.0/16` for lylat-obs, `10.55.0.0/16` for Alloy pushes from every VM over lylat-telemetry to the
  telemetry VIP `10.55.18.101`, since 2026-11-14; plus each Proxmox node's 10.5.1.x address, added in
  `main.tf`, for Alloy pushing the Ceph daemon logs to the VLAN 5 VIP, see `log-senders/README.md`),
  and 7946/9095 except from the three HA addresses. Nothing else is filtered.
- S3 keys live in `/etc/logging/loki.env` (0600) and are expanded by Loki (`-config.expand-env`);
  `loki.yaml` itself (output `loki_configs`) has no secrets.
- With RF 3 and no shared chunk cache, all three ingesters flush the same chunks (same object keys,
  so S3 holds one copy, but three writes).

### Alloy

- **log VMs**: syslog on every address (the VIPs included), pushed to the *local* Loki:

  | Listener | Format | Senders | Timestamp |
  | --- | --- | --- | --- |
  | TCP 514 | RFC 5424, octet-counted | VyOS leaves, DHCP VMs, fw-wan, PVE nodes (rsyslog) | sender's |
  | UDP 514 | RFC 3164 | MikroTik CRS317/CRS326 | receive time (no year/zone) |
  | UDP 1514 | raw (unparsed line) | Cisco C9800 WLCs (IOS-XE), FS S3910, FS S3700: RFC 3164 parsing silently drops their messages (the S3700's end in a NUL byte) | receive time (switch-1 has no NTP) |

  The `raw` format is experimental in Alloy, so the log VMs run it with `--stability.level=experimental`
  (validation too: `alloy validate` doesn't check stability, `alloy run` refuses it).
  Labels: `source="syslog"`, `host` (message hostname, else the sender's IP), `app`, `level` (severity),
  `facility`. Known senders get a fixed `host` from their address, the same name Prometheus uses: every
  `snmp_targets` address, plus `logging_settings.syslog_host_overrides`. That's what names the raw
  lines and fixes generic hostnames ("Switch").
- **Every VM** (mon01/02, graf01/02, loki01-03, mim01-03, pg01-03): the journal, `source="journal"`, `host`=VM name, `unit`,
  `container` (Podman's journald driver: every Quadlet container), `app`, `level`. All but the log VMs push to
  the telemetry VIP `http://10.55.18.101:3100` from their lylat-telemetry NIC.
- **services-config's VMs** (dns, netbox, proxy, valkey, triage; services-config `alloy.tf`): the same
  journal config and labels, pushing to the same telemetry VIP and scraped on the telemetry address
  (`targets.alloy`). Until 2026-11-13 these VMs sent their journal as syslog through rsyslog (`source="syslog"`).

### VIPs and failover (keepalived)

keepalived comes from the Debian package (installed by `deploy.sh`), not a container: it manages host
addresses (it needs host networking and NET_ADMIN anyway), its check scripts run curl on the host,
and Debian ships security updates for it. There's no trustworthy upstream keepalived image.

- **One VRRP instance** (`virtual_router_id 101`, `logging_settings.vrrp_router_id`; VRRPv3 over IPv6, no
  authentication) with unicast adverts over the HA segment (`eth4`, `fd69:5018::34-36`). It carries the three
  VIPs, each on its client NIC (`10.54.18.101/16 dev eth1`, `10.5.11.101/16 dev eth2`, `10.55.18.101/16 dev eth5`,
  with `use_vmac`), so they always move together.
- All three start `BACKUP` with **`nopreempt`**. Priorities 150/100/50 (loki01/02/03) only decide the
  first election. A recovered VM doesn't take the VIPs back, so there's no second interruption.
- **Failover**: the holder goes to FAULT, and a peer takes the VIPs within ~15 s (checks every 5 s,
  3 failures), when Loki's `/ready` fails, Alloy's `/-/ready` fails, a client NIC goes down
  (`track_interface`), or the VM or keepalived stops (3 missed adverts, ~3 s). The new holder sends
  gratuitous ARPs (and every 60 s while it holds them), which the EVPN fabric learns as a MAC move.
- What senders see: UDP syslog sent during the switchover is lost. TCP senders (rsyslog, VyOS)
  reconnect and resend their queue. Grafana and the pushing Alloys retry.
- If all three fail their checks, nobody holds the VIPs (alert `LoggingVIPNotHeldOnce`).

### Adding a log sender

- Send syslog to `10.5.11.101` (monitoring network) or, from the mgmt VRF, to all three of `10.20.11.34-36` (no VIP on mgmt): **TCP 514 RFC 5424
  octet-counted** if the device can (rsyslog: `omfwd` with `RSYSLOG_SyslogProtocol23Format`,
  `TCP_Framing="octet-counted"`), otherwise **UDP 514 RFC 3164**, and **UDP 1514** if the device's
  format doesn't parse as RFC 3164 (it shows in `loki_source_syslog_parsing_errors_total`).
- If its messages carry no useful hostname, add its address to `snmp_targets` (if it's scraped) or
  `logging_settings.syslog_host_overrides`.
- A Linux VM with Podman: give it a lylat-telemetry NIC (VLAN 1501) and Alloy like mon01 or services-config's
  `alloy.tf` (journal -> the telemetry VIP 10.55.18.101).
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

- **Which VM holds the VIPs:** `ip -br a | grep vrrp` on each log VM (the VIPs sit on `vrrp*` macvlans), or
  `node_network_address_info{device=~"vrrp.*"}` in Prometheus. Logs: `journalctl -u keepalived`.
- **Move the VIPs off a VM** (maintenance): `sudo systemctl stop keepalived` there (they don't come
  back on start, `nopreempt`).
- **Ring state:** `curl -s http://10.54.18.34:3100/ring` (ingesters), `/memberlist`, `/compactor/ring`,
  `/ruler/ring`; ready: `/ready`. Each must show three ACTIVE members.
- **S3 path:** `curl -s http://10.54.18.34:8405/stats` (haproxy: which RGWs are UP);
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
Prometheus mon01 --remote_write--\                       /--> mimir (VIP holder): distributor -> 3 ingesters (RF 3, VLAN 1017)
Prometheus mon02 --remote_write---> VIP 10.54.17.103:8080 ---> query-frontend -> queriers -> ingesters + store-gateways
Grafana (uid prometheus) --/prometheus------------------/     ingesters --2 h blocks--> 127.0.0.1:7480 haproxy --> RGWs (bucket mimir)
```

**Networks on each Mimir VM** (mgmt `eth0`, `network_devices[i]` = `eth<i+1>`):

| Network | mim01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.37-39 | SSH |
| lylat-obs, VLAN 1401 (`eth1`) | 10.54.17.37-39 | backend and default route (gateway 10.54.0.1): Mimir HTTP (push, queries, self-metrics), haproxy stats; VIP `10.54.17.103` |
| vmbr27 (`eth2`) | 10.27.11.37-39 | Ceph public network: haproxy -> RGWs |
| VLAN 1017 (`eth3`, L2VNI `ha_mimir`) | 10.50.17.37-39, fd69:5017::37-39 | HA: memberlist (7946), gRPC (9095), keepalived adverts (IPv6) |
| lylat-telemetry, VLAN 1501 (`eth4`) | 10.55.17.37-39 | node_exporter and Alloy metrics, Alloy's log pushes |

### Mimir

- **Mimir 3.2.4, monolithic** (`-target=all`: distributor, ingester, querier, query-frontend and
  -scheduler, store-gateway, compactor, ruler) on each VM, **classic architecture**: Mimir 3.x
  still defaults to it in the binary (`ingest_storage.enabled: false`, set explicitly); the Kafka
  "ingest storage" architecture is only the Helm chart's default. No Kafka.
- The three form one set of rings over **memberlist** on VLAN 1017 (`cluster_label lylat-mimir`, every
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
  (a replica failover can resend slightly older samples), block upload off (`block_upload_enabled`: set it
  true only while running a `mimirtool backfill`).
  The ingestion rate is a per-tenant *global* limit: each distributor enforces `ingestion_rate / healthy
  distributors` (burst not divided). All pushes go through the VIP to one distributor, so that one
  allows only a third: 100k/s. Prometheus treats a 429 as non-recoverable and drops the batch, so the
  limit must cover a WAL catch-up after an outage. At 40k (13.3k/s on the VIP holder), mon01 dropped
  ~1.08M samples catching up during the first deploy (2026-11-10 ~00:27 UTC). Mimir 3.2.4 has no
  option to answer rate limits with a retryable status.
- **Ports**: Mimir uses host networking and listens on every address (the VIP moves).
  `metrics-guard` (nftables table `inet metrics_guard`) drops 8080 except from loopback and
  `metrics_settings.allowed_sources` (`10.54.0.0/16` lylat-obs for remote_write, `10.52.0.0/16` lylat-app for
  Grafana), and 7946/9095 except from loopback and the
  three HA addresses. gRPC must include loopback: in monolithic mode the query-frontend and querier
  reach the scheduler on `127.0.0.1:9095`.
- S3 keys live in `/etc/metrics/mimir.env` (0600, `-config.expand-env`); `mimir.yaml` (output
  `mimir_configs` of the module) has none.
- The ruler runs (it's part of `all`) with no rules; alerting stays in Prometheus. No Mimir
  Alertmanager.

### VIP (keepalived)

One VRRPv3 instance (router id **103**, no authentication), unicast adverts over IPv6 on VLAN 1017
(`fd69:5017::37-39`), VIP `10.54.17.103/16` on the backend NIC (`eth1`). Same rules as the
Loki VIPs: all `BACKUP` with `nopreempt`, priorities 150/100/50 for the first election, FAULT when
Mimir's `/ready` fails 3 times (5 s apart) or `eth1` goes down. Prometheus retries and replays its
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

- **Rings:** `http://10.54.17.37:8080/ingester/ring` (also `/store-gateway/ring`, `/compactor/ring`,
  `/distributor/ring`, `/memberlist`); each needs three ACTIVE members. `/ready` on each VM.
- **HA tracker:** `http://10.54.17.103:8080/distributor/ha_tracker` shows the elected replica;
  `cortex_ha_tracker_elected_replica_status` in Prometheus.
- **Who holds the VIP:** `ip -br a | grep 10.54.17.103`, `node_network_address_info{address="10.54.17.103"}`.
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

Grafana's database (and NetBox's and dark-triage's) is a **Patroni cluster** on pg01-03 (since 2026-11-10;
`role = "postgres"`, titania/fortuna/venom), deployed by `terraform_data.postgres["<vm>"]`
([`postgres.tf`](postgres.tf), [module `postgres.tf`](../../modules/services/monitoring/postgres.tf)).
Live steps: `~/network_automation/mon-ha/runbook-postgres.md`.

```
graf01/02 --sslmode=require--> VIP 10.56.14.104:5432 (keepalived on the Patroni leader; check = Patroni /primary)
   leader pgNN: Postgres 18 <-- streaming replication (VLAN 1014) -- 2 replicas (pg_rewind, slots)
   Patroni x3 <--> etcd x3 (DCS, VLAN 1014)      archive_command / daily full backup --> pgBackRest
   --> https://127.0.0.1:7443 haproxy --> RGWs (bucket postgres, path /lylat-pg18, PITR 14 days)
```

| Network | pg01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.40-42 | SSH |
| lylat-data, VLAN 1601 (`eth1`) | 10.56.14.40-42 | backend and default route (gateway 10.56.0.1: Debian/PGDG packages, images): clients -> VIP `10.56.14.104`, scrapes (8008, 2381, 8405) |
| vmbr27 (`eth2`) | 10.27.11.40-42 | Ceph public network: haproxy -> RGWs |
| VLAN 1014 (`eth3`, L2VNI `ha_postgres`) | 10.50.14.40-42 | replication, etcd (2379/2380), Patroni REST (8008), keepalived (vrid 104, VRRPv3 over `fd69:5014::40-42`) |
| lylat-telemetry, VLAN 1501 (`eth4`) | 10.55.14.40-42 | scrapes (9187, 9100, Alloy 12345), Alloy's log pushes |

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
| `backend_vlan_ids` | `[1201, 1401, 1601]` | Zone segments (lylat-app, lylat-obs, lylat-data) whose NIC is a VM's backend NIC; each VM needs exactly one |
| `telemetry_vlan_id` | `1501` | lylat-telemetry: the NIC every exporter, node_exporter and Alloy listens on and Alloy pushes from |
| `ha_vlan_id` | `1018` | HA VLAN of the logging VMs (Loki ring, VRRP adverts); each logging VM needs one addressed NIC on it |
| `logging_settings` | see `variables.tf` | VIPs (backend `10.54.18.101`, monitoring `10.5.11.101`, telemetry `10.55.18.101`), VRRP router id (101), RGW endpoints, Loki retention (90d) and replication (3), schema start, sources allowed to Loki's HTTP port, extra syslog sender IP => host names |
| `loki_s3` | `null` (required with logging VMs) | Loki's S3 bucket and RGW keys, in the git-ignored `logging.secret.auto.tfvars` |
| `metrics_ha_vlan_id` | `1017` | HA VLAN of the Mimir VMs (memberlist, gRPC, VRRP); each needs one addressed NIC on it |
| `metrics_settings` | see `variables.tf` | [Mimir](#metrics-mimir-ha): VIP (`10.54.17.103/16`), VRRP router id (103), RGW endpoints, RF (3), retention (396d), HA tracker labels, `drop_labels`, limits, block upload (off), sources allowed to Mimir's HTTP port |
| `mimir_s3` | `null` (Mimir off) | Mimir's S3 bucket and RGW keys, in the git-ignored `metrics.secret.auto.tfvars` |
| `postgres_ha_vlan_id`, `postgres_settings` | `1014`, see `variables.tf` | [Patroni](#postgres-ha-patroni): HA VLAN, VIP (`10.56.14.104/16`), VRRP router id (104), `pg_major`, cutover switches |
| `grafana_ha_vlan_id`, `grafana_vrrp` | `1011`, VIP `10.52.11.100/16` router id 100 | Grafana's HA VLAN (alerting gossip, VRRP adverts) and keepalived VIP; `grafana_vrrp = null` = no VIP |
| `monitoring_bridge` | `vmbr100` | Bridge of the backends' monitoring-network NIC |
| `monitoring_primary` | `"mon01"` | [Backend HA](#backend-ha-mon01--mon02): the backend with Postgres (Grafana's fallback Prometheus without Mimir); the other `role = "monitoring"` VM (at most one) is the replica |
| `monitoring_ha_vlan_id` | `1016` | HA VLAN of the backends (L2VNI `ha_monitor`): keepalived adverts, Alertmanager gossip; each backend needs one addressed NIC on it |
| `backend_vrrp` | VIPs `10.5.11.102/16`, `10.54.16.102/16`, router id 102 | keepalived on the backends; `null` = no VIPs, Grafana uses the primary |
| `pve_monitoring_bridge` | `"100"` | `pve_network.bridges` key for the Proxmox nodes' scrape addresses |
| `images` | pinned tags | Container images; override one key at a time |
| `settings` | see `variables.tf` | Prometheus local retention (7d / 20GB; Mimir keeps the long-term copy), Grafana root URL, DNS probe zone, Ceph cluster label |
| `pve_api_token`, `greatfox_api_token` | required | Proxmox API tokens for the metric servers, from the linked `proxmox.secret.auto.tfvars` |
| `pve_api_node` | `null` (`nodes.cluster_api_node`) | Cluster node whose API manages the cluster's metric server; set another node if that one is unreachable |
| `pve_metrics` | see `variables.tf` | Proxmox metric servers: `enabled`, `pvestatd_port` (8186) |
| `pve_exporter_token` | `null` | PVE API token; `null` leaves pve-exporter out |
| `grafana_admin_password` | `null` (generated) | Fixed UI password; set it in a git-ignored `*.secret.auto.tfvars` |
| `snmp_v3_auths` | `{}` | SNMPv3 credentials for snmp_exporter (git-ignored `*.secret.auto.tfvars`); written to `/etc/monitoring/snmp-exporter/auths.yml` and loaded as a second exporter config file. The WLCs' `lylat_v3` lives here |
| `wlc_telemetry` | `{ port = 57500 }` | [C9800 telemetry](#c9800-telemetry-model-driven-dial-out): the WLC Telegraf's gRPC port on the backends and the monitoring VIP. `null` leaves Telegraf out |
| `vyos_extra_targets`, `node_extra_targets`, `snmp_targets`, `blackbox_icmp_targets`, `blackbox_http_targets` | see `variables.tf` | Targets outside the inventory |

## Running it

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config init'
nix-shell --run 'tofu -chdir=roots/monitoring-config plan'
nix-shell --run 'tofu -chdir=roots/monitoring-config apply'
tofu -chdir=roots/monitoring-config output -raw grafana_admin_password
```

Then open Grafana on https://grafana.lylat.space (through the proxy; directly: the VIP
`http://10.52.11.100:3000`, graf01/02 `10.52.11.32`/`.33`) as `admin`, and
Prometheus on `http://10.5.11.30:9090`.

The logging VMs need `logging.secret.auto.tfvars` (see [Ceph RGW](#ceph-rgw-on-the-pve-nodes)) and
their VLAN 1018 NIC before they can be planned. To dry-run a VM's deployment without installing
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

- **mon01's legacy Postgres (only with `legacy_on_primary = true`) reads its credentials only on first start**, when its data
  directory is empty. The generated values never change, but if you replace the
  `random_password` resources, wipe the data directory too.
- **Alertmanager routes everything to a `null` receiver.** Alerts are visible in
  Alertmanager and Grafana but not sent anywhere until you add a receiver.
- **Postgres (the Patroni VIP 10.56.14.104) is in lylat-data**, which only lylat-app, lylat-dns and lylat-external import (pg_hba and `postgres_guard` limit the clients further).
- **The Proxmox metric servers are managed here** ([`pve-metrics.tf`](pve-metrics.tf)).
  The cluster and the standalone greatfox each have one PVE metric server per monitoring
  backend, `pvestatd-mon01` and `pvestatd-mon02` (`/etc/pve/status.cfg`, type `influxdb`),
  that `pvestatd` uses to push node, guest (VM/LXC) and storage stats every ~10 s over HTTP
  to that backend's pvestatd Telegraf (`:8186`, token-checked), which Prometheus scrapes as
  job `pvestatd` (10 s; module `pvestatd.tf`). Until 2026-11-13 they wrote to InfluxDB
  (metric servers `influxdb` and `influxdb-mon02`, buckets `pve_cluster`, `pve_greatfox`), whose
  history is backfilled into Mimir ([Retired: InfluxDB](#retired-influxdb)). The metric servers go
  through the bpg provider (cluster API and the `proxmox.greatfox` alias), which needs
  `proxmox.secret.auto.tfvars` linked into this root:
  `ln -s ../../inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars roots/monitoring-config/`.
- **greatfox unreachable = untargeted plans fail.** greatfox is a standalone PVE host (not in the
  cluster), reached on its own API. When it's down, any untargeted `plan`/`apply` of this root
  fails while refreshing `proxmox_metrics_server.pvestatd_standalone["greatfox/mon01"]` and
  `["greatfox/mon02"]` (`dial tcp 10.20.7.20:8006`). Until it's back, exclude them:
  `tofu -chdir=roots/monitoring-config plan -exclude='proxmox_metrics_server.pvestatd_standalone'`
  (same for `apply`). Nothing else here depends on them, so the rest of the root plans normally.

### Retired: InfluxDB

InfluxDB 2 ran on mon01 and mon02 from 2026-11-09 to 2026-11-14 (Proxmox metric servers until
2026-11-13, the C9800 telemetry, fw-wan's Telegraf through the influx-relay until 2026-11-13). Every
source now goes to Prometheus/Mimir, and the history of the buckets `pve_cluster`, `pve_greatfox` and
`wlc` is backfilled into Mimir under the live names (`~/network_automation/mon-ha/mimir-runbook.md`).
The retirement removed the container, its scrape job, the Grafana datasource (provisioning deletes
it), the WLC Telegraf's InfluxDB outputs and tokens, the `influxdb-vip`/`influxdb-mon0x` DNS names and
the keepalived health check. The monitoring VIP `10.5.11.102` stays: it is the WLCs' telemetry
receiver, now `wlc-telemetry-vip`, and keepalived checks the WLC Telegraf instead.

- The buckets and write tokens were dropped from the state without being destroyed (2026-11-14, a one-off
  `removed` block file, deleted after that apply along with the influxdb provider).
- The data stays in `/var/lib/monitoring/influxdb` on both backends (~340 MB each) until it is
  removed by hand, after a final backup if wanted; the deploy only removes the env files with the
  old tokens (`/etc/monitoring/influxdb.env`, `telegraf.env`).

## Next steps

1. Exporters on the remaining targets: `prometheus-node-exporter` on greatfox.
   The leaves get theirs from `fabric.settings.leaf_prometheus_exporters`
   (fabric-leaves) and the DHCP VMs from `dhcp_prometheus_exporters`
   (services-config).
2. A pve-exporter token, for VM/HA state in Prometheus.

## Tests

`tests/postgres.tftest.hcl` covers the Patroni cluster (Patroni/etcd configs on the HA VLAN 1014, pg_hba,
the guard, keepalived on `/primary` with vrid 104, pgBackRest via the TLS haproxy, deploy.sh packages/order,
scrapes/alerts, the Grafana cutover and mon01 container switches and their guard, `bootstrap_from_backup`).
`tests/metrics.tftest.hcl` covers Mimir (config per VM, HA tracker and limits, remote_write and the
datasource switch, keepalived, deploy.sh, and that nothing Mimir-related renders without `mimir_s3`).
`tests/monitoring.tftest.hcl` plans against the real inventory with a mocked
`random` provider. It checks the derived targets and URLs, that pve-exporter
appears only with a token (and the token stays out of `prometheus.yml`), the
unit contents (Postgres bound to the backend address, Grafana HA peers), the
Postgres data-directory owner, the dashboard provider and files (the
expected files and uids per folder, every query uses the provisioned Prometheus
datasource, no import-time placeholders, every dashboard in the `lylat` links
dropdown, the Ceph dashboards' `ceph` tag and dropdown with no `$datasource` left, the Proxmox
dashboards' `proxmox` tag and dropdown, `pvestatd_*` queries with no InfluxDB/Flux left and the cluster picker, the fw-wan
dashboards' `fw-wan` tag and dropdown and the routing one's fw-wan default, Node Exporter Full's job and host pickers, the overview as home
dashboard, no restart for JSON changes, stale files pruned), that a missing
backend NIC fails the plan, and the logging stack: Loki's ring on the HA VLAN, RF 3, S3 through the
local haproxy, ruler to both Alertmanagers, no S3 keys in `loki.yaml`; the exact keepalived config per VM
(single instance over `eth4`, VIPs on the client NICs, priorities 150/100/50); Alloy's three syslog
listeners, `raw` with the experimental flag, sender-address host names from `snmp_targets`, journal-only
Alloy on the other VMs pushing to the telemetry VIP; haproxy's RGW backends; the Loki/Alloy/haproxy/node scrape
jobs and logging alerts; the Loki datasource; the validations in each logging `deploy.sh`; and that a
missing `loki_s3` or VLAN 1018 NIC fails the plan. For the C9800 telemetry (`wlc_telemetry`):
Telegraf on both backends, its unit (MDT port published on each monitoring address and the VIP,
`User=telegraf`, SIGHUP reload, no InfluxDB output, token or env file), keepalived tracking it, the
config check and gRPC health check in `deploy.sh`, the `telegraf` and `wlc` scrape jobs and alerts,
and that `wlc_telemetry = null` leaves all of it out. The retired InfluxDB (`exporters_and_ceph_alerts`):
no unit, image, scrape job, datasource or keepalived check left, the old datasource deleted, the env
files removed and the data kept. The two wireless dashboards carry the `wireless` tag and
dropdown, read `wlc_*` from the Prometheus datasource (no InfluxDB or Flux left), and pick WLCs by the
`host` label. Backend HA (`backend_ha`, `wlc_prometheus`, `backend_vrrp_disabled`,
`backend_ha_nic_required`): identical scrapes with per-replica `__replica__`, alerts without it to both
Alertmanagers, Postgres on mon01 only, Alertmanager gossip on VLAN 1016, the keepalived config (VIPs on
eth1/eth2, adverts over eth3, vrid 102, mon01 first) and the VIP publishes, Grafana's VIP and per-replica
datasources, the `wlc_*` clones scraped through the backend VIP, and that a missing VLAN 1016 NIC fails
the plan.

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config test'
```
