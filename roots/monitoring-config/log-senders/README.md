# Log senders

Everything that ships logs to Loki does it as syslog to Alloy on log01–log03, through the
keepalived VIPs. Nothing uses Loki's push API directly. Alloy listens on:

| Listener | Format | Who sends there |
|---|---|---|
| TCP 514 | RFC 5424, octet-counted | VyOS (leaves, dhcp01/02, fw-wan), rsyslog (PVE nodes, dns01/02) |
| UDP 514 | RFC 3164 | MikroTik (spines, CRS317), FS S3700 (switch-1) |
| UDP 1514 | raw (no parsing; host from the source IP) | Cisco C9800 WLCs, FS S3910 (switch-2) |

The 1514 listener exists because Alloy's RFC 3164 parser drops IOS-XE's
`<189>45: host: *Nov  9 …` lines and the S3910's `<189>FS 2026-11-10 …` lines. Both
formats were replayed through Alloy v1.16 to confirm this. Devices whose hostname is
missing or generic (switch-1 says `Switch`, switch-2 says `FS`, IOS-XE sends no hostname
by default) get their `host` label from a source-IP map in the Alloy config.

VIPs: `10.5.11.40` (`logs.lylat.space`, monitoring network / VLAN 5) and `10.20.11.40`
(management network).

## Managed by OpenTofu (plan only here; see each root)

| Source | Where | What |
|---|---|---|
| VyOS leaves | fabric-leaves, `fabric.settings.leaf_syslog` | `system syslog remote 10.20.11.40`, TCP, `vrf mgmt` |
| m326-1/2 (spines) | fabric-spines, `fabric.settings.spine_syslog` | `remote` logging action → 10.5.11.40 UDP 514, topics info/warning/error/critical |
| dhcp01/02 | services-config, `dhcp_syslog` | same as the leaves |
| dns01/02 | services-config, `dns_syslog` | rsyslog forwarder for the journal (BIND included) → 10.20.11.40 TCP |

## Configured by hand

### PVE nodes (fichina … venom, greatfox)

rsyslog forwards the journal over TCP to `10.5.11.40` from the node's 10.5.1.x address.
On the Ceph mon nodes it also tails the Ceph cluster log (`/var/log/ceph/ceph.log`),
which isn't in the journal (`mon_cluster_log_to_journald=false`). Every mon writes the same
cluster log, so each line arrives once per mon (`app="ceph-cluster"`; filter on one
`host`). The files in this folder:

- [`pve-50-loki.conf`](pve-50-loki.conf) → `/etc/rsyslog.d/50-loki.conf`: forward
  `*.info` and `stop`, so nothing gets written to `/var/log` and the journal stays the
  local store. It has a disk-assisted queue (128 MB) for when the receiver is down.
- [`pve-40-ceph-cluster-log.conf`](pve-40-ceph-cluster-log.conf) →
  `/etc/rsyslog.d/40-ceph-cluster-log.conf`: imfile on `ceph.log`. Installed only where
  that file exists.
- [`pve-install.sh`](pve-install.sh): installs the files, then the `rsyslog` package,
  then runs `rsyslogd -N1` and restarts rsyslog.

```sh
cd roots/monitoring-config/log-senders
for ip in 10.20.7.11 10.20.7.12 10.20.7.13 10.20.7.14 10.20.7.15 10.20.7.16 10.20.7.17 10.20.7.20; do
  scp pve-50-loki.conf pve-40-ceph-cluster-log.conf pve-install.sh root@$ip:/root/ &&
  ssh -n root@$ip bash /root/pve-install.sh
done
```

### fw-wan

See the fw-wan section of the [monitoring-config README](../README.md). It sends from
`lylat_service` (10.5.0.255) to `10.5.11.40`, TCP, RFC 5424. Firewall `log` rules
(kernel) and strongSwan/IPsec logs are included at `info` and up.

```
set system syslog remote 10.5.11.40 facility all level 'info'
set system syslog remote 10.5.11.40 port '514'
set system syslog remote 10.5.11.40 protocol 'tcp'
set system syslog remote 10.5.11.40 format include-timezone
set system syslog remote 10.5.11.40 format octet-counted
set system syslog remote 10.5.11.40 vrf 'lylat_service'
set system syslog remote 10.5.11.40 source-address '10.5.0.255'
```

### m317-1/2 (MikroTik CRS317, 10.20.0.3/.4)

Same settings as the spines (which OpenTofu manages). The source address is chosen by
the route, so it's the switch's VLAN 5 address (10.5.0.3/.4).

```
/system logging action set [find name=remote] remote=10.5.11.40 remote-port=514 remote-protocol=udp remote-log-format=syslog syslog-time-format=bsd-syslog syslog-facility=daemon
/system logging add topics=info action=remote
/system logging add topics=warning action=remote
/system logging add topics=error action=remote
/system logging add topics=critical action=remote
```

RouterOS saves configuration changes immediately.

### switch-1 (FS S3700, 10.20.0.1)

The CLI uses `config`, not `configure terminal`. The default format is RFC 3164 and the
default port is UDP 514.

```
enable
config
logging 10.5.11.40 informational
logging source-interface Vlan 5
exit
write
```

The switch's clock says 2000 (no NTP), so Alloy stamps these lines with the receive
time.

### switch-2 (FS S3910, 10.20.0.2)

FSOS, which lands in `FS#`. Messages go to the raw listener on UDP 1514.

```
configure terminal
logging server 10.5.11.40 udp-port 1514
logging source interface VLAN 5
logging trap informational
end
write
```

### c9800-wlc-1/2 (Cisco C9800-CL, 10.20.1.1/.2)

IOS-XE sends from Vlan5 (10.5.1.1/.2). Messages go to the raw listener on UDP 1514.

```
configure terminal
logging host 10.5.11.40 transport udp port 1514
logging source-interface Vlan5
logging trap informational
logging origin-id hostname
end
write memory
```

## Checking

From mon01 (VLAN 13):

```sh
curl -sG http://10.13.11.40:3100/loki/api/v1/label/host/values | jq
curl -sG http://10.13.11.40:3100/loki/api/v1/query_range --data-urlencode 'query={host="m326-1"}' --data-urlencode limit=5 | jq '.data.result[].values'
```

To test a sender by hand: `logger -n 10.5.11.40 -P 514 -T --rfc5424 -t test hello` from a
Linux box, or `/log info "loki test"` on a MikroTik.
