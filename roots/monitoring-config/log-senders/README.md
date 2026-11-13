# Log senders

Everything that ships logs to Loki does it as syslog to Alloy on loki01–loki03, through the
keepalived VIPs. Nothing uses Loki's push API directly. Alloy listens on:

| Listener | Format | Who sends there |
|---|---|---|
| TCP 514 | RFC 5424, octet-counted | VyOS (leaves, dhcp01/02, fw-wan), rsyslog (PVE nodes, dns01/02) |
| UDP 514 | RFC 3164 | MikroTik (spines, CRS317) |
| UDP 1514 | raw (no parsing; host from the source IP) | Cisco C9800 WLCs, FS S3910 (switch-2), FS S3700 (switch-1) |

The 1514 listener exists because Alloy's RFC 3164 parser drops some formats without
logging anything: IOS-XE's `<189>45: host: *Nov  9 …`, the S3910's `<189>FS 2026-11-10 …`,
and the S3700's otherwise valid RFC 3164 lines, because they end in a NUL byte. Each was
replayed through Alloy v1.16 to confirm this. Raw lines keep the device's own header (and
the S3700's trailing `\x00`). The `host` label comes from the source-IP map in
monitoring-config (`snmp_targets` addresses plus `logging_settings.syslog_host_overrides`),
which also fixes generic hostnames (`Switch`, `FS`).

VIPs: `10.5.11.101` (`logs-vip.lylat.space`, monitoring network / VLAN 5) and `10.20.11.101`
(management network).

## Managed by OpenTofu (plan only here; see each root)

| Source | Where | What |
|---|---|---|
| VyOS leaves | fabric-leaves, `fabric.settings.leaf_syslog` | `system syslog remote 10.20.11.101`, TCP, `vrf mgmt` |
| m326-1/2 (spines) | fabric-spines, `fabric.settings.spine_syslog` | `remote` logging action → 10.5.11.101 UDP 514, topics info/warning/error/critical |
| dhcp01/02 | services-config, `dhcp_syslog` | same as the leaves |
| dns01/02 | services-config, `dns_syslog` | rsyslog forwarder for the journal (BIND included) → 10.20.11.101 TCP |

## Configured by hand

Applied on 2026-11-09; every source was verified in Loki (`label/host/values` and a query
per host):

| Source | Method | Status |
|---|---|---|
| fw-wan | VyOS syslog, TCP 514 → 10.5.11.101 from `lylat_service`, saved | verified (`host="fw-wan"`, strongSwan, kernel, FRR…) |
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

### fw-wan

See the fw-wan section of the [monitoring-config README](../README.md). It sends from
`lylat_service` (10.5.0.255) to `10.5.11.101`, TCP, RFC 5424. Firewall `log` rules
(kernel) and strongSwan/IPsec logs are included at `info` and up.

```
set system syslog remote 10.5.11.101 facility all level 'info'
set system syslog remote 10.5.11.101 port '514'
set system syslog remote 10.5.11.101 protocol 'tcp'
set system syslog remote 10.5.11.101 format include-timezone
set system syslog remote 10.5.11.101 format octet-counted
set system syslog remote 10.5.11.101 vrf 'lylat_service'
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

From mon01 (VLAN 13):

```sh
curl -sG http://10.13.11.101:3100/loki/api/v1/label/host/values | jq
curl -sG http://10.13.11.101:3100/loki/api/v1/query_range --data-urlencode 'query={host="m326-1"}' --data-urlencode limit=5 | jq '.data.result[].values'
curl -sG http://10.13.11.101:3100/loki/api/v1/query --data-urlencode 'query=sum by (host) (count_over_time({source="syslog"}[30m]))' | jq -r '.data.result[] | "\(.metric.host) \(.value[1])"'
```

To test a sender by hand: `logger -n 10.5.11.101 -P 514 -T --rfc5424 -t test hello` from a
Linux box, `/log info "loki test"` on a MikroTik, `send log 6 loki test` on a WLC, or
`ceph log "loki test"` for the Ceph cluster log.
