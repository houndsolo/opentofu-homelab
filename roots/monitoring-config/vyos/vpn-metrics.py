#!/usr/bin/env python3
# IPsec (strongSwan via VICI) and WireGuard state as Prometheus metrics, written
# for node_exporter's textfile collector (service monitoring prometheus
# node-exporter collectors textfile). Run every minute by the task scheduler
# (system task-scheduler task vpn-metrics). Installed by hand from the
# opentofu-homelab monitoring work; no secrets are read or written.
import os
import subprocess
import tempfile
import time

OUT_DIR = '/run/node_exporter/collector'
OUT = os.path.join(OUT_DIR, 'vpn.prom')

lines = []
meta = {}


def esc(v):
    return str(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ')


def metric(name, help_, type_, labels, value):
    if name not in meta:
        meta[name] = True
        lines.append(f'# HELP {name} {help_}')
        lines.append(f'# TYPE {name} {type_}')
    lab = ','.join(f'{k}="{esc(v)}"' for k, v in labels.items())
    lines.append(f'{name}{{{lab}}} {value}')


def s(d, k, default=''):
    v = d.get(k, default)
    return v.decode() if isinstance(v, bytes) else v


def num(d, k):
    try:
        return int(s(d, k, '0') or 0)
    except ValueError:
        return 0


# --- IPsec -----------------------------------------------------------------
ok = 1
try:
    import vici
    sess = vici.Session()
    conns = {}
    for c in sess.list_conns():
        for name, conf in c.items():
            conns[name] = conf
    sas = {}
    for x in sess.list_sas():
        for name, ike in x.items():
            sas[name] = ike
    for name, conf in conns.items():
        remote = ','.join(a.decode() if isinstance(a, bytes) else a for a in conf.get('remote_addrs', []) or [])
        ike = sas.get(name, {})
        state = s(ike, 'state', 'DOWN') or 'DOWN'
        metric('vyos_ipsec_ike_up', 'IKE SA established (1) or not (0), per configured connection.', 'gauge',
               {'connection': name, 'remote': remote}, 1 if state == 'ESTABLISHED' else 0)
        metric('vyos_ipsec_ike_state_info', 'IKE SA state (CONNECTING, ESTABLISHED, DOWN, ...).', 'gauge',
               {'connection': name, 'state': state}, 1)
        metric('vyos_ipsec_ike_established_seconds', 'Seconds since the IKE SA was established.', 'gauge',
               {'connection': name}, num(ike, 'established'))
        children = conf.get('children', {}) or {}
        installed = {}
        for ch in (ike.get('child-sas') or {}).values():
            installed.setdefault(s(ch, 'name'), []).append(ch)
        for child in children:
            child = child.decode() if isinstance(child, bytes) else child
            chs = [c for c in installed.get(child, []) if s(c, 'state') == 'INSTALLED']
            lab = {'connection': name, 'child': child}
            metric('vyos_ipsec_child_up', 'CHILD SA installed (1) or not (0).', 'gauge', lab, 1 if chs else 0)
            metric('vyos_ipsec_child_installed_seconds', 'Seconds since the newest CHILD SA was installed.', 'gauge',
                   lab, min((num(c, 'install-time') for c in chs), default=0))
            for field, mname, h in [('bytes-in', 'vyos_ipsec_child_received_bytes', 'Bytes received on the CHILD SA (resets on rekey).'),
                                    ('bytes-out', 'vyos_ipsec_child_sent_bytes', 'Bytes sent on the CHILD SA (resets on rekey).'),
                                    ('packets-in', 'vyos_ipsec_child_received_packets', 'Packets received on the CHILD SA (resets on rekey).'),
                                    ('packets-out', 'vyos_ipsec_child_sent_packets', 'Packets sent on the CHILD SA (resets on rekey).')]:
                metric(mname, h, 'gauge', lab, sum(num(c, field) for c in chs))
except Exception as e:  # strongSwan not running or no IPsec configured
    ok = 0
metric('vyos_vpn_metrics_ipsec_ok', 'IPsec state could be read.', 'gauge', {}, ok)

# --- WireGuard ---------------------------------------------------------------
ok = 1
try:
    names = {}
    try:
        from vyos.configquery import ConfigTreeQuery
        wg = ConfigTreeQuery().get_config_dict(['interfaces', 'wireguard'], key_mangling=('-', '_'),
                                               get_first_key=True, no_tag_node_value_mangle=True)
        for ifname, ifconf in wg.items():
            for peer, pconf in (ifconf.get('peer') or {}).items():
                if 'public_key' in pconf:
                    names[(ifname, pconf['public_key'])] = peer
    except Exception:
        pass
    now = time.time()
    hs = subprocess.run(['wg', 'show', 'all', 'latest-handshakes'], capture_output=True, text=True, check=True).stdout
    tr = subprocess.run(['wg', 'show', 'all', 'transfer'], capture_output=True, text=True, check=True).stdout
    for line in hs.splitlines():
        ifname, key, ts = line.split('\t')
        lab = {'interface': ifname, 'peer': names.get((ifname, key), key[:8])}
        metric('vyos_wireguard_latest_handshake_timestamp_seconds', 'Unix time of the latest handshake (0 = never).',
               'gauge', lab, int(ts))
        metric('vyos_wireguard_peer_up', 'Handshake within the last 3 minutes.', 'gauge', lab,
               1 if int(ts) and now - int(ts) < 180 else 0)
    for line in tr.splitlines():
        ifname, key, rx, tx = line.split('\t')
        lab = {'interface': ifname, 'peer': names.get((ifname, key), key[:8])}
        metric('vyos_wireguard_received_bytes_total', 'Bytes received from the peer.', 'counter', lab, int(rx))
        metric('vyos_wireguard_sent_bytes_total', 'Bytes sent to the peer.', 'counter', lab, int(tx))
except Exception:
    ok = 0
metric('vyos_vpn_metrics_wireguard_ok', 'WireGuard state could be read.', 'gauge', {}, ok)
metric('vyos_vpn_metrics_last_run_timestamp_seconds', 'Unix time this file was written.', 'gauge', {}, int(time.time()))

os.makedirs(OUT_DIR, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix='.vpn.')
with os.fdopen(fd, 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.chmod(tmp, 0o644)
os.replace(tmp, OUT)
