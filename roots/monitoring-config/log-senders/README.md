# Log senders

Devices, routers and the PVE nodes ship their logs as syslog to Alloy on loki01–loki03. (The Linux
service VMs push their journal with Alloy to Loki's telemetry VIP instead; see the
[monitoring-config README](../README.md#alloy).) The exception on the PVE nodes: Grafana Alloy there pushes
the Ceph daemon logs to Loki's API (see [Ceph daemon logs](#ceph-daemon-logs-grafana-alloy-on-the-pve-nodes-dt-021)).
Alloy on loki01–03 listens on:

| Listener | Format | Who sends there |
|---|---|---|
| TCP 514 | RFC 5424, octet-counted | VyOS (leaves, dhcp01/02, fw-wan), rsyslog (PVE nodes) |
| UDP 514 | RFC 3164 | MikroTik (spines, CRS317) |
| UDP 1514 | raw (no parsing; host from the source IP) | Cisco C9800 WLCs, FS S3910 (switch-2), FS S3700 (switch-1) |

The 1514 listener exists because Alloy's RFC 3164 parser drops some formats without
logging anything: IOS-XE's `<189>45: host: *Nov  9 …`, the S3910's `<189>FS 2026-11-10 …`,
and the S3700's otherwise valid RFC 3164 lines, because they end in a NUL byte. Each was
replayed through Alloy v1.16 to confirm this. Raw lines keep the device's own header (and
the S3700's trailing `\x00`). The `host` label comes from the source-IP map in
monitoring-config (`snmp_targets` addresses plus `logging_settings.syslog_host_overrides`),
which also fixes generic hostnames (`Switch`, `FS`).

Targets: the keepalived VIP `10.5.11.101` (`logs-vip.lylat.space`, monitoring network / VLAN 5), or on the
management network each log VM's own address, `10.20.11.34`–`.36` (no VIP there; senders send to all three).

## Managed by OpenTofu (plan only here; see each root)

| Source | Where | What |
|---|---|---|
| VyOS leaves | fabric-leaves, `fabric.settings.leaf_syslog` | `system syslog remote` 10.20.11.34, .35 and .36, TCP, `vrf mgmt` |
| m326-1/2 (spines) | fabric-spines, `fabric.settings.spine_syslog` | `remote` logging action → 10.5.11.101 UDP 514, topics info/warning/error/critical |
| dhcp01/02 | services-config, `dhcp_syslog` | same as the leaves |

## Configured by hand

Applied on 2026-11-09; every source was verified in Loki (`label/host/values` and a query
per host):

| Source | Method | Status |
|---|---|---|
| fw-wan | VyOS syslog, TCP 514 → 10.5.11.101 from `lylat-external`, saved | verified (`host="fw-wan"`, strongSwan, kernel, FRR…) |
| m317-1/2 | RouterOS `remote` action, UDP 514 (applied live; RouterOS saves immediately) | verified |
| switch-1 | `logging 10.5.11.101 port 1514`, `write` | verified (raw) |
| switch-2 | `logging server 10.5.11.101 udp-port 1514`, `write` | verified (raw) |
| c9800-wlc-1/2 | `logging host … transport udp port 1514`, `write memory` | verified (raw) |
| PVE nodes (all 8) | rsyslog, TCP 514 → 10.5.11.101 | verified, journal of every node |
| Ceph cluster log | rsyslog imfile on the 4 mons (macbeth, titania, zoness, venom) | verified (`app="ceph-cluster"`; `ceph log` test line seen from all 4) |

### PVE nodes (fichina … venom, greatfox)

rsyslog forwards the journal over TCP to `10.5.11.101` from the node's 10.5.1.x address.
On the Ceph mon nodes it also tails the Ceph cluster log (`/var/log/ceph/ceph.log`),
which isn't in the journal (`mon_cluster_log_to_journald=false`). Every mon writes the same
cluster log, so each line arrives once per mon (`app="ceph-cluster"`; filter on one
`host`). The files in this folder:

- [`pve-30-loki.conf`](pve-30-loki.conf) → `/etc/rsyslog.d/30-loki.conf`: forward
  `*.info` and `stop`, so nothing gets written to `/var/log` and the journal stays the
  local store. It has a disk-assisted queue (128 MB) for when the receiver is down. It
  must sort before the packages' own rules: FRR's `45-frr.conf` sends FRR's daemons to
  `/var/log/frr/frr.log` and stops them there, so with a later file name, FRR logs
  never reached Loki.
- [`pve-40-ceph-cluster-log.conf`](pve-40-ceph-cluster-log.conf) →
  `/etc/rsyslog.d/40-ceph-cluster-log.conf`: imfile on `ceph.log`, starting at the end of
  the file. `[DBG]` lines (the mgr's pgmap every 2 s, about 43k a day per mon) are dropped;
  INF/WRN/ERR are forwarded. Installed only where that file exists.
- [`pve-install.sh`](pve-install.sh): installs the files, then the `rsyslog` package,
  then runs `rsyslogd -N1` and restarts rsyslog.

```sh
cd roots/monitoring-config/log-senders
for ip in 10.20.7.11 10.20.7.12 10.20.7.13 10.20.7.14 10.20.7.15 10.20.7.16 10.20.7.17 10.20.7.20; do
  scp pve-30-loki.conf pve-40-ceph-cluster-log.conf pve-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/pve-install.sh
done
```

### Ceph daemon logs: Grafana Alloy on the PVE nodes (DT-021)

Ceph writes its daemon logs only to files (`log_to_syslog`/`log_to_journald` are false), so neither
the journal forwarder nor pve-40 sees them. Grafana Alloy on each Ceph node tails them and pushes to
Loki; rsyslog stays as it is (journal + cluster log, same labels as before). Alloy could later take
over the journal too (comment at the top of the config); not done yet.

| Files | Labels |
|---|---|
| `/var/log/ceph/ceph-{osd,mon,mgr,mds}.*.log`, `ceph-client.rgw.*.log` (not `ceph.log`/`ceph.audit.log`: cluster log is pve-40's) | `host` (node short name), `source="ceph"`, `app=ceph-osd\|ceph-mon\|ceph-mgr\|ceph-mds\|ceph-rgw`, `daemon=osd.8\|mon.venom\|mgr.titania\|mds.zoness\|rgw.venom`, `level` |

- [`pve-alloy.config.alloy`](pve-alloy.config.alloy) → `/etc/alloy/pve.alloy`. `local.file_match` →
  `discovery.relabel` (app/daemon from the file name) → `loki.source.file` (`tail_from_end`: no backfill on
  the first start, then the positions file) → `loki.process "ceph"` → `http://10.5.11.101:3100` (Loki on
  the VLAN 5 VIP, directly connected from the nodes' 10.5.1.x; logging-guard admits exactly those
  addresses on 3100, monitoring-config `main.tf`).
  - Multiline: continuation lines (RocksDB stats tables, crash backtraces) join the timestamped line.
  - Timestamp from the line (`2026-11-14T02:20:01.123-0500`).
  - `level`, journal words: Ceph priority `-1` → error, `0` → notice, `1`–`5` → info, `>5` → debug; the
    mgr modules' own `[module LEVEL module]` and cluster-log copies' `[DBG|INF|WRN|ERR|SEC]` win;
    heartbeat timeouts, slow ops/requests and RGW 5xx → warning.
  - Drops (`loki_process_dropped_lines_total{reason}` on Alloy's :12345): `ceph_rgw_request` (beast access
    lines and `starting new request`/`req done` of non-5xx requests, ~99.9 % of the RGW log),
    `ceph_mgr_no_orchestrator`, `ceph_mgr_periodic` (active mgr's module chatter: DEBUG, idle-connection
    sweep, pg_autoscaler per-pool report, rbd_support schedule reloads, no-op balancer runs),
    `ceph_clog_debug` (`log_channel(cluster|audit) log [DBG]` copies: pgmap, read-only command audit),
    `ceph_mon_poll` (`ceph df`/`osd blocklist ls` polls), `ceph_mon_cache_autotune`, `ceph_rocksdb`
    (RocksDB housekeeping; write stalls and errors kept), `ceph_logrotate_hup`.
- [`pve-alloy-install.sh`](pve-alloy-install.sh): installs Grafana's release `.deb` pinned by version and
  SHA-256 (no apt repo, so `apt full-upgrade` never moves it; same v1.21.3 as the VMs' container), the
  config, `/etc/alloy/pve.env` (`CONFIG_FILE`, `CUSTOM_ARGS`: HTTP on the node's 10.5.1.x:12345) and a
  unit drop-in that reads it after the package's `/etc/default/alloy` (conffiles stay pristine) plus
  sandboxing (`ProtectSystem=strict`, `MemoryMax=1G`). Read access: ACL `u:alloy:r-x` on `/var/log/ceph`
  (ceph:ceph 2770; daemon logs are 0644), not group `ceph` (writable dir). Restarts Alloy, checks
  `/-/ready` and the journal. Idempotent.

Volume (replay of a day of real logs through the pipeline): ~110–130 lines/day on a node with a mon,
two OSDs and an RGW (venom 424k raw → 111, zoness 149k → 126), ~3.2k/day on the node with the active
mgr (titania 538k → 3,165; 1,459 of them the once-a-minute pg_autoscaler `cephfs_metadata won't scale`
warning). Incident days are higher: venom's OSD heartbeat-timeout week averaged ~2.3k/day.

Apply order: monitoring-config first (logging-guard on loki01–03 lets the PVE nodes reach 3100;
check from a node: `curl -s -o /dev/null -w '%{http_code}' http://10.5.11.101:3100/ready` → 200), then
Alloy, one canary node first (titania: active mgr, mon, OSDs, RGW):

```sh
cd roots/monitoring-config/log-senders
# optional: fetch the .deb once here and scp it along (the script verifies the checksum either way)
for ip in 10.20.7.13; do   # canary; then 10.20.7.11 .12 .14 .15 .16 .17 (greatfox has no Ceph)
  scp pve-alloy.config.alloy pve-alloy-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/pve-alloy-install.sh
done
```

Check: `lylat-obs logtop '{source="ceph"}' --by host,app --since 30m`, and
`curl -s http://10.5.1.13:12345/metrics | grep -E 'loki_process_dropped_lines_total|loki_write_(sent|dropped)_entries_total'`.
To scrape Alloy later, add the nodes as `targets.alloy` (`10.5.1.<id>:12345`) in monitoring-config.

### fw-wan

See the fw-wan section of the [monitoring-config README](../README.md). It sends from
`lylat-external` (10.5.0.255) to `10.5.11.101`, TCP, RFC 5424. Firewall `log` rules
(kernel) and strongSwan/IPsec logs are included at `info` and up.

```
set system syslog remote 10.5.11.101 facility all level 'info'
set system syslog remote 10.5.11.101 port '514'
set system syslog remote 10.5.11.101 protocol 'tcp'
set system syslog remote 10.5.11.101 format include-timezone
set system syslog remote 10.5.11.101 format octet-counted
set system syslog remote 10.5.11.101 vrf 'lylat-external'
set system syslog remote 10.5.11.101 source-address '10.5.0.255'
```

### m317-1/2 (MikroTik CRS317, 10.20.0.3/.4)

Same settings as the spines (which OpenTofu manages). The source address is chosen by
the route, so it's the switch's VLAN 5 address (10.5.0.3/.4).

```
/system logging action set [find name=remote] remote=10.5.11.101 remote-port=514 remote-protocol=udp remote-log-format=syslog syslog-time-format=bsd-syslog syslog-facility=daemon
/system logging add topics=info action=remote
/system logging add topics=warning action=remote
/system logging add topics=error action=remote
/system logging add topics=critical action=remote
```

RouterOS saves configuration changes immediately.

### switch-1 (FS S3700, 10.20.0.1)

The CLI uses `config`, not `configure terminal`. The format stays at the default, RFC 3164,
but the messages go to the raw listener on 1514 (see above: the trailing NUL).

```
enable
config
logging 10.5.11.101 port 1514
logging source-interface Vlan 5
exit
write
```

The switch's clock says 2000 (no NTP), so Alloy stamps these lines with the receive
time; the `Jan 26 …` inside the line is the switch's own clock. Careful with `?` on this
CLI: Ctrl-U doesn't clear the line, so the half-typed command runs on the next Enter.

### switch-2 (FS S3910, 10.20.0.2)

FSOS, which lands in `FS#`. Messages go to the raw listener on UDP 1514.

```
configure terminal
logging server 10.5.11.101 udp-port 1514
logging source interface VLAN 5
logging trap informational
end
write
```

### c9800-wlc-1/2 (Cisco C9800-CL, 10.20.1.1/.2)

IOS-XE sends from Vlan5 (10.5.1.1/.2). Messages go to the raw listener on UDP 1514.

```
configure terminal
logging host 10.5.11.101 transport udp port 1514
logging source-interface Vlan5
logging trap informational
logging origin-id hostname
end
write memory
```

## Checking

From mon01 (lylat-obs; Loki's backend VIP `10.54.18.101`):

```sh
curl -sG http://10.54.18.101:3100/loki/api/v1/label/host/values | jq
curl -sG http://10.54.18.101:3100/loki/api/v1/query_range --data-urlencode 'query={host="m326-1"}' --data-urlencode limit=5 | jq '.data.result[].values'
curl -sG http://10.54.18.101:3100/loki/api/v1/query --data-urlencode 'query=sum by (host) (count_over_time({source="syslog"}[30m]))' | jq -r '.data.result[] | "\(.metric.host) \(.value[1])"'
```

To test a sender by hand: `logger -n 10.5.11.101 -P 514 -T --rfc5424 -t test hello` from a
Linux box, `/log info "loki test"` on a MikroTik, `send log 6 loki test` on a WLC, or
`ceph log "loki test"` for the Ceph cluster log.
