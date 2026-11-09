#!/usr/bin/env python3
"""Snapshot the parts of fw-wan's config that the fw-wan dashboards need.

    python3 -I modules/services/monitoring/dashboards/fwwan_config.py
    python3 -I modules/services/monitoring/dashboards/custom.py

vyos/nft-metrics.py on fw-wan exports per-rule counters (vyos_firewall_rule_* with
family, kind, chain and rule labels; vyos_nat_rule_* with family, type and rule),
but not what a rule does. This script reads the router's config over ssh
(vyos@10.20.10.255, read-only) and writes fwwan_snapshot.py: for every IPv4/IPv6
filter chain (input, forward, output and the named ones) its default action,
which rules jump to it, and per rule the action (with jump target), description
and a short match summary; plus the NAT rules, interface -> VRF and the VRF tables.
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
WANTED = (r"^set (firewall ipv[46] |nat(66)? (source|destination) rule |vrf name [^ ]+ (table|description) "
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


BASE_HOOKS = ("input", "forward", "output")


def parse(lines):
    chains, jumps, nat, interfaces, vrfs = {}, {}, {}, {}, {}
    for line in lines:
        w = words(line)
        if w[1] == "firewall" and w[2] in ("ipv4", "ipv6"):
            # set firewall ipv4 name <chain> ... | set firewall ipv4 <hook> filter ...
            fam = w[2]
            if w[3] == "name":
                chain, kind, rest = w[4], "named", w[5:]
            elif w[3] in BASE_HOOKS and w[4] == "filter":
                chain, kind, rest = w[3], "base", w[5:]
            else:
                continue  # prerouting raw etc.: no counters exported
            c = chains.setdefault((fam, chain), {"kind": kind, "default-action": "", "rules": {}})
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
                    jumps.setdefault((fam, val[0]), []).append(f"{chain} {rest[1]}")
                else:
                    r["conds"].append([key, *val] if val else [key])
        elif w[1] in ("nat", "nat66"):
            fam = "ipv6" if w[1] == "nat66" else "ipv4"
            r = nat.setdefault((fam, w[2], w[4]), {"description": "", "conds": []})
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
    order = {"input": 0, "forward": 1, "output": 2}
    for (fam, chain), c in sorted(chains.items(), key=lambda kv: (kv[0][0], kv[1]["kind"] != "base",
                                                                   order.get(kv[0][1], 9), kv[0][1])):
        rules = {}
        for rid in sorted(c["rules"], key=sort_key):
            r = c["rules"][rid]
            action = r["action"] + (f" {r['target']}" if r.get("target") else "")
            rules[rid] = {"action": action, "description": r["description"], "match": summary(r["conds"])}
        # Without a default-action, VyOS accepts in a base chain and drops in a named one.
        default = c["default-action"] or ("accept" if c["kind"] == "base" else "drop")
        out_chains.setdefault(fam, {})[chain] = {"kind": c["kind"], "default_action": default,
                                                 "from": sorted(jumps.get((fam, chain), [])), "rules": rules}
    out_nat = [{"family": f, "type": t, "rule": rid, "description": r["description"], "match": summary(r["conds"])}
               for (f, t, rid), r in sorted(nat.items(), key=lambda kv: (kv[0][0], kv[0][1], sort_key(kv[0][2])))]
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
        f'than editing this file. CHAINS[family][chain]: the input/forward/output filters (kind\n'
        f'base) and the named chains (VyOS names, no NAME_ prefix), as vyos/nft-metrics.py labels them.\n"""\n\nTAKEN = "{datetime.date.today()}"\n\n{body}\n')
    rules = sum(len(c["rules"]) for f in chains.values() for c in f.values())
    print(f"{OUT.name}: {sum(map(len, chains.values()))} chains, {rules} rules, {len(nat)} NAT rules, "
          f"{len(interfaces)} interfaces, {len(vrfs)} VRFs")


if __name__ == "__main__":
    main()
