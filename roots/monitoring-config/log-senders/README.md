# Log senders

Devices and routers send syslog to Alloy on loki01-03; the PVE nodes run Grafana Alloy and push to Loki's API
([below](#pve-nodes-grafana-alloy-journal-ceph-cluster-log-ceph-daemon-logs)). Linux service VMs push their
journal with Alloy to the telemetry VIP ([monitoring-config README](../README.md#alloy)).

| Listener | Format | Senders |
|---|---|---|
| TCP 514 | RFC 5424, octet-counted | VyOS (leaves, dhcp01/02, fw-wan) |
| UDP 514 | RFC 3164 | MikroTik (spines, CRS317) |
| UDP 1514 | raw (no parsing; `host` from the source IP) | C9800 WLCs, FS S3910 (switch-2), FS S3700 (switch-1) |

Why 1514: Alloy's RFC 3164 parser silently drops IOS-XE's `<189>45: host: *Nov  9 …`, the S3910's
`<189>FS 2026-11-10 …` and the S3700's otherwise valid lines (they end in a NUL byte). Raw lines keep the device's
header (and the S3700's `\x00`). `host` comes from the source-IP map in monitoring-config (`snmp_targets`
addresses plus `logging_settings.syslog_host_overrides`), which also fixes generic hostnames (`Switch`, `FS`).

Targets: the VIP `10.5.11.101` (`logs-vip.lylat.space`, monitoring network / VLAN 5), or from the mgmt network
all three log VMs `10.20.11.34`-`.36` (no VIP on mgmt).

## Managed by OpenTofu

| Source | Where | What |
|---|---|---|
| VyOS leaves | fabric-leaves, `fabric.settings.leaf_syslog` | TCP to 10.20.11.34/.35/.36, `vrf mgmt` |
| m326-1/2 (spines) | fabric-spines, `fabric.settings.spine_syslog` | `remote` action -> 10.5.11.101 UDP 514, topics info/warning/error/critical |
| dhcp01/02 | services-config, `dhcp_syslog` | same as the leaves |

## Configured by hand

All verified in Loki (`label/host/values` and a query per host) when applied.

| Source | Method |
|---|---|
| fw-wan | VyOS syslog, TCP 514 -> 10.5.11.101 from `lylat-external` |
| m317-1/2 | RouterOS `remote` action, UDP 514 |
| switch-1 | `logging 10.5.11.101 port 1514` (raw) |
| switch-2 | `logging server 10.5.11.101 udp-port 1514` (raw) |
| c9800-wlc-1/2 | `logging host … transport udp port 1514` (raw) |
| PVE nodes (7 cluster nodes + greatfox) | Grafana Alloy -> Loki API: journal, Ceph cluster log, Ceph daemon logs (greatfox: journal only) |

### PVE nodes: Grafana Alloy (journal, Ceph cluster log, Ceph daemon logs)

Alloy ships everything; rsyslog forwards nothing and, via `/etc/rsyslog.d/30-journal-only.conf` (`stop`), writes
nothing to `/var/log/*` (the journal is the local store; FRR's `45-frr.conf` never runs). The old rsyslog
forwarders (`30-loki.conf`, `40-ceph-cluster-log.conf`, `source="syslog"`) were retired on 2026-11-14.
Tofu-managing this install is a dark-triage ticket.

| Stream | Labels |
|---|---|
| journal (all of it, kernel included; priority debug dropped) | `host`, `source="journal"`, `unit`, `container`, `app` (SYSLOG_IDENTIFIER, the same value rsyslog sent, so `app="corosync"`, `"pve-ha-lrm"`, `"kernel"` still match), `level` (`emerg alert crit err warning notice info`) |
| Ceph cluster log `/var/log/ceph/ceph.log`, mon nodes only (`[DBG]` dropped) | `host`, `source="ceph"`, `app="ceph-cluster"`, `level` (from `[ERR]`/`[WRN]`/`[SEC]`/`[INF]`). Every mon writes the same log, so each line arrives once per mon: filter on one `host` |
| `/var/log/ceph/ceph-{osd,mon,mgr,mds}.*.log`, `ceph-client.rgw.*.log` | `host`, `source="ceph"`, `app=ceph-osd\|ceph-mon\|ceph-mgr\|ceph-mds\|ceph-rgw`, `daemon=osd.8\|mon.venom\|…`, `level` (`error`, `warning`, …) |

`ceph.audit.log` is not read. The *Proxmox & Ceph logs* dashboard selects `source=~"journal|syslog"` so pre-switch
history stays visible; drop `syslog` once retention (90d) has aged it out.

- [`pve-alloy.config.alloy`](pve-alloy.config.alloy) -> `/etc/alloy/pve.alloy`, pushes to
  `http://10.5.11.101:3100` (directly connected from the nodes' 10.5.1.x; logging-guard admits exactly those on
  3100, monitoring-config `main.tf`).
  - journal: `loki.relabel "journal"` (same rules as the VMs, plus the debug drop) -> `loki.source.journal`
    (`max_age` 12h; positions under `/var/lib/alloy/data`).
  - cluster log: `loki.source.file` (`tail_from_end`) -> `loki.process "ceph_cluster"` (debug drop, level,
    timestamp from the line).
  - daemon logs: `local.file_match` -> `discovery.relabel` (app/daemon from the file name) -> `loki.source.file`
    -> `loki.process "ceph"`: multiline (RocksDB stats, backtraces), timestamp, level (Ceph priority `-1` ->
    error, `0` -> notice, `1`-`5` -> info, `>5` -> debug; mgr `[module LEVEL module]` and cluster-log
    `[DBG|INF|WRN|ERR|SEC]` win; heartbeat timeouts, slow ops, RGW 5xx -> warning). Noise drops are counted in
    `loki_process_dropped_lines_total{reason}` (`ceph_rgw_request`, `ceph_mgr_no_orchestrator`,
    `ceph_mgr_periodic`, `ceph_clog_debug`, `ceph_mon_poll`, `ceph_mon_cache_autotune`, `ceph_rocksdb`,
    `ceph_logrotate_hup`).
- [`pve-alloy-install.sh`](pve-alloy-install.sh), idempotent:
  - Grafana's release `.deb` pinned by `ALLOY_VERSION` + `ALLOY_SHA256` (no apt repo). Keep it in step with
    `alloy` in `inventory/auto.tfvars/software-versions.auto.tfvars`.
  - `/etc/alloy/pve.env` (`CONFIG_FILE`, `CUSTOM_ARGS`: HTTP on the node's 10.5.1.x:12345) and a unit drop-in read
    after the package's `/etc/default/alloy` (conffiles stay pristine), with `AmbientCapabilities=CAP_DAC_READ_SEARCH`
    (ceph.log is ceph:ceph 0600 and recreated on rotation, so an ACL wouldn't stick), `ProtectSystem=strict`,
    `NoNewPrivileges`, `MemoryMax=1G`.
  - Replaces rsyslog's forwarders with `30-journal-only.conf` and restarts rsyslog.
  - First journal start runs with `max_age 1m` for 15 s (no 12 h backfill), then the real config. Checks `/-/ready`.
  - Alloy's SIGHUP reload hangs on journal pipeline changes: the script restarts, never reloads.

```sh
cd roots/monitoring-config/log-senders
for ip in 10.20.7.12; do   # canary (mon node); then 10.20.7.11 .13 .14 .15 .16 .17 .20
  scp pve-alloy.config.alloy pve-alloy-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/pve-alloy-install.sh
done
```

Check from a node (logging-guard only admits the nodes and VMs on 3100):
`curl -sG http://10.5.11.101:3100/loki/api/v1/query --data-urlencode 'query=sum by (host, source) (count_over_time({host=~"fichina|macbeth|titania|zoness|fortuna|eldarad|venom|greatfox"}[10m]))'`
and `curl -s http://10.5.1.12:12345/metrics | grep -E 'loki_process_dropped_lines_total|loki_write_(sent|dropped)_entries_total|loki_source_journal_target_lines_total'`.
Prometheus doesn't scrape these Alloys; to do so, add the nodes (`10.5.1.<id>:12345`) to `targets.alloy` in
monitoring-config.

### fw-wan

Config and the rest of fw-wan's hand setup: [monitoring-config README](../README.md#fw-wan-vyos-edge-router-configured-by-hand).
Sends from `lylat-external` (10.5.0.255) to `10.5.11.101`, TCP, RFC 5424, `info` and up (firewall `log` rules,
strongSwan, FRR).

### m317-1/2 (MikroTik CRS317, 10.20.0.3/.4)

Same as the spines. The source address follows the route: the switch's VLAN 5 address. RouterOS saves immediately.

```
/system logging action set [find name=remote] remote=10.5.11.101 remote-port=514 remote-protocol=udp remote-log-format=syslog syslog-time-format=bsd-syslog syslog-facility=daemon
/system logging add topics=info action=remote
/system logging add topics=warning action=remote
/system logging add topics=error action=remote
/system logging add topics=critical action=remote
```

### switch-1 (FS S3700, 10.20.0.1)

CLI uses `config`, not `configure terminal`. Format stays RFC 3164 but goes to the raw listener (trailing NUL).

```
enable
config
logging 10.5.11.101 port 1514
logging source-interface Vlan 5
exit
write
```

No NTP (clock says 2000): Alloy stamps receive time; the `Jan 26 …` in the line is the switch's clock. Careful
with `?`: Ctrl-U doesn't clear the line, so the half-typed command runs on the next Enter.

### switch-2 (FS S3910, 10.20.0.2)

FSOS (`FS#` prompt).

```
configure terminal
logging server 10.5.11.101 udp-port 1514
logging source interface VLAN 5
logging trap informational
end
write
```

### c9800-wlc-1/2 (Cisco C9800-CL, 10.20.1.1/.2)

Sends from Vlan5 (10.5.1.1/.2).

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

Test a sender by hand: `logger -n 10.5.11.101 -P 514 -T --rfc5424 -t test hello` (Linux), `/log info "loki test"`
(MikroTik), `send log 6 loki test` (WLC), `ceph log "loki test"` (Ceph cluster log).
