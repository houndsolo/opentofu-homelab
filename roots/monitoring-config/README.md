# monitoring-config

Deploys the monitoring stack onto VMs that [services-vms](../services-vms/README.md) creates, by role:
`monitoring` (mon01 primary, mon02 replica), `grafana` (graf01/02), `logging` (loki01-03), `metrics`
(mim01-03) and `postgres` (pg01-03). Same mechanism as BIND in
[services-config](../services-config/README.md#how-bind-is-deployed): OpenTofu SSHes to each VM and runs a
generated `deploy.sh` that installs **Podman Quadlet** units, so every container is a systemd service.

Rendering lives in [modules/services/monitoring](../../modules/services/monitoring/README.md); this root picks
the VMs, derives the scrape targets from the inventory, generates the secrets and runs the deploys.

## What runs where

| VM | Service (systemd unit) | Listens on |
| --- | --- | --- |
| mon01/02 | `prometheus`, `alertmanager` | monitoring network (`10.5.11.30`/`.31`) and backend NIC (`10.54.16.30`/`.31`): 9090, 9093. Alertmanager also on the backend VIP `10.54.16.102`; gossip 9094 on ha_monitor (VLAN 1016, `10.50.16.30`/`.31`) |
| | `snmp-exporter`, `blackbox-exporter`, `pve-exporter` | reached by name on the `monitoring` Podman network. snmp (9116) and blackbox (9115) also published on the backend address for the other replica's self-scrape; pve-exporter only with a token, not published |
| | `telegraf` ([C9800 telemetry](#c9800-telemetry-model-driven-dial-out)) | gRPC MDT `:57500` on the monitoring address and the monitoring VIP `10.5.11.102`; own metrics on the backend address :9273; `wlc_*` series on :9275 (all addresses) |
| | `pvestatd` (second Telegraf) | InfluxDB v2 listener on the monitoring address :8186 (token-checked; the PVE metric servers write here); metrics on the backend address :9274 |
| | `keepalived` (Debian package) | VRRPv3 vrid 102 over IPv6 on VLAN 1016 (`fd69:5016::30`/`::31`); VIPs `10.5.11.102/16` (eth2, vmbr100) and `10.54.16.102/16` (eth1, lylat-obs) |
| graf01/02 | `grafana` | 3000 on every address (VIP `10.52.11.100` included); alerting gossip 9094 on ha_grafana (VLAN 1011) |
| | `keepalived` | VRRPv3 vrid 100 over IPv6 on VLAN 1011 (`fd69:5011::32`/`::33`); VIP `10.52.11.100/16` on the lylat-app NIC |
| loki01-03 | `loki` | 3100 on every address, limited by `logging-guard`; ring (gRPC 9095, memberlist 7946) on ha_logging (VLAN 1018) |
| | `alloy` (syslog receiver + journal) | syslog on every address: TCP 514 (RFC 5424), UDP 514 (RFC 3164), UDP 1514 (raw) |
| | `haproxy` (S3 -> Ceph RGWs) | `127.0.0.1:7480`; stats/metrics on the backend address :8405 |
| | `keepalived`, `logging-guard` (nftables) | VRRPv3 vrid 101 on VLAN 1018; VIPs `10.54.18.101`, `10.5.11.101`, `10.55.18.101` |
| mim01-03 | `mimir` ([Mimir HA](#metrics-mimir-ha)) | 8080 on every address (VIP `10.54.17.103`), limited by `metrics-guard`; ring (9095, 7946) on ha_mimir (VLAN 1017) |
| | `haproxy`, `keepalived`, `metrics-guard` | as on the Loki VMs; VRRPv3 vrid 103 on VLAN 1017, VIP `10.54.17.103/16` on eth1 |
| pg01-03 | see [Patroni](#postgres-ha-patroni) | |
| every VM here | `node-exporter` :9100, `alloy` :12345 (metrics) | lylat-telemetry address. Alloy ships the journal to the Loki telemetry VIP `10.55.18.101` (log VMs: to their local Loki) |

**Networks.** Each VM's backend NIC is its zone segment (`backend_vlan_ids`, DT-090): lylat-obs (VLAN 1401,
10.54/16) for mon, Loki and Mimir; lylat-app (1201, 10.52/16) for Grafana; lylat-data (1601, 10.56/16) for
Postgres. It carries the default route (`10.Z.0.1`). Scrapes and Alloy pushes use **lylat-telemetry** (VLAN 1501,
10.55/16, isolated VRF). The **monitoring network** (vmbr100, 10.5/16) is where the Prometheus/Alertmanager UIs
are and where the PVE nodes and C9800 WLCs push.

**VIPs** (keepalived; must match `inventory/auto.tfvars/vips.auto.tfvars`, check `vips_match_monitoring_config`
in `vips.tf`). All instances are VRRPv3 over IPv6 on their HA segment, no auth, every node `BACKUP` +
`nopreempt` (priorities 150/100/50 by name decide only the first election), VIPs on `use_vmac` macvlans
(MAC never changes; only its EVPN location moves), a failing check = FAULT = VIP released.

| VIP | Name | vrid | Held by | Check | Used by |
| --- | --- | --- | --- | --- | --- |
| `10.52.11.100` | grafana-vip | 100 | graf01/02 | Grafana `/api/health` | the proxy (https://grafana.lylat.space) |
| `10.5.11.101` | logs-vip | 101 | loki01-03 | Loki `/ready`, Alloy `/-/ready`, client NICs | syslog from devices, PVE nodes' Alloy |
| `10.54.18.101` | loki-vip | 101 | loki01-03 | same instance | Grafana's Loki datasource |
| `10.55.18.101` | loki-telemetry-vip | 101 | loki01-03 | same instance | Alloy pushes from every other VM |
| `10.5.11.102` | wlc-telemetry-vip | 102 | mon01/02 | Alertmanager `/-/ready`, WLC Telegraf `:9273` | C9800 telemetry receiver |
| `10.54.16.102` | monitoring-vip | 102 | mon01/02 | same instance | Grafana's Alertmanager datasource, `wlc` scrape |
| `10.54.17.103` | mimir-vip | 103 | mim01-03 | Mimir `/ready`, eth1 | remote_write, Grafana's `prometheus` datasource |
| `10.56.14.104` | postgres-vip | 104 | Patroni leader | Patroni `/primary` | Grafana, NetBox, dark-triage |

Who holds a VIP: `node_network_address_info{address="<vip>"}` in Prometheus, or `ip -br a | grep vrrp` on the VM.
Each group has a `*VIPNotHeldOnce` alert.

## How a deployment works

One `terraform_data` per VM: `backend`, `grafana`, `logging`, `metrics`, `postgres` (`["<vm>"]`). Order:
backends, then logging, then metrics and postgres, then grafana (it needs Postgres and Mimir). Each uploads
`deploy.sh` to a private `/tmp` directory, runs it with `sudo -n`, and deletes it. The script:

1. Unpacks its embedded files into a staging directory and pulls the images.
2. Installs missing or out-of-pin Debian packages (keepalived; the Patroni stack). Deploy mode only.
3. **Validates** (in throwaway no-network containers, or on the host for nft/keepalived/patroni): `promtool check config` (and the Ceph rules),
   `amtool check-config`, blackbox `--config.check`, snmp_exporter `--dry-run`, `telegraf config check`,
   `alloy validate`, `loki -verify-config`, `haproxy -c`, `nft -c`, and once the packages exist `keepalived -t`
   and `patroni --validate-config`. A broken
   config never gets installed.
4. Creates directories (data dirs owned by the user each image runs as) and installs only files that changed
   (content, mode, owner). Under the dashboards directory, files no longer in the module are deleted.
5. Stops and removes Quadlet units it no longer manages (e.g. `pve-exporter` after removing the token).
6. `systemctl daemon-reload`, then per service in order: **restart** if its unit, env file or a restart-type
   config changed; **start** if not running; **reload** (SIGHUP / ExecReload) if only a reloadable config changed.
   Prometheus, Alertmanager, blackbox, Telegraf, Alloy and keepalived reload, so scrape-target edits don't
   restart Prometheus.
7. Waits up to two minutes per health check (`/-/ready`, Grafana `/api/health`, Telegraf's ports, ...). On
   failure it prints the failing units' journal and exits non-zero.

`deploy.sh check` pulls, validates and lists what would change, installing nothing (copy it to a VM and run
`sudo bash deploy.sh check`). A failed deploy fails the apply and taints the resource, so the next apply retries.

**Redeploy triggers:** any rendered file or image, the VM's management address, VM ID, `ssh_username`, or
`deploy_revision`. Secrets are rendered in, but generated once and kept in state.

**Rolling restarts:** all VMs of a role deploy in parallel. For Loki, Mimir and Patroni use `-parallelism=1`
so each VM waits for its health check before the next restarts; a parallel apply restarts all three Lokis or
Mimirs at once (writes fail for a minute, clients retry).

### What ends up on the VMs

| Path | What |
| --- | --- |
| `/etc/containers/systemd/*.container`, `monitoring.network` | Quadlet units (`<name>.service`) |
| `/etc/monitoring/prometheus/prometheus.yml`, `rules/basic.yml`, `rules/ceph.yml` | Prometheus config, alert rules (all groups in `basic.yml`; the vendored ceph-mixin in `ceph.yml`) |
| `/etc/monitoring/{alertmanager,blackbox,snmp-exporter,telegraf,pvestatd,pve-exporter}/` | the other backend configs (`snmp-exporter/auths.yml` 0600, `pve-exporter/pve.yml` 0640; token in `/etc/monitoring/pvestatd.env` 0600) |
| `/var/lib/monitoring/{prometheus,alertmanager}` | backend data |
| `/etc/grafana-container/provisioning/{datasources,dashboards}/`, `grafana.env` (0600) | Grafana datasources, dashboard provider + `files/<Folder>/*.json`, secrets |
| `/var/lib/grafana-container` | Grafana plugins/cache (real state is in Postgres) |
| `/etc/alloy/config.alloy`, `/var/lib/alloy` | Alloy (every VM) |
| `/etc/logging/loki/loki.yaml`, `loki/rules/fake/`, `/etc/logging/loki.env` (0600), `/var/lib/logging/loki` | Loki (chunks are in S3) |
| `/etc/metrics/mimir/`, `/etc/metrics/mimir.env` (0600), `/var/lib/metrics/mimir` | Mimir |
| `/etc/{logging,metrics}/haproxy/haproxy.cfg` | haproxy (S3 -> RGWs) |
| `/etc/{logging,metrics}/guard.nft` + `{logging,metrics}-guard.service` | nftables guards |
| `/etc/keepalived/keepalived.conf` (0600), `/etc/sysctl.d/90-monitoring-vip.conf` (backends) | VRRP; `ip_nonlocal_bind` so containers can publish on VIPs |
| `/etc/patroni/`, `/etc/etcd/etcd.yml`, `/etc/pgbackrest/`, `/etc/postgres-ha/` (`s3.env`, haproxy, guard) | Patroni members; data in `/var/lib/postgresql/patroni/<major>` |

Logs: `journalctl -u <unit>`.

## Scrape targets

Derived from the inventory: adding a node, leaf or service VM updates Prometheus on the next apply. VM-hosted
jobs get `instance = <host>:<port>` (module `instance-labels.tf`), so address moves don't start new series.

| Job | Targets |
| --- | --- |
| `prometheus`, `alertmanager`, `snmp-exporter`, `blackbox-exporter` | every backend on its backend address (label `host`): each replica scrapes both |
| `node` | every service VM's lylat-telemetry address (label `role`), PVE nodes on `cidrhost(vmbr100 prefix, id)` (role `proxmox`), `node_extra_targets` |
| `alloy` | every VM here plus services-config's dns, netbox, proxy, valkey and triage VMs |
| `vyos-node` (:9100), `vyos-frr` (:9342) | leaves and DHCP VMs (mgmt), `vyos_extra_targets` (fw-wan) |
| `vyos-telegraf` (:9273) | `vyos_telegraf_targets` (fw-wan); `syslog_*` series dropped |
| `snmp-<name>` | `snmp_targets` on their 10.5/16 addresses: `fs-switches`, `mikrotik-access` (CRS317), `spines`, `mikrotik-hr` (HOST-RESOURCES-MIB, own job because it's fast), `wlc` (SNMPv3, `snmp_v3_auths`). fs-switches, mikrotik-access and spines: 30 s interval, 20 s timeout |
| `pve` | cluster nodes through pve-exporter; only with `pve_exporter_token` |
| `ceph` (:9283, 15 s) | the mgr prometheus module on `ceph_mgr_nodes` (only the active mgr returns data) |
| `pvestatd` (10 s) | each Prometheus's own pvestatd Telegraf by container name |
| `blackbox-icmp`, `-http_2xx`, `-https`, `-dns_soa` | `blackbox_*_targets`; `https` requires a valid cert (sites behind the proxy); `dns_soa` = each DNS VM's service address, `SOA lylat.space` |
| `grafana` | each Grafana's backend address |
| `telegraf`, `wlc` | WLC Telegraf's own metrics (each backend); the `wlc_*` series via the backend VIP :9275 |
| `loki`, `haproxy`, `mimir`, `haproxy-mimir`, `patroni`, `etcd`, `postgres`, `haproxy-postgres` | the log, Mimir and Patroni VMs |
| `valkey`, `valkey-sentinel`, `nginx`, `bind`, `netbox` | services-config's VMs (exporters there) |

**Alert groups** (Prometheus, all in `rules/basic.yml`): `basic`, `storage-health`, `fabric`/`vpn`/`hosts`/
`hardware` (`infra-alerts.tf`), `logging`, `metrics`, `monitoring-ha`, `wlc-telemetry`, `pvestatd`, `postgres`,
`ceph-rgw-buckets`, `valkey`, `nginx`, `tls`, `bind`; plus the ceph-mixin groups in `rules/ceph.yml`. Loki's ruler
has group `logging` (see [Loki](#loki)).

### The `mikrotik_lite` SNMP module

The bundled `mikrotik` module walks all of MIKROTIK-MIB (~2,400 PDUs per CRS3xx; 5-17 s on RouterOS, hitting
the 20 s timeout, DT-023). The MikroTik jobs walk `mikrotik_lite` instead: only what the `mikrotik-snmp`
dashboard queries (board/firmware/license scalars and health in one GET, the MNDP/LLDP neighbor table, 34
interface-stats columns). About half the PDUs; median walk 10.0 s -> 5.5 s.

- `modules/services/monitoring/snmp/mikrotik_lite.yml` is generated; the source is the `KEEP` list in
  `snmp/build-mikrotik-lite.sh` (commands at its top). Regenerate after adding a metric or bumping
  `snmp_exporter`.
- Loaded as a second `--config.file` next to the bundled `snmp.yml`; `deploy.sh` dry-runs the set.

## Dashboards

JSON files in [modules/services/monitoring/dashboards](../../modules/services/monitoring/dashboards/); each
subdirectory is a Grafana folder (46 dashboards). A file provider loads them:

- **No restart for JSON changes.** The provider polls every 30 s and the deploy also triggers a provisioning
  reload through the admin API (Grafana 13 doesn't always pick up new folders by polling). Only a provider or
  datasource change restarts Grafana.
- **Deleting a file deletes the dashboard** (`deploy.sh` prunes the directory).
- **The UI can't save over them** (`allowUiUpdates: false`). "Save as" a copy to explore; permanent changes go
  into the generator.
- Both Grafanas provision the same files into the shared database; checksums keep them from fighting.

The **home page** is the overview (`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`) unless a user/team/org
preference overrides it. Every dashboard has a **Dashboards** dropdown (tag `lylat`); the overview has one per
folder (tags `lylat-<folder>`).

| Folder | Dashboard (uid) | Source | Shows |
| --- | --- | --- | --- |
| Overview | lylat.space overview (`lylat-overview`) | custom | Targets, firing alerts, probes, BGP/BFD; HA service tiles (OK/DEGRADED/DOWN, click through); VIP holders; HTTPS sites and cert lifetime; Postgres/Valkey/NetBox queue; Ceph, Proxmox, Edge summaries; host/router table (links to Node Exporter Full and logs); top interfaces; log volume |
| Hosts | Node Exporter Full (`node-exporter-full`) | [grafana.com 1860](https://grafana.com/grafana/dashboards/1860) rev 46 | One host; pick job `node` (VMs) or `vyos-node` (VyOS), then host |
| Network | FRR / EVPN fabric (`frr-evpn-fabric`) | custom | BGP peer table, session timeline, flaps, BFD, EVPN VTEPs/MACs/ARP-ND per router and L2VNI, routes per VRF, RIB vs FIB |
| Network | SNMP Device Summary (`snmp-device-summary`) | [grafana.com 12489](https://grafana.com/grafana/dashboards/12489) rev 5 | Per device: interfaces up/down, top talkers, traffic, interface table |
| Network | SNMP Interface Detail (`snmp-interface-detail`) | [grafana.com 12492](https://grafana.com/grafana/dashboards/12492) rev 4 | Per interface: status, speed, traffic, packets, errors, discards |
| Network | SNMP interface throughput (`snmp-throughput`) | custom (`snmp.py`) | Traffic, utilisation, errors, state for one or more SNMP devices |
| Network | SNMP Interface Throughput (community) (`snmp-throughput-community`) | grafana.com 1124 rev 1 | Interface bandwidth |
| Network | Mikrotik monitoring (`mikrotik-snmp`) | [grafana.com 14420](https://grafana.com/grafana/dashboards/14420) rev 9 | `mikrotik_lite`: board/firmware, temperature, traffic, Ethernet errors, neighbors |
| Network | Wireless (C9800) (`wireless-overview`) | custom (`wlc_*`, job `wlc`) | [C9800 telemetry](#c9800-telemetry-model-driven-dial-out): controllers, APs, radios, RF environment, SSIDs, clients; WLC picker |
| Network | Wireless client (C9800) (`wireless-client`) | custom (`wlc_*`) | One client: RSSI/SNR, rates, throughput, retries, AP/SSID/channel timeline |
| Edge | fw-wan overview (`fw-wan-overview`) | custom | The VyOS edge router: status, WAN and per-VRF traffic, firewall verdicts, NAT, VPN state, system; router syslog |
| Edge | fw-wan firewall (`fw-wan-firewall`) | custom | Every IPv4/IPv6 filter chain and NAT rule from nft-metrics.py: verdicts, default-action drops, per-rule table, conntrack, firewall log |
| Edge | fw-wan VPNs (`fw-wan-vpn`) | custom | IPsec SAs (vpn-metrics.py), WireGuard peers, BGP over the tunnels, tunnel traffic, strongSwan log |
| Edge | fw-wan VRFs & routing (`fw-wan-routing`) | custom | Router (default fw-wan, works for leaves/DHCP VMs) and VRF pickers: BGP/BFD, RIB/FIB per VRF, peers, traffic per VRF |
| Probes | Blackbox probes (`blackbox-probes`) | custom | ICMP/HTTP/DNS SOA status, availability, timings, SOA serial drift |
| Monitoring | Monitoring stack (`monitoring-stack`) | custom | Component status/versions; Prometheus, Alertmanager, Grafana, Loki/Alloy, Mimir remote_write, Telegraf internals; exporter scrape times |
| Storage | Ceph cluster (`ceph-cluster`) | custom | Health, capacity and forecasts, client I/O, PGs/recovery, OSD grid and table, slow ops/BlueStore, mons/mgrs, CephFS, OSD hosts, per-image RBD |
| Storage | Ceph OSD (`ceph-osd`) | custom | One OSD: state, latency, IOPS, BlueStore, scrubs, its disk from node_exporter |
| Storage | Ceph cluster advanced (mixin) (`ceph-cluster-advanced`) | [ceph-mixin](https://github.com/ceph/ceph/tree/tentacle/monitoring/ceph-mixin) `tentacle` @ `804c5928` | Official cluster dashboard: health, capacity, I/O, PGs, latency heatmaps |
| Storage | Ceph OSDs overview (mixin) (`ceph-osds-overview`) | ceph-mixin | OSD latency, slowest OSDs, PGs per OSD, slow ops |
| Storage | Ceph OSD device details (mixin) (`ceph-osd-device-details`) | ceph-mixin | One OSD (device panels stay empty, see below) |
| Storage | Ceph pools overview (mixin) (`ceph-pools-overview`) | ceph-mixin | Pool capacity, top pools by IOPS/bandwidth |
| Storage | Ceph pool details (mixin) (`ceph-pool-details`) | ceph-mixin | One pool: usage, time till full, I/O |
| Storage | Ceph RBD overview (mixin) (`ceph-rbd-overview`) | ceph-mixin | RBD totals and top images |
| Storage | Ceph RBD details (mixin) (`ceph-rbd-details`) | ceph-mixin | One image: IOPS, throughput, latency |
| Storage | Ceph filesystem (mixin) (`ceph-filesystem`) | ceph-mixin | CephFS pools, MDS requests, sessions, caps |
| Storage | Ceph RGW buckets (`ceph-rgw-buckets`) | custom (`rgw.py`) | Per-bucket size, objects, growth, quotas from [pve-collectors](pve-collectors/README.md) |
| Proxmox | Proxmox overview (`proxmox-overview`) | custom (job `pvestatd`) | Cluster, nodes table, node trends, top guests, storage |
| Proxmox | Proxmox node (`proxmox-node`) | custom | One node: CPU/memory/load, NICs, its guests and storages, node_exporter extras |
| Proxmox | Proxmox guests (`proxmox-guest`) | custom | Guest table, then one guest: CPU, memory, pressure, disks, NICs |
| Proxmox | Proxmox storage (`proxmox-storage`) | custom | Used % per storage, growth and "full in", Ceph health |
| Logs | Logs overview (`logs-overview`) | custom (Loki) | Lines, errors/warnings, noisiest hosts and apps, newest errors, log browser |
| Logs | Network device logs (`logs-network`) | custom (Loki + frr_exporter) | Leaves, fw-wan, MikroTiks, FS switches, WLCs: BGP/BFD, interface, STP, auth/config, AP/client events |
| Logs | fw-wan firewall & VPN logs (`logs-fw-wan`) | custom (Loki) | Parsed firewall log, strongSwan IKE events, config commits |
| Logs | Proxmox & Ceph logs (`logs-proxmox`) | custom (Loki) | PVE errors, tasks, corosync, HA, auth; Ceph cluster log (pick one mon) and daemon logs |
| Logs | Services logs (`logs-services`) | custom (Loki) | BIND, Kea (leases, HA), keepalived transitions, monitoring containers |
| Databases | Postgres cluster (Patroni) (`postgres-cluster`) | custom | Leader, VIP, checks tile, members, failover history, replication, WAL/backups, etcd, hosts |
| Databases | Postgres instance (`postgres-instance`) | custom | One member and database: backends, transactions, cache, checkpoints, locks, settings diff |
| Databases | Prometheus (`prometheus-server`) | custom | mon01/02 (7 d / 20 GB local, remote_write to Mimir): checks tile, TSDB, scrapes, rules, remote write, notifications |
| Databases | Mimir (`mimir`) | custom | mim01-03: checks, ingestion/dedup, series vs limits, blocks to S3, compactor, queries, rings |
| Databases | Loki (`loki`) | custom | loki01-03 and the Alloy senders: checks, ingestion, chunks, WAL, ring, queries, retention, ruler |
| Databases | Telegraf (`telegraf`) | custom | WLC telemetry Telegraf, pvestatd listener, fw-wan's VyOS Telegraf |
| Databases | Valkey (NetBox cache and queue) (`valkey`) | custom | valkey01-03 and Sentinels: primary, checks, replication, RQ queue, memory |
| Services | dark-triage helpdesk (`dark-triage`) | custom (Postgres + Prometheus, `triage.py`) | Ticket queue, priorities, flow, app health |
| Services | nginx reverse proxy (`nginx-proxy`) | custom | proxy01/02: VIP, sites probed over HTTPS, cert expiry, per-site access-log stats, connections |
| Services | DNS (BIND) (`dns-bind`) | custom | dns01/02: VIP, SOA probes, zone serials, query mix, recursion/cache, transfers |

Notes per family (each family shares a top-bar dropdown that carries pickers along):

- **SNMP:** only need `if_mib`, so they work for every SNMP job. Pickers show the target's `host` label.
- **Proxmox** (`proxmox` tag): read `pvestatd_<measurement>_<field>` (job `pvestatd`, 10 s, Mimir datasource;
  10 s minimum interval). **Cluster** picker: the lylat cluster or standalone greatfox. "Now" values are instant
  queries; a guest drops out a minute after it stops being reported, a node counts as down after a minute.
- **fw-wan** (`fw-wan` tag): jobs `vyos-node`, `vyos-frr`, `vyos-telegraf`, `blackbox-icmp` plus fw-wan's syslog in
  Loki. Firewall/NAT counters are nft-metrics.py's ([fw-wan](#fw-wan-vyos-edge-router-configured-by-hand)).
  What a rule does (action, jump target, match, interface -> VRF, NAT rules) comes from
  [`fwwan_snapshot.py`](../../modules/services/monitoring/dashboards/fwwan_snapshot.py); "Rules not in snapshot"
  turns orange when fw-wan has rules it doesn't know (refresh: [Changing the dashboards](#changing-the-dashboards)).
- **Wireless** (`wireless` tag): `wlc_*` (job `wlc`, datasource uid `prometheus`); InfluxDB history from
  2026-11-09 is backfilled into Mimir under the same names. String leaves are labels of `wlc_<short>_info`
  (joined with `group_left`); timestamps are `<field>_seconds` (0 = unset). The WLC picker filters on `host`
  (`c9800-wlc-1/2`, same as the SNMP jobs). Telegraf drops a series 150 s after its last push. APs refresh
  counters only every 90 s (client traffic, SSID stats) or 180 s (radio, uplink, RRM) and the WLC re-sends the
  old value in between, so rate panels use 3/6-minute minimum windows. Download = AP `bytes_tx`. c9800-wlc-2 has
  no APs or clients.
- **Logs** (`logs` tag, datasource uid `loki`): Podman logs container stderr as priority err, so the dashboards
  re-derive `level` from the line. Host pickers match case-insensitively (Loki `LEAF-11`, Prometheus `leaf-11`).
- **Ceph:** the mgr prometheus module (job `ceph`) plus node_exporter on the PVE nodes, both set up by hand
  (2026-11-08):

```sh
# Once, on any PVE node (port 9283 on every mgr; standbys answer an empty 200):
ceph mgr module enable prometheus
ceph config set mgr mgr/prometheus/exclude_perf_counters false  # per-daemon perf counters (no ceph-exporter on PVE)
ceph config set mgr mgr/prometheus/rbd_stats_pools ceph_rbd     # per-image (per VM disk) RBD stats
# On each Ceph node: node_exporter (:9100, job node, role proxmox) with the SMART textfile collector
apt-get install -y --no-install-recommends prometheus-node-exporter prometheus-node-exporter-collectors
```

  `ceph_mgr_nodes` lists the mgr hosts; update it if mgrs move. `ceph-exporter` is deliberately not used (perf
  counters come from the mgr; PVE's package crash-loops on the keyring path, PVE bug 6816).

Panels that stay empty, and why:

- **Node Exporter Full:** swap, zswap, EDAC, power, fans, CPU frequency need hardware a VM lacks. On VyOS "Root
  FS" is empty (overlay root). Temperatures only on the bare-metal leaves (leaf-18, leaf-19, leaf-42).
- **Mikrotik monitoring:** Wi-Fi, CAPsMAN, 60 GHz, PoE, queue panels don't apply to CRS switches (CPU/RAM/disk
  come from `mikrotik-hr` and the `system` module).
- **Ceph:** PG state, slow-op and scrub panels show only non-zero values; forecasts use 7 days of history;
  CephFS latency is empty while the MDS is idle. Mixin quirks: "OSD device details" joins node_exporter on
  `instance` (ours is `host:port`), so use the Ceph OSD dashboard; no pool uses compression; some queries use
  metrics Ceph 20 dropped; MDS CPU needs the disabled mgr `stats` module; no RGW versions; the OSD size buckets
  skip 10-12 TB, where these 10.9 TiB OSDs fall.
- **fw-wan:** nft-metrics.py counters start 2026-11-09 and reset on every firewall commit (rate/increase cope).
  NAT counts connections, not bytes. No output filter (only "default accept"), raw chains left out, no OSPF,
  no BFD on fw-wan. Firewall log panels show only rules with `log`. Road-warrior WireGuard peers and the VPS
  IPsec connection read DOWN while not connected.
- **Logs:** Loki has data from 2026-11-09. Event panels stay empty until such an event happens. WireGuard is
  always empty (kernel logs only with dynamic debug); BIND queries need query logging. VyOS forces FRR to `log
  syslog notifications`, so bgpd/bfdd state changes never reach syslog: those come from frr_exporter. VyOS
  routers and DHCP VMs send every line twice (rsyslog reads the journal and journald's syslog socket); Alloy
  drops the one-leading-space copy for `logging_settings.syslog_dedup_hosts` (kernel lines excepted), so only
  older ranges show doubles. The Ceph cluster log arrives once per mon. BIND logs everything to stderr, so its
  panels go by the line, not the level.
- **Proxmox:** `pvestatd_*` start 2026-11-13 10:10Z (earlier InfluxDB history backfilled). PVE reports no disk
  usage inside VMs, so root-disk panels are containers only; per-disk, per-NIC, balloon and I/O-error panels
  are VMs only. Balloon stats need the guest's balloon driver (empty for the WLCs). No KSM, per-node pressure or
  ZFS on the cluster. Guest status is running/stopped only. A storage's `content` label arrives in random order,
  so storage queries collapse it.

### Changing the dashboards

Never edit the JSON by hand; regenerate it, review the diff, apply. File and folder names must not contain spaces.

- **Community:** edit the list in [`update.py`](../../modules/services/monitoring/dashboards/update.py), run
  `python3 -I modules/services/monitoring/dashboards/update.py`. It downloads the pinned grafana.com revision or
  ceph-mixin commit (`CEPH_MIXIN_COMMIT`; keep `rules/ceph-mixin/fetch.sh` on the same commit), points every
  query at the provisioned datasource (uid `prometheus`), drops import-time inputs, sets uid/tags/links.
- **Custom:** run `python3 -I modules/services/monitoring/dashboards/custom.py` (offline). Builders:
  `custom.py` (overview, FRR, probes, monitoring stack, Ceph), `pve.py` (Proxmox), `fwwan.py`, `logs.py`,
  `wireless.py` (its docstring lists the `wlc_*` names it relies on), `databases.py` (Postgres, Valkey),
  `promtsdb.py`, `mimir.py`, `loki.py`, `telegraf.py`, `nginx.py`, `dns.py`, `rgw.py`, `snmp.py`, `triage.py`;
  `theme.py` is the palette pass both scripts apply.
- **fw-wan snapshot:** after changing fw-wan's firewall, NAT, interfaces or VRFs, run
  `python3 -I modules/services/monitoring/dashboards/fwwan_config.py` (reads the config over
  `ssh vyos@10.20.10.255`), then `custom.py`, and commit both.

## fw-wan (VyOS edge router, configured by hand)

fw-wan isn't managed by this repo. Prometheus scrapes it through `vyos_extra_targets` (node :9100 and FRR :9342
in the mgmt VRF, 10.20.10.255) and `vyos_telegraf_targets` (job `vyos-telegraf`, :9273 in `lylat-external`,
10.5.0.255). Telegraf has no InfluxDB output, and VyOS only runs its exec inputs while one is set, so three
scripts run every minute from the task scheduler and write node_exporter's textfile collector (job `vyos-node`):

- [`vyos/vpn-metrics.py`](vyos/vpn-metrics.py): IPsec via VICI and WireGuard (`vyos_ipsec_*`, `vyos_wireguard_*`).
- [`vyos/nft-metrics.py`](vyos/nft-metrics.py): per-rule counters for every filter chain (base chains and
  default actions, named chains, IPv4/IPv6) and NAT: `vyos_firewall_rule_{packets,bytes}_total{family,kind,chain,rule}`,
  `vyos_nat_rule_{packets,bytes}_total{family,type,rule}`. Telegraf's VyOS script covers only named IPv4 chains.
- [`vyos/status-metrics.py`](vyos/status-metrics.py): `vyos_interface_{state,link,info}`, `vyos_service_status`
  (runs VyOS's own Telegraf exec scripts and converts the output).

Install: `sudo install -m 0755 vpn-metrics.py nft-metrics.py status-metrics.py /config/scripts/` on the router.
Live config (checked 2026-11-15; zabbix-agent lines omitted):

```
set service monitoring prometheus node-exporter listen-address '10.20.10.255'
set service monitoring prometheus node-exporter vrf 'mgmt'
set service monitoring prometheus node-exporter collectors textfile
set service monitoring prometheus frr-exporter listen-address '10.20.10.255'
set service monitoring prometheus frr-exporter vrf 'mgmt'
set service monitoring prometheus frr-exporter collector bgp-l2-vpn
set service monitoring prometheus frr-exporter collector bgp peer-hostname
set service monitoring prometheus frr-exporter collector bgp peer-description 'plain-text'
set service monitoring telegraf vrf 'lylat-external'
set service monitoring telegraf prometheus-client listen-address '10.5.0.255'
set service monitoring telegraf prometheus-client port '9273'
set service monitoring telegraf prometheus-client allow-from '10.5.11.30/32'
set service monitoring telegraf prometheus-client allow-from '10.5.11.31/32'
set firewall ipv4 input filter rule 9100 action 'accept'
set firewall ipv4 input filter rule 9100 destination port '9100,9342'
set firewall ipv4 input filter rule 9100 inbound-interface name 'mgmt'
set firewall ipv4 input filter rule 9100 protocol 'tcp'
set firewall ipv4 input filter rule 9100 source address '10.20.11.30'
set firewall ipv4 input filter rule 9101 action 'accept'
set firewall ipv4 input filter rule 9101 destination port '9100,9342'
set firewall ipv4 input filter rule 9101 inbound-interface name 'mgmt'
set firewall ipv4 input filter rule 9101 protocol 'tcp'
set firewall ipv4 input filter rule 9101 source address '10.20.11.31'
set firewall ipv4 input filter rule 9273 action 'accept'
set firewall ipv4 input filter rule 9273 destination port '9273'
set firewall ipv4 input filter rule 9273 inbound-interface name 'lylat-external'
set firewall ipv4 input filter rule 9273 protocol 'tcp'
set firewall ipv4 input filter rule 9273 source address '10.5.11.30'
set firewall ipv4 input filter rule 9274 action 'accept'
set firewall ipv4 input filter rule 9274 destination port '9273'
set firewall ipv4 input filter rule 9274 inbound-interface name 'lylat-external'
set firewall ipv4 input filter rule 9274 protocol 'tcp'
set firewall ipv4 input filter rule 9274 source address '10.5.11.31'
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

The syslog lines send fw-wan's log (firewall `log` rules, strongSwan, FRR; `info` and up) to the Alloy VIP. In
Loki: `{host="fw-wan"}`; firewall lines are `app="kernel"` with VyOS's `[ipv4-<hook>-<chain>-<rule>-<A|D|R>]`
prefix. Other hand-configured log senders: [log-senders](log-senders/README.md).

## C9800 telemetry (model-driven, dial-out)

The two C9800-CL WLCs **dial out** gRPC (yang-push, kvGPB, periodic) to Telegraf on the backends
([`telemetry.tf`](../../modules/services/monitoring/telemetry.tf)), so nothing polls them and no WLC credentials
are stored here.

- `inputs.cisco_telemetry_mdt` on `:57500`, published on each backend's monitoring address and the monitoring
  VIP `10.5.11.102`. The WLCs send from Vlan5 (`10.5.1.1`/`.2`), same 10.5/16: no router or firewall in the path.
- Only the VIP holder's Telegraf receives: IOS XE keeps one receiver per subscription active (a second named
  receiver is a standby), so both WLCs use one receiver `mon01` whose host is the VIP
  (`tofu output wlc_telemetry_receiver`).
- `processors.clone` + [`telegraf/wlc.star`](../../modules/services/monitoring/telegraf/wlc.star) turn each YANG
  message into `wlc_<short>_<field>` series (string leaves as labels of `wlc_<short>_info`, the WLC as `host`),
  served on `:9275`; both replicas scrape the backend VIP (job `wlc`). The YANG originals are dropped.
- RRM noise/foreign lists get their `chan` key via `embedded_tags`; the per-process CPU list is dropped
  (`fieldexclude`, colliding fields).
- Known WLC bug (IOS XE 26.01.1): after the first update on a connection the WLC omits the lowest-key entry of
  each multi-entry list (radio slot 0, lowest WLAN id, lowest client MAC). Not fixable in Telegraf; see
  `FIRST_ENTRY_GAP` in `wireless.py`.
- Alerts (`wlc-telemetry`): `WlcTelemetryStopped` (no telemetry for 20 min, summed over both Telegrafs),
  `WlcTelemetryWriteDropping`, `WlcTelemetryNotInPrometheus`.

WLC side (by hand): 27 `telemetry ietf subscription`s on each WLC (ids 101-608, checked 2026-11-15;
`encoding encode-kvgpb`, `stream yang-push`, `update-policy periodic` 3000 or 6000), all pointing at
`telemetry receiver protocol mon01` (port 57500, `grpc-tcp`, no TLS). CLI:
`~/network_automation/wlc-telemetry/wlc-config.md`; field names from a capture: `.../fields.md`. Check:
`journalctl -u telegraf` on the VIP holder, or `count by (host) (wlc_client_live_run_state_clients)`.

## Backend HA (mon01 + mon02)

At most two `role = "monitoring"` VMs: `monitoring_primary` (mon01) and one replica, same rendered stack
(module `backends.tf`).

- **Prometheus pair.** Identical config; `external_labels = {site, ha_cluster = "lylat", __replica__ = "<vm>"}`.
  Both remote_write to Mimir, whose HA tracker keeps one replica's samples and drops `ha_cluster` and `site`.
  Datasources `Prometheus mon01`/`mon02` (uids `prometheus-mon01/-mon02`) look at one replica; only the primary's
  is used for Grafana's alert views.
- **Alertmanager cluster.** Gossip on VLAN 1016 (`10.50.16.30/.31:9094`, label `lylat-alertmanager`). Both
  Prometheus and the Loki ruler send to both; `alert_relabel_configs` drops `__replica__`, so the cluster
  notifies once. Without a VLAN 1016 address on every backend, gossip falls back to the backend NIC.
- **keepalived** (`backend_vrrp`, vrid 102): see [VIPs](#what-runs-where). FAULT when Alertmanager `/-/ready` or
  the WLC Telegraf's `:9273/metrics` fails (the Telegraf check has no `init_fail`, so adding it by reload doesn't
  drop the VIPs). `net.ipv4.ip_nonlocal_bind = 1` lets containers publish on the VIPs.
- **Grafana's database** is the [Patroni cluster](#postgres-ha-patroni). mon01's old Postgres container is gone;
  its leftover `/var/lib/monitoring/postgres` can be deleted by hand.

## Logging (Loki HA)

Logs go to **Loki** on loki01-03 (zoness/titania/fortuna) through **Grafana Alloy**; Grafana datasource `Loki`
(uid `loki`).

```
devices, fw-wan --syslog--> VIP 10.5.11.101 ; PVE nodes' Alloy --> 10.5.11.101:3100 --\
VyOS leaves, DHCP VMs --syslog--> 10.20.11.34-36 (each, mgmt) ------------------------> alloy (VIP holder / each)
every other VM: alloy --journal--> telemetry VIP 10.55.18.101:3100 -------------------/
alloy (each log VM) --> local loki --(ring, RF 3, VLAN 1018)--> all 3 lokis
loki --S3--> 127.0.0.1:7480 haproxy --> RGW on macbeth/titania/venom (10.27.0.12/13/17)
Grafana --> 10.54.18.101:3100 ; Loki ruler --> both Alertmanagers (10.54.16.30/.31:9093)
```

| Network (iface) | loki01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.34-36 | SSH; syslog from VyOS leaves and DHCP VMs (mgmt VRF; no VIP there) |
| lylat-obs, 1401 (`eth1`) | 10.54.18.34-36 | backend, default route: Loki API, haproxy stats; VIP `10.54.18.101` |
| vmbr100 (`eth2`) | 10.5.11.34-36 | VIP `10.5.11.101`: syslog from switches, WLCs, fw-wan; PVE nodes' Alloy pushes |
| vmbr27 (`eth3`) | 10.27.11.34-36 | Ceph public: haproxy -> RGWs |
| 1018 (`eth4`, `ha_logging`) | 10.50.18.34-36, fd69:5018::34-36 | ring (memberlist, gRPC), VRRP adverts |
| lylat-telemetry, 1501 (`eth5`) | 10.55.18.34-36 | Alloy/node_exporter metrics; VIP `10.55.18.101` |

### Loki

- **Monolithic** (`-target=all`); one ring over memberlist on VLAN 1018 (`cluster_label lylat-loki`).
  **RF 3**: writes need two of three ingesters, so one VM can be down.
- **Storage:** TSDB, schema v13 from `logging_settings.schema_start` (never change an existing period; add a
  new one); chunks and index in bucket `loki` via the local haproxy, which health-checks the three RGWs
  (anonymous `GET /` = 200). With RF 3 all three ingesters flush the same chunks (one copy in S3, three writes).
- **Retention:** `logging_settings.retention_period` (90d). One compactor is elected through the ring; delete
  requests live in S3.
- **Ruler:** `/etc/logging/loki/rules/fake/`, sharded over the ruler ring, alerts to both Alertmanagers. Group
  `logging` (`loki_rules_yml` in module `logging.tf`): `RouterOSBGPNoBFD` (spines; leaf-20 excluded),
  `SataLinkReset`, `KernelDiskIOError`, `KernelHardwareError` (PVE kernel lines). VyOS never sends FRR
  `ADJCHANGE`, so the leaves' sessions are alerted from frr_exporter (`fabric` group).
- **Ports:** host networking, every address (the VIPs move). `logging-guard` (`inet logging_guard`) drops 3100
  except from loopback, `loki_allowed_sources` (lylat-app, lylat-obs, lylat-telemetry) and each PVE node's
  vmbr100 address (added in `main.tf`, for their Alloy); 7946/9095 only from the three HA addresses.
- S3 keys only in `/etc/logging/loki.env` (`-config.expand-env`); `loki.yaml` (output `loki_configs`) has none.

### Alloy

- **Log VMs:** syslog on every address, pushed to the local Loki:

  | Listener | Format | Senders | Timestamp |
  | --- | --- | --- | --- |
  | TCP 514 | RFC 5424, octet-counted | VyOS leaves, DHCP VMs, fw-wan | sender's |
  | UDP 514 | RFC 3164 | MikroTik CRS317/CRS326 | receive time |
  | UDP 1514 | raw (unparsed) | C9800 WLCs, FS S3910, FS S3700 (RFC 3164 parsing silently drops their lines) | receive time |

  `raw` is experimental, so the log VMs run Alloy with `--stability.level=experimental` (`alloy validate`
  doesn't check stability, `alloy run` refuses). Labels: `source="syslog"`, `host`, `app`, `level`, `facility`.
  `host` is fixed from the sender address for every `snmp_targets` address and
  `logging_settings.syslog_host_overrides` (names raw lines, fixes generic hostnames like "Switch").
- **Every VM** here and services-config's dns/netbox/proxy/valkey/triage VMs (services-config `alloy.tf`): the
  journal, `source="journal"`, `host` = VM, `unit`, `container`, `app`, `level`; pushed to the telemetry VIP
  `http://10.55.18.101:3100`.
- **PVE nodes:** Alloy .deb installed by hand: [log-senders](log-senders/README.md).

### VIPs and failover (keepalived)

keepalived is the Debian package (host addresses, NET_ADMIN, host-side curl checks, Debian security updates),
not a container.

- One instance (vrid 101) with unicast adverts on `eth4` carries all three VIPs (`eth1`, `eth2`, `eth5`), so
  they move together. Checks every 5 s, 3 failures: Loki `/ready`, Alloy `/-/ready`, a client NIC down
  (`track_interface`), or the VM/keepalived stopping (~3 s of missed adverts). Failover within ~15 s.
- UDP syslog sent during a switchover is lost; TCP senders reconnect and resend; Grafana and pushing Alloys retry.
- If all three fail their checks nobody holds the VIPs (`LoggingVIPNotHeldOnce`).

### Adding a log sender

- Syslog to `10.5.11.101`, or from the mgmt VRF to all three of `10.20.11.34-36`. Prefer **TCP 514 RFC 5424
  octet-counted** (rsyslog: `omfwd`, `RSYSLOG_SyslogProtocol23Format`, `TCP_Framing="octet-counted"`), else
  **UDP 514 RFC 3164**, else **UDP 1514** if RFC 3164 doesn't parse (`loki_source_syslog_parsing_errors_total`).
- No useful hostname in the messages: add its address to `snmp_targets` or `logging_settings.syslog_host_overrides`.
- A Linux VM with Podman: give it a lylat-telemetry NIC and Alloy like services-config's `alloy.tf`.

### Ceph RGW on the PVE nodes

S3 is Ceph RGW (`radosgw` from the PVE Ceph repo, at the cluster version), one daemon each on macbeth, titania
and venom (`client.rgw.<node>`, beast on `10.27.0.<id>:7480`, sections in `/etc/pve/ceph.conf`), not managed by
OpenTofu. `logging_settings.rgw_endpoints` (and the Mimir/Postgres equivalents) list them. Users and buckets:
`loki`, `mimir`, `postgres`; keys go in the git-ignored `logging.secret.auto.tfvars`, `metrics.secret.auto.tfvars`,
`postgres.secret.auto.tfvars`:

```hcl
loki_s3 = { bucket = "loki", access_key = "...", secret_key = "..." }
```

Per-bucket usage comes from a timer on the RGW nodes ([pve-collectors](pve-collectors/README.md)); dashboard
**Storage -> Ceph RGW buckets**, alert group `ceph-rgw-buckets` (thresholds in `rgw_bucket_alerts`).

### Runbook

- **Ring state:** `curl -s http://10.54.18.34:3100/ring` (also `/memberlist`, `/compactor/ring`, `/ruler/ring`,
  `/ready`); each needs three ACTIVE members.
- **S3 path:** `curl -s http://10.54.18.34:8405/stats` (haproxy: which RGWs are UP); on a log VM
  `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7480/` = 200.
- **Syslog arriving?** `sum by (host) (rate(loki_source_syslog_entries_total[5m]))`; Explore `{source="syslog"}`.
- **Move the VIPs** off a VM: `sudo systemctl stop keepalived` there (`nopreempt`: they don't come back on start).
- **Rebuilt log VM:** WAL lost, data safe (RF 3). Apply (new VM ID triggers the deploy, or bump
  `deploy_revision`); the ring forgets the old instance after its heartbeat times out.
- **Alerts** (`logging`): `LokiRingUnhealthy`, `LokiRingMembersMissing`, `LokiIngesterFlushFailures`,
  `SyslogIngestStopped`, `AlloyLokiWriteDrops`, `RGWBackendDegraded`/`RGWBackendDown`, `LoggingVIPNotHeldOnce`.

## Metrics: Mimir HA

Long-term metrics in **Grafana Mimir** on mim01-03 (fichina/venom/eldarad; [`metrics.tf`](metrics.tf), module
[`metrics.tf`](../../modules/services/monitoring/metrics.tf)). Both Prometheus replicas remote_write to it and
Grafana's default datasource (uid `prometheus`) queries it, so dashboards survive either Prometheus being down
and reach back ~13 months.

```
Prometheus mon01/02 --remote_write--> VIP 10.54.17.103:8080 --> distributor -> 3 ingesters (RF 3, VLAN 1017)
Grafana (uid prometheus) --/prometheus--> query-frontend -> schedulers (ring) -> queriers -> ingesters + store-gateways
ingesters --2 h blocks--> 127.0.0.1:7480 haproxy --> RGWs (bucket mimir)
```

| Network (iface) | mim01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.37-39 | SSH |
| lylat-obs, 1401 (`eth1`) | 10.54.17.37-39 | backend, default route: Mimir HTTP, haproxy stats; VIP `10.54.17.103` |
| vmbr27 (`eth2`) | 10.27.11.37-39 | Ceph public: haproxy -> RGWs |
| 1017 (`eth3`, `ha_mimir`) | 10.50.17.37-39, fd69:5017::37-39 | memberlist 7946, gRPC 9095, VRRP adverts |
| lylat-telemetry, 1501 (`eth4`) | 10.55.17.37-39 | node_exporter/Alloy metrics, Alloy pushes |

### Mimir

- **Monolithic** (`-target=all`), **classic architecture** (`ingest_storage.enabled: false` set explicitly; no
  Kafka). Rings over memberlist on VLAN 1017 (`cluster_label lylat-mimir`). **RF 3**. Multitenancy off (tenant
  `anonymous`).
- **Query scheduler in ring mode:** every frontend enqueues on and every querier pulls from all three schedulers.
  The default (`dns`) kept each node on its own scheduler: all queries ran on the VIP holder and hit the queue
  limit (HTTP 429).
- **Storage:** WAL and the last 13 h on local disk (`/var/lib/metrics/mimir`), 2 h blocks to bucket `mimir` via
  the local haproxy. The compactor (one, via its ring) deletes blocks older than `retention_period` (396d).
- **HA tracker** (memberlist KV): accepts one replica (`ha_cluster` / `__replica__`), fails over after 30 s
  without samples, then `drop_labels` removes `ha_cluster` and `site`. `cluster` isn't the HA label because the
  `ceph` job has its own `cluster` label.
- **Limits** (`metrics_settings`): 600k series (300k filled up when the instance relabel briefly doubled the VM
  jobs' series), 40 labels per series, 10 min out-of-order window (replica failover), block upload off (set
  `block_upload_enabled` only for a `mimirtool backfill`). **Ingestion rate 300k/s is per tenant, divided by
  healthy distributors**, and the VIP sends everything to one, so it allows 100k/s. Prometheus treats a 429 as
  non-recoverable and drops the batch, so the limit must cover a WAL catch-up after an outage (at 40k, mon01
  dropped ~1.08M samples on the first deploy).
- **Ports:** host networking. `metrics-guard` (`inet metrics_guard`) drops 8080 except from loopback and
  `allowed_sources` (lylat-obs, lylat-app), and 7946/9095 except from loopback and the three HA addresses.
- S3 keys only in `/etc/metrics/mimir.env`. The ruler runs with no rules; alerting stays in Prometheus.

### Turning it on

Mimir deploys only when `mimir_s3` is set; without it (check `mimir_s3` warns) Prometheus has no remote_write
and Grafana's `prometheus` datasource points at the primary's Prometheus. RGW user/bucket runbook:
`~/network_automation/mon-ha/mimir-runbook.md` (also `mimirtool backfill`).

### Runbook

- **Rings:** `http://10.54.17.37:8080/ingester/ring` (also `/store-gateway/ring`, `/compactor/ring`,
  `/distributor/ring`, `/memberlist`, `/ready`); three ACTIVE members each.
- **HA tracker:** `http://10.54.17.103:8080/distributor/ha_tracker`; `cortex_ha_tracker_elected_replica_status`.
- **Data arriving?** `sum(rate(cortex_distributor_received_samples_total[5m]))`, `prometheus_remote_storage_*`.
- **Rebuilt/dead Mimir VM:** a VM that died stays Unhealthy in the ingester ring (`MimirRingUnhealthy`) and a
  fresh Mimir won't report ready meanwhile: click **Forget** for the old entry on `/ingester/ring`.
- **Alerts** (`metrics`): `MimirRingMembersMissing`, `MimirRingUnhealthy`, `MimirBlockUploadFailures`,
  `MimirCompactorNotRunning`, `MimirDiscardingSamples`, `PrometheusRemoteWriteFailing`,
  `PrometheusRemoteWriteBehind`, `MimirRGWBackendDown`, `MimirVIPNotHeldOnce`.

## Postgres HA: Patroni

Grafana's, NetBox's and dark-triage's database: a **Patroni cluster** on pg01-03 (titania/fortuna/venom;
[`postgres.tf`](postgres.tf), module [`postgres.tf`](../../modules/services/monitoring/postgres.tf)). Live steps:
`~/network_automation/mon-ha/runbook-postgres.md`.

```
graf01/02, netbox, triage --sslmode=require--> VIP 10.56.14.104:5432 (keepalived on the leader; check = Patroni /primary)
  leader: Postgres <-- streaming replication (VLAN 1014) -- 2 replicas (pg_rewind, slots)
  Patroni x3 <--> etcd x3 (DCS, VLAN 1014)   archive_command + daily full backup --> pgBackRest
  --> https://127.0.0.1:7443 haproxy --> RGWs (bucket postgres, path /lylat-pg18, PITR 14 days)
```

| Network (iface) | pg01/02/03 | Used for |
| --- | --- | --- |
| mgmt (`eth0`) | 10.20.11.40-42 | SSH |
| lylat-data, 1601 (`eth1`) | 10.56.14.40-42 | backend, default route: clients -> VIP `10.56.14.104`, scrapes (8008, 2381, 8405) |
| vmbr27 (`eth2`) | 10.27.11.40-42 | Ceph public: haproxy -> RGWs |
| 1014 (`eth3`, `ha_postgres`) | 10.50.14.40-42 | replication, etcd (2379/2380), Patroni REST (8008), VRRP (vrid 104, `fd69:5014::40-42`) |
| lylat-telemetry, 1501 (`eth4`) | 10.55.14.40-42 | scrapes (9187, 9100, 12345), Alloy pushes |

- **Packages, not containers**, for the database: Patroni starts/stops Postgres and `archive_command` needs
  pgBackRest beside it; the only image with all of it is Spilo (Kubernetes-oriented). PostgreSQL, Patroni and
  pgBackRest from PGDG (`trixie-pgdg`; Debian 13 has only 17), etcd from Debian. The deploy installs the PGDG
  source, key and an apt pin first. Versions: `packages` in
  [`software-versions.auto.tfvars`](../../inventory/auto.tfvars/software-versions.auto.tfvars) (`"18.6"` = any
  Debian revision of 18.6; a full Debian version pins exactly). A package missing or outside its pin is installed
  at the newest matching apt version; no match fails the deploy. `policy-rc.d` stops package scripts from
  (re)starting services; unattended-upgrades skips the stack. haproxy, postgres_exporter, node_exporter and
  Alloy are containers.
- **A new major is a rebuild**, not pg_upgrade: the major gives its own Patroni scope and pgBackRest stanza
  (`<cluster_name><major>`, now `lylat-pg18`) and data dir (`/var/lib/postgresql/patroni/<major>`); etcd keeps
  `cluster_name`. Data moves by dump/restore (17 -> 18: DT-046 has steps and rollback).
- **pgBackRest** only speaks HTTPS to S3, so haproxy terminates TLS on `127.0.0.1:7443` with the snakeoil cert.
  S3 keys: `postgres_s3` (git-ignored `postgres.secret.auto.tfvars`), on the VMs in `/etc/postgres-ha/s3.env`.
- **Passwords** (`random_password.pg_*`): superuser, replication, REST API, `pgmon`; Grafana reuses its DB
  password; app passwords from `app-db.secret.auto.tfvars`. `pg-leader-setup` (every deploy, leader only)
  creates roles, databases, the stanza and the first full backup.
- **Deploys never restart Patroni** (it would stop Postgres and fail over the leader): config is SIGHUP-reloaded;
  env/unit changes need a rolling restart. The **first** deploy must run all members together (etcd/Patroni
  bootstrap); later ones with `-parallelism=1`. `sudo pgctl ...` on a member wraps patronictl.
- **Grafana always uses the cluster** (VIP, TLS required); `terraform_data.grafana` fails its precondition
  without it. `bootstrap_from_backup` (+ `restore_target_time`) rebuilds a lost cluster from the repository.
- **Monitoring:** jobs `patroni`, `etcd`, `postgres`, `haproxy-postgres`; node targets `role=postgres`
  (pgBackRest results via the textfile collector); alert group `postgres`; dashboards Postgres cluster/instance.

### Minor upgrade (PostgreSQL, Patroni, etcd, pgBackRest)

What apt offers: `apt-cache madison postgresql-18 patroni etcd-server pgbackrest` on a member.

1. Set the new version in `packages` (e.g. `postgresql = "18.7"`). The plan changes only
   `terraform_data.postgres["pg0N"]`.
2. Apply with `-parallelism=1`. Each member installs the pinned version; nothing restarts, so the old binaries
   keep running.
3. Rolling restart, replicas first: `sudo systemctl restart etcd` (only after an etcd change),
   `sudo systemctl restart patroni` (new Patroni) or `sudo pgctl restart lylat-pg18 <member>` (new PostgreSQL
   only); wait for `sudo pgctl list` to show it `streaming`. Then `sudo pgctl switchover` and do the old leader.
   pgBackRest needs no restart.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Key for `config.ssh_username` on the VMs (passwordless sudo) |
| `deploy_revision` | `"1"` | Change to force a redeploy |
| `backend_vlan_ids` | `[1201, 1401, 1601]` | Zone segments; each VM needs exactly one addressed NIC on one |
| `telemetry_vlan_id` | `1501` | lylat-telemetry: exporters and Alloy listen there |
| `monitoring_primary` | `"mon01"` | Primary backend (Grafana's fallback without Mimir, first VRRP priority) |
| `monitoring_bridge`, `pve_monitoring_bridge` | `vmbr100`, `"100"` | Backends' monitoring NIC; `pve_network.bridges` key for the PVE nodes' scrape addresses |
| `monitoring_ha_vlan_id`, `backend_vrrp` | `1016`; VIPs `10.5.11.102/16`, `10.54.16.102/16`, vrid 102 | Backend HA; `backend_vrrp = null` = no VIPs |
| `grafana_ha_vlan_id`, `grafana_vrrp` | `1011`; `10.52.11.100/16`, vrid 100 | Grafana HA; `null` = no VIP |
| `ha_vlan_id`, `logging_settings` | `1018`; see `variables.tf` | Loki: VIPs, vrid 101, RGW endpoints, retention 90d, RF 3, schema start, allowed sources, syslog host overrides and dedup hosts |
| `loki_s3` | `null` (required with logging VMs) | `logging.secret.auto.tfvars` |
| `metrics_ha_vlan_id`, `metrics_settings` | `1017`; see `variables.tf` | Mimir: VIP, vrid 103, RGW endpoints, RF 3, retention 396d, HA labels, limits, block upload, allowed sources |
| `mimir_s3` | `null` (Mimir off) | `metrics.secret.auto.tfvars` |
| `postgres_ha_vlan_id`, `postgres_settings` | `1014`; see `variables.tf` | Patroni: VIP, vrid 104, cluster name, RGW endpoints, backups, Postgres parameters, etcd timings, `bootstrap_from_backup` |
| `postgres_s3` | `null` (cluster off) | `postgres.secret.auto.tfvars` |
| `app_db_passwords` | `{}` | App database passwords (`app-db.secret.auto.tfvars`, shared with services-config) |
| `settings` | see `variables.tf` | Prometheus retention (7d / 20GB), Grafana root URL, DNS probe zone, Ceph cluster label |
| `pve_api_token`, `greatfox_api_token` | required | PVE API tokens for the metric servers (linked `proxmox.secret.auto.tfvars`) |
| `pve_api_node` | `null` (`nodes.cluster_api_node`) | Node whose API manages the cluster's metric servers |
| `pve_metrics` | `enabled`, `pvestatd_port = 8186` | Proxmox metric servers |
| `pve_exporter_token` | `null` | `null` leaves pve-exporter out |
| `grafana_admin_password` | `null` (generated) | Only applied when Grafana first creates the admin user |
| `snmp_v3_auths` | `{}` | SNMPv3 credentials (the WLCs' `lylat_v3`), git-ignored secret tfvars |
| `wlc_telemetry` | `{ port = 57500 }` | `null` leaves the WLC Telegraf out |
| `snmp_targets`, `vyos_extra_targets`, `vyos_telegraf_targets`, `node_extra_targets`, `ceph_mgr_nodes`, `blackbox_{icmp,http,https}_targets` | see `variables.tf` | Targets outside the inventory |
| `rgw_bucket_alerts` | module defaults | `ceph-rgw-buckets` thresholds |
| `vms`, `nodes`, `fabric`, `pve_network`, `vips`, `containers`, `packages` | linked `*.auto.tfvars` from `inventory/auto.tfvars/` | Inventory; image and package versions live in `software-versions.auto.tfvars` |

## Running it

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config init'
nix-shell --run 'tofu -chdir=roots/monitoring-config plan'
nix-shell --run 'tofu -chdir=roots/monitoring-config apply'
tofu -chdir=roots/monitoring-config output -raw grafana_admin_password
```

Grafana: https://grafana.lylat.space (directly: VIP `http://10.52.11.100:3000`, graf01/02 `10.52.11.32`/`.33`),
user `admin`. Prometheus: `http://10.5.11.30:9090` / `.31`. Needs the `proxmox`, `monitoring`, `logging`,
`metrics`, `postgres` and `app-db` `.secret.auto.tfvars`; the PVE token file is linked with
`ln -s ../../inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars roots/monitoring-config/`.

### Optional: the PVE exporter token

```sh
pveum user add prometheus@pve
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token add prometheus@pve exporter --privsep 0
```

Put it in `inventory/auto.tfvars.secret/monitoring.secret.auto.tfvars` (already linked into this root; it holds `snmp_v3_auths` too):

```hcl
pve_exporter_token = { user = "prometheus@pve", token_name = "exporter", value = "<uuid>" }
```

Not set today: no `pve` job, so no VM/HA state from the PVE API (pvestatd covers guest metrics).

## Things to know

- **Alertmanager routes everything to a `null` receiver.** Alerts show in Alertmanager and Grafana but go
  nowhere until a receiver is added. `CephHealthCheckWarn` inhibits the mixin's `CephHealthWarning`.
- **Postgres (10.56.14.104) is in lylat-data**, which only lylat-app, lylat-dns and lylat-external import
  (pg_hba and `postgres-guard` narrow the clients further).
- **The Proxmox metric servers are managed here** ([`pve-metrics.tf`](pve-metrics.tf)): on the cluster and on
  standalone greatfox, one per backend (`pvestatd-mon01`, `pvestatd-mon02`, type `influxdb` because that's the
  protocol) pushing node, guest and storage stats every ~10 s to that backend's pvestatd Telegraf. Uses the bpg
  provider (cluster API and the `proxmox.greatfox` alias).
- **greatfox down = untargeted plans fail** refreshing `proxmox_metrics_server.pvestatd_standalone`
  (`dial tcp 10.20.7.20:8006`). Until it's back:
  `tofu -chdir=roots/monitoring-config plan -exclude='proxmox_metrics_server.pvestatd_standalone'` (same for apply).
- **Prometheus scrape/rule panels** on the Prometheus dashboard only show the replica Mimir keeps.

### Retired: InfluxDB

InfluxDB 2 ran on mon01/02 from 2026-11-09 to 2026-11-14 (PVE metric servers, C9800 telemetry, fw-wan's
Telegraf). Everything now goes to Prometheus/Mimir; the buckets `pve_cluster`, `pve_greatfox` and `wlc` are
backfilled into Mimir under the live names (`~/network_automation/mon-ha/mimir-runbook.md`). Its data dirs are
gone from both backends (checked 2026-11-15). The monitoring VIP `10.5.11.102` stayed as the WLCs' receiver.

## Tests

```sh
nix-shell --run 'tofu -chdir=roots/monitoring-config test'
```

- `monitoring.tftest.hcl` (real inventory, mocked `random`): derived targets, exporters and Ceph alerts, pve-exporter
  only with a token, SNMPv3 and `mikrotik_lite`, scrape timeouts, infra alerts, PVE metric servers, WLC telemetry
  (on/off), logging (ring, RF 3, S3 via haproxy, keepalived per VM, Alloy listeners, missing S3 keys or HA NIC
  fail), Grafana HA, backend HA (identical scrapes per replica, Alertmanager gossip, keepalived, VIP publishes,
  single-backend and VRRP-off variants), services-config Alloy targets, and the dashboards (files, uids, tags,
  dropdowns, datasources, no restart on JSON change, pruning).
- `metrics.tftest.hcl`: Mimir config, HA tracker and limits, remote_write and datasource switch, keepalived,
  nothing Mimir without `mimir_s3`, HA NIC required.
- `postgres.tftest.hcl`: Patroni/etcd on VLAN 1014, pg_hba, guard, keepalived on `/primary`, pgBackRest via TLS
  haproxy, packages and order, scrapes/alerts, Grafana on the VIP, `bootstrap_from_backup`, major override/validation.
- `rgw.tftest.hcl`: the `ceph-rgw-buckets` rules and thresholds.
