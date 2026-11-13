#!/usr/bin/env python3
# VyOS interface and service state for node_exporter's textfile collector (service
# monitoring prometheus node-exporter collectors textfile). Run every minute by the
# task scheduler (system task-scheduler task status-metrics).
#
# The same data Telegraf's VyOS exec input used to give (show_interfaces_*,
# vyos_services_*): VyOS only runs that input while the telegraf influxdb output is
# configured, and that output (bucket vyos through the InfluxDB relay) is gone. This
# runs the two scripts VyOS ships for it and converts their InfluxDB line protocol.
# Names are new (vyos_interface_*, vyos_service_status) so they never mix with the old
# Telegraf series; the values keep VyOS's meaning:
#   vyos_interface_state  0 = up, 2 = admin down (disabled in the config)
#   vyos_interface_link   0 = link up, 1 = link down
#   vyos_service_status   1 = running (a daemon VyOS expects for its config: zebra, bgpd, charon...)
# Addresses and descriptions are labels of vyos_interface_info (value 1), so a DHCP address
# change doesn't restart the state series.
import os
import re
import subprocess
import tempfile
import time

OUT_DIR = '/run/node_exporter/collector'
OUT = os.path.join(OUT_DIR, 'status.prom')
SCRIPTS = '/etc/telegraf/custom_scripts'
SOURCES = {'interfaces': 'show_interfaces_input_filter.py', 'services': 'vyos_services_input_filter.py'}

lines = []
meta = set()


def esc(v):
    return str(v).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def metric(name, help_, type_, labels, value):
    if name not in meta:
        meta.add(name)
        lines.append(f'# HELP {name} {help_}')
        lines.append(f'# TYPE {name} {type_}')
    lab = ','.join(f'{k}="{esc(v)}"' for k, v in labels.items())
    lines.append(f'{name}{{{lab}}} {value}')


def unquote(v):
    """Tag values arrive with literal quotes from vyos_services (service="zebra")."""
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    return re.sub(r'\\([ ,=])', r'\1', v)


def pairs(text):
    """k=v,k=v (tags or fields) -> dict; integer fields (12i) -> int."""
    out = {}
    for part in re.findall(r'((?:[^,"\\]|\\.|"(?:[^"\\]|\\.)*")+)', text):
        k, _, v = part.partition('=')
        v = unquote(v)
        if re.fullmatch(r'-?\d+i', v):
            v = int(v[:-1])
        out[unquote(k)] = v
    return out


def parse(line):
    """measurement,tags fields [timestamp] -> (measurement, tags, fields)."""
    # Split on the first two unquoted, unescaped spaces.
    parts, cur, quoted, i = [], '', False, 0
    while i < len(line):
        c = line[i]
        if c == '\\' and i + 1 < len(line):
            cur += line[i:i + 2]
            i += 2
            continue
        if c == '"':
            quoted = not quoted
        if c == ' ' and not quoted and len(parts) < 2:
            parts.append(cur)
            cur = ''
        else:
            cur += c
        i += 1
    parts.append(cur)
    head, fields = parts[0], parts[1] if len(parts) > 1 else ''
    measurement, _, tags = head.partition(',')
    return measurement, pairs(tags) if tags else {}, pairs(fields)


ok = {}
for source, script in SOURCES.items():
    try:
        out = subprocess.run([os.path.join(SCRIPTS, script)], capture_output=True, text=True, timeout=20,
                             check=True).stdout
        ok[source] = 1
    except (subprocess.SubprocessError, OSError):
        ok[source] = 0
        continue
    for raw in out.splitlines():
        if not raw.strip():
            continue
        measurement, tags, fields = parse(raw.strip())
        if measurement == 'show_interfaces' and 'interface' in tags:
            iface = {'interface': tags['interface']}
            metric('vyos_interface_info', 'Interface addresses and description from VyOS (value always 1).', 'gauge',
                   {**iface, 'ip_addresses': fields.get('ip_addresses', ''),
                    'description': fields.get('description', '')}, 1)
            if isinstance(fields.get('state'), int):
                metric('vyos_interface_state', 'VyOS interface admin state: 0 up, 2 admin down.', 'gauge', iface,
                       fields['state'])
            if isinstance(fields.get('link'), int):
                metric('vyos_interface_link', 'VyOS interface link: 0 up, 1 down.', 'gauge', iface, fields['link'])
        elif measurement == 'vyos_services' and 'service' in tags and isinstance(fields.get('status'), int):
            metric('vyos_service_status', 'Daemon VyOS expects for its config is running (1) or not (0).', 'gauge',
                   {'service': tags['service']}, fields['status'])

for source, value in ok.items():
    metric('vyos_status_metrics_source_ok', 'VyOS script for this source ran successfully (1) or failed (0).', 'gauge',
           {'source': source}, value)
metric('vyos_status_metrics_last_run_timestamp_seconds', 'Unix time this file was written.', 'gauge', {},
       int(time.time()))

os.makedirs(OUT_DIR, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix='.status.')
with os.fdopen(fd, 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.chmod(tmp, 0o644)
os.replace(tmp, OUT)
