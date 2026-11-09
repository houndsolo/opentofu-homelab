#!/usr/bin/env python3
"""Snapshot the parts of fw-wan's config that the fw-wan dashboards need.

    python3 -I modules/services/monitoring/dashboards/fwwan_config.py
    python3 -I modules/services/monitoring/dashboards/custom.py

Telegraf on fw-wan exports per-rule nftables counters (nftables_pkts/bytes with
chain and ruleid labels), but not what a rule does. This script reads the router's
config over ssh (vyos@10.20.10.255, read-only) and writes fwwan_snapshot.py:
for every named IPv4 firewall chain its default action, which base-chain rules
jump to it, and per rule the action, description and a short match summary;
plus the source/destination NAT rules, interface -> VRF and the VRF tables.
fwwan.py turns that into value mappings, drop/reject selectors and the rule
reference tables, so custom.py stays offline.

Re-run both commands after changing fw-wan's firewall, NAT, interfaces or VRFs,
and commit the diff. Only the paths above are read: the grep runs on the router,
so keys, secrets and the rest of the config never leave it.
"""
import datetime
import json
import pathlib
import re
import shlex
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "fwwan_snapshot.py"
ROUTER = "vyos@10.20.10.255"
WANTED = (r"^set (firewall ipv4 |nat (source|destination) rule |vrf name [^ ]+ (table|description) "
          r"|interfaces [^ ]+ [^ ]+ (vif [0-9]+ )?(vrf|description) ')")
COMMAND = ("/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands | grep -E "
           + shlex.quote(WANTED))

# How a rule's match conditions are abbreviated (longest key first).
SHORT = {
    "source address": "src", "source group address-group": "src @", "source group network-group": "src @",
    "source port": "sport", "destination address": "dst", "destination group address-group": "dst @",
    "destination group network-group": "dst @", "destination port": "dport",
    "inbound-interface name": "in", "inbound-interface group": "in @",
    "outbound-interface name": "out", "outbound-interface group": "out @",
    "icmp type-name": "icmp", "protocol": "proto", "state": "state",
    "translation address": "to", "translation port": "to port",
}


def words(line):
    return [w.strip("'") for w in shlex.split(line)]


def summary(conds):
    """[["destination", "port", "22"], ["state", "established"], ...] -> 'dport 22, state established'."""
    merged = {}
    for c in conds:
        for n in range(len(c) - 1, 0, -1):
            key = " ".join(c[:n])
            if key in SHORT:
                merged.setdefault(SHORT[key], []).append(" ".join(c[n:]))
                break
        else:
            merged.setdefault(" ".join(c[:-1]) if len(c) > 1 else c[0], []).append(c[-1] if len(c) > 1 else "")
    parts = []
    for k, vals in sorted(merged.items(), key=lambda kv: kv[0] == "log"):  # "log" last
        sep = "" if k.endswith("@") else " "
        parts.append(f"{k}{sep}{','.join(v for v in vals if v)}".strip())
    return ", ".join(parts)


def sort_key(rule_id):
    return (0, int(rule_id)) if rule_id.isdigit() else (1, rule_id)


def parse(lines):
    chains, jumps, nat, interfaces, vrfs = {}, {}, {}, {}, {}
    for line in lines:
        w = words(line)
        if w[1:3] == ["firewall", "ipv4"]:
            # set firewall ipv4 name <chain> ... | set firewall ipv4 <hook> filter ...
            if w[3] == "name":
                chain, rest = w[4], w[5:]
            else:
                chain, rest = f"{w[3]} {w[4]}", w[5:]
            c = chains.setdefault(chain, {"default-action": "", "rules": {}})
            if rest[:1] == ["default-action"]:
                c["default-action"] = rest[1]
            elif rest[:1] == ["rule"]:
                r = c["rules"].setdefault(rest[1], {"action": "", "description": "", "conds": []})
                key, val = rest[2], rest[3:]
                if key == "action":
                    r["action"] = val[0]
                elif key == "description":
                    r["description"] = val[0]
                elif key == "jump-target":
                    r["target"] = val[0]
                    jumps.setdefault(val[0], []).append(f"{chain} {rest[1]}")
                else:
                    r["conds"].append([key, *val] if val else [key])
        elif w[1] == "nat":
            r = nat.setdefault((w[2], w[4]), {"description": "", "conds": []})
            if w[5] == "description":
                r["description"] = w[6]
            else:
                r["conds"].append(w[5:])
        elif w[1] == "vrf":
            vrfs.setdefault(w[3], {"table": "", "description": ""})[w[4]] = w[5]
        elif w[1] == "interfaces":
            # set interfaces ethernet eth1 [vif 1000] vrf 'x'
            name = w[3] + (f".{w[5]}" if w[4] in ("vif", "vif-s") else "")
            interfaces.setdefault(name, {"vrf": "default", "description": ""})[w[-2]] = w[-1]

    out_chains = {}
    for chain, c in sorted(chains.items()):
        if " " in chain:  # base chains (input filter, forward filter): no per-rule counters in Telegraf
            continue
        rules = {}
        for rid in sorted(c["rules"], key=sort_key):
            r = c["rules"][rid]
            action = r["action"] + (f" {r['target']}" if r.get("target") else "")
            rules[rid] = {"action": action, "description": r["description"], "match": summary(r["conds"])}
        # VyOS drops by default in a named chain without a default-action.
        out_chains[chain] = {"default_action": c["default-action"] or "drop",
                             "from": sorted(jumps.get(chain, [])), "rules": rules}
    out_nat = [{"type": t, "rule": rid, "description": r["description"], "match": summary(r["conds"])}
               for (t, rid), r in sorted(nat.items(), key=lambda kv: (kv[0][0], sort_key(kv[0][1])))]
    return out_chains, out_nat, dict(sorted(interfaces.items())), dict(sorted(vrfs.items()))


def main():
    cmd = ["ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", ROUTER, COMMAND]
    lines = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=60).stdout.splitlines()
    chains, nat, interfaces, vrfs = parse([l for l in lines if re.match(WANTED, l)])
    # JSON of plain strings, lists and dicts is valid Python.
    body = "\n\n".join(f"{name} = {json.dumps(value, indent=2)}" for name, value in (
        ("CHAINS", chains), ("NAT", nat), ("INTERFACES", interfaces), ("VRFS", vrfs)))
    OUT.write_text(
        f'"""fw-wan config snapshot for the fw-wan dashboards (fwwan.py).\n\n'
        f"Generated by fwwan_config.py from {ROUTER} on {datetime.date.today()}; re-run it rather\n"
        f'than editing this file. Named IPv4 firewall chains only (Telegraf has no counters for the\n'
        f'base chains), with VyOS names (no NAME_ prefix).\n"""\n\nTAKEN = "{datetime.date.today()}"\n\n{body}\n')
    rules = sum(len(c["rules"]) for c in chains.values())
    print(f"{OUT.name}: {len(chains)} chains, {rules} rules, {len(nat)} NAT rules, "
          f"{len(interfaces)} interfaces, {len(vrfs)} VRFs")


if __name__ == "__main__":
    main()
