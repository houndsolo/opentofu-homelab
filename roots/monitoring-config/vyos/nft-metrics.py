#!/usr/bin/env python3
# Per-rule nftables counters of the VyOS firewall (all base and named chains, IPv4
# and IPv6) and NAT, written for node_exporter's textfile collector (service
# monitoring prometheus node-exporter collectors textfile). Run every minute by
# the task scheduler (system task-scheduler task nft-metrics).
#
# Telegraf's bundled VyOS script only reports the named (NAME_*) IPv4 chains;
# this covers the input/forward/output filters, the default actions and NAT too.
# Only counters and the rule comments VyOS generates are read.
import json
import os
import re
import subprocess
import tempfile
import time

OUT_DIR = '/run/node_exporter/collector'
OUT = os.path.join(OUT_DIR, 'nft.prom')

TABLES = [('ip', 'vyos_filter', 'ipv4'), ('ip6', 'vyos_filter', 'ipv6'), ('ip', 'vyos_nat', 'ipv4'), ('ip6', 'vyos_nat', 'ipv6')]
BASE = {'VYOS_FORWARD_filter': 'forward', 'VYOS_INPUT_filter': 'input', 'VYOS_OUTPUT_filter': 'output'}
NAT = {'SRC': 'source', 'DST': 'destination'}

lines = []
meta = set()


def esc(v):
    return str(v).replace('\\', '\\\\').replace('"', '\\"')


def metric(name, help_, type_, labels, value):
    if name not in meta:
        meta.add(name)
        lines.append(f'# HELP {name} {help_}')
        lines.append(f'# TYPE {name} {type_}')
    lab = ','.join(f'{k}="{esc(v)}"' for k, v in labels.items())
    lines.append(f'{name}{{{lab}}} {value}')


def counters(rule):
    pkts = byts = 0
    found = False
    for e in rule.get('expr', []):
        c = e.get('counter') if isinstance(e, dict) else None
        if isinstance(c, dict):
            found = True
            pkts += int(c.get('packets', 0))
            byts += int(c.get('bytes', 0))
    return found, pkts, byts


ok = 1
rules = {}  # (metric, labels tuple) -> [pkts, bytes]
for family, table, fam in TABLES:
    try:
        out = subprocess.run(['nft', '-j', 'list', 'table', family, table], capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        continue  # table not present (e.g. no IPv6 firewall)
    for obj in json.loads(out).get('nftables', []):
        rule = obj.get('rule')
        if not rule:
            continue
        comment = rule.get('comment') or ''
        found, pkts, byts = counters(rule)
        if not found or not comment:
            continue
        nft_chain = rule['chain']
        if table == 'vyos_nat':
            m = re.match(r'(SRC|DST)-NAT(?:66)?-(\d+)$', comment)
            if not m:
                continue
            key = ('vyos_nat_rule', (('family', fam), ('type', NAT[m[1]]), ('rule', m[2])))
        else:
            if 'default-action' in comment:
                rid = 'default-action'
            else:
                m = re.search(r'-(\d+)$', comment)
                if not m:
                    continue
                rid = m[1]
            chain = BASE.get(nft_chain) or (nft_chain[5:] if nft_chain.startswith('NAME_') or nft_chain.startswith('NAME6') else nft_chain)
            if nft_chain.startswith('NAME6_'):
                chain = nft_chain[6:]
            kind = 'base' if nft_chain in BASE else 'named'
            key = ('vyos_firewall_rule', (('family', fam), ('kind', kind), ('chain', chain), ('rule', rid)))
        acc = rules.setdefault(key, [0, 0])
        acc[0] += pkts
        acc[1] += byts

for (prefix, labels), (pkts, byts) in sorted(rules.items()):
    lab = dict(labels)
    what = 'NAT' if prefix == 'vyos_nat_rule' else 'firewall'
    metric(f'{prefix}_packets_total', f'Packets matched by the {what} rule (resets when the ruleset is reloaded).', 'counter', lab, pkts)
    metric(f'{prefix}_bytes_total', f'Bytes matched by the {what} rule (resets when the ruleset is reloaded).', 'counter', lab, byts)

metric('vyos_nft_metrics_rules', 'Rules with counters written to this file.', 'gauge', {}, len(rules))
metric('vyos_nft_metrics_last_run_timestamp_seconds', 'Unix time this file was written.', 'gauge', {}, int(time.time()))

os.makedirs(OUT_DIR, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix='.nft.')
with os.fdopen(fd, 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.chmod(tmp, 0o644)
os.replace(tmp, OUT)
