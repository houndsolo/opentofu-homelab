# Log senders

Devices and routers ship their logs as syslog to Alloy on loki01–loki03. (The Linux service VMs push
their journal with Alloy to Loki's telemetry VIP instead; see the [monitoring-config README](../README.md#alloy).
The PVE nodes push everything with Grafana Alloy to Loki's API since 2026-11-14; see
[PVE nodes](#pve-nodes-grafana-alloy-journal-ceph-cluster-log-ceph-daemon-logs).)
Alloy on loki01–03 listens on:

| Listener | Format | Who sends there |
|---|---|---|
| TCP 514 | RFC 5424, octet-counted | VyOS (leaves, dhcp01/02, fw-wan) |
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
| PVE nodes (7 cluster nodes) | Grafana Alloy → Loki API (journal, Ceph cluster log, Ceph daemon logs), 2026-11-14 | verified; greatfox was off, still on rsyslog until the installer is run there |

### PVE nodes: Grafana Alloy (journal, Ceph cluster log, Ceph daemon logs)

Until 2026-11-14 rsyslog forwarded the journal and the Ceph cluster log as syslog (`source="syslog"`,
`pve-30-loki.conf`/`pve-40-ceph-cluster-log.conf`, removed from this folder; see git history), and Alloy only
tailed the Ceph daemon logs (DT-021). Now Alloy ships all three; rsyslog forwards nothing and, through
`/etc/rsyslog.d/30-journal-only.conf` (`stop`), writes nothing to `/var/log/*` (the journal stays the local
store, FRR's `45-frr.conf` never runs). Tofu-managing this install is a dark-triage ticket.

| Stream | Labels |
|---|---|
| journal (everything journald has, kernel included; priority debug dropped like rsyslog's `*.info`) | `host`, `source="journal"`, `unit`, `container`, `app` (SYSLOG_IDENTIFIER: the same value rsyslog sent as APP-NAME, so `app="corosync"`, `"pve-ha-lrm"`, `"kernel"` still match), `level` (journal words: `emerg alert crit err warning notice info`) |
| Ceph cluster log `/var/log/ceph/ceph.log`, mon nodes only (`[DBG]` dropped) | `host`, `source="ceph"`, `app="ceph-cluster"`, `level` (`err`/`warning`/`crit`/`info` from `[ERR]`/`[WRN]`/`[SEC]`/`[INF]`); every mon writes the same cluster log, so each line arrives once per mon: filter on one `host` |
| `/var/log/ceph/ceph-{osd,mon,mgr,mds}.*.log`, `ceph-client.rgw.*.log` | `host`, `source="ceph"`, `app=ceph-osd\|ceph-mon\|ceph-mgr\|ceph-mds\|ceph-rgw`, `daemon=osd.8\|mon.venom\|…`, `level` (long words: `error`, `warning`, …) |

`ceph.audit.log` is not read. The Grafana dashboard *Proxmox & Ceph logs* selects `source=~"journal|syslog"` so
history from before the switch stays visible; the `syslog` alternative can go once retention has aged it out.

- [`pve-alloy.config.alloy`](pve-alloy.config.alloy) → `/etc/alloy/pve.alloy`, everything → `http://10.5.11.101:3100`
  (Loki on the VLAN 5 VIP, directly connected from the nodes' 10.5.1.x; logging-guard admits exactly those
  addresses on 3100, monitoring-config `main.tf`).
  - journal: `loki.relabel "journal"` (same rules as the VMs' config.alloy, plus the debug drop) →
    `loki.source.journal` (`max_age` 12h; positions under `/var/lib/alloy/data`).
  - cluster log: `loki.source.file` (`tail_from_end`) → `loki.process "ceph_cluster"` (`ceph_cluster_debug`
    drop, level, timestamp from the line).
  - daemon logs: `local.file_match` → `discovery.relabel` (app/daemon from the file name) → `loki.source.file`
    → `loki.process "ceph"`: multiline (RocksDB stats tables, backtraces), timestamp from the line, level
    (priority `-1` → error, `0` → notice, `1`–`5` → info, `>5` → debug; mgr modules' `[module LEVEL module]` and
    cluster-log copies' `[DBG|INF|WRN|ERR|SEC]` win; heartbeat timeouts, slow ops, RGW 5xx → warning), drops
    (`loki_process_dropped_lines_total{reason}` on :12345): `ceph_rgw_request`, `ceph_mgr_no_orchestrator`,
    `ceph_mgr_periodic`, `ceph_clog_debug`, `ceph_mon_poll`, `ceph_mon_cache_autotune`, `ceph_rocksdb`,
    `ceph_logrotate_hup`. ~110–130 lines/day per node, ~3.2k on the active mgr's node.
- [`pve-alloy-install.sh`](pve-alloy-install.sh), idempotent: Grafana's release `.deb` pinned by version and
  SHA-256 (no apt repo; same v1.21.3 as the VMs' container), the config, `/etc/alloy/pve.env` (`CONFIG_FILE`,
  `CUSTOM_ARGS`: HTTP on the node's 10.5.1.x:12345), a unit drop-in read after the package's
  `/etc/default/alloy` (conffiles stay pristine) with `AmbientCapabilities=CAP_DAC_READ_SEARCH` (ceph.log is
  ceph:ceph 0600 and recreated on every rotation, so an ACL wouldn't stick) and sandboxing
  (`ProtectSystem=strict`, `MemoryMax=1G`, `NoNewPrivileges`). Replaces rsyslog's `30-loki.conf`/`40-ceph-cluster-log.conf`
  with `30-journal-only.conf` and restarts rsyslog. On the first journal start it runs with `max_age 1m` for 15 s
  (no 12 h backfill of lines rsyslog already delivered), then the real config. Checks `/-/ready` and the log.
  Alloy's SIGHUP reload hangs on journal pipeline changes: the script restarts, never reloads.

```sh
cd roots/monitoring-config/log-senders
for ip in 10.20.7.12; do   # canary (mon node); then 10.20.7.11 .13 .14 .15 .16 .17 .20
  scp pve-alloy.config.alloy pve-alloy-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/pve-alloy-install.sh
done
```

Check (from a node; logging-guard only admits the nodes and VMs on 3100):
`curl -sG http://10.5.11.101:3100/loki/api/v1/query --data-urlencode 'query=sum by (host, source) (count_over_time({host=~"fichina|macbeth|titania|zoness|fortuna|eldarad|venom|greatfox"}[10m]))'`
and `curl -s http://10.5.1.12:12345/metrics | grep -E 'loki_process_dropped_lines_total|loki_write_(sent|dropped)_entries_total|loki_source_journal_target_lines_total'`.
To scrape Alloy, add the nodes as `targets.alloy` (`10.5.1.<id>:12345`) in monitoring-config.

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
