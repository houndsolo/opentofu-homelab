"""The fw-wan dashboards (folder Edge): overview, firewall, VPNs, VRFs & routing.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with
its helpers; see custom.py for the conventions. fw-wan is the VyOS edge router, set
up by hand (roots/monitoring-config/README.md, "fw-wan"). Its data:

- Prometheus job vyos-node (node_exporter, plus the textfile metrics of
  vpn-metrics.py, vyos_ipsec_* and vyos_wireguard_*, nft-metrics.py, per-rule
  firewall and NAT counters vyos_firewall_rule_* / vyos_nat_rule_*, and
  status-metrics.py, VyOS's interface and service state vyos_interface_* /
  vyos_service_status), vyos-frr (frr_exporter), vyos-telegraf (Telegraf's
  prometheus-client: systemd units and system counters) and blackbox-icmp;
- Loki: the router's syslog (Alloy on the logging VIP), which carries the
  firewall's log lines.
Until 2026-11-13 the interface/service state came from Telegraf (show_interfaces_*,
vyos_services_status) and the logs from a Telegraf copy in InfluxDB (bucket vyos);
both went with the influxdb output.

What a firewall rule does isn't in the metrics: fwwan_snapshot.py (written by
fwwan_config.py from the router's config) maps family/chain/rule to action, jump target and match.
The VRFs & routing dashboard has a router picker (default fw-wan) and works for
the leaves too; everything else is fw-wan only.
"""
from custom import (
    BFD_MAP, BGP_MAP, BLUE, FRR_DASH, GREEN, MERGE, NODE_DASH, OK_MAP, ORANGE_IF_ANY,
    RED_IF_ANY, UP_MAP, UP_STEPS, Board, bfd_summary, bgp_summary, bargauge, cell, dashboard,
    fixed_color, gauge, mapping, organize, override, q, query_var, stat, state_timeline, steps,
    table, text, timeseries,
)
from logs import log_table, lq, on_loki
from theme import ACCENT, ACCENT2, INFO
import fwwan_snapshot as snap

FW = 'host="fw-wan"'
UIDS = {"overview": "fw-wan-overview", "firewall": "fw-wan-firewall", "vpn": "fw-wan-vpn",
        "routing": "fw-wan-routing"}
FW_LINK = {"type": "dashboards", "tags": ["fw-wan"], "asDropdown": True, "title": "fw-wan dashboards",
           "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
           "tooltip": "", "url": ""}
NODE_FULL = NODE_DASH + "?var-job=vyos-node&var-node=10.20.10.255:9100&${__url_time_range}"
IN, OUT = ACCENT2, ACCENT  # directions, not states (like custom.READ/WRITE)
ACTION_COLORS = {"accept": "green", "drop": "red", "reject": "orange", "return": "blue", "jump": "purple",
                 "unknown": "yellow"}
ACTION_MAP = mapping(**{a: ("not in snapshot" if a == "unknown" else a, c) for a, c in ACTION_COLORS.items()})
# Telegraf systemd_units active_code.
UNIT_MAP = mapping(**{"0": ("active", "green"), "1": ("reloading", "blue"), "2": ("inactive", "text"),
                      "3": ("failed", "red"), "4": ("activating", "orange"), "5": ("deactivating", "orange")})
# vyos_interface_link (0 up, 1 down) + vyos_interface_state (0 up, 2 admin down), status-metrics.py.
LINK_MAP = mapping(**{"0": ("up", "green"), "1": ("down", "red"), "2": ("admin down", "blue"),
                      "3": ("admin down", "blue")})
LINK_STEPS = steps(("green", None), ("red", 1), ("blue", 2))
NOT_VRF_DEV = 'device!~"lo|pim6reg.*|dum.*"'


def url_link(title, url, icon="dashboard"):
    return {"type": "link", "title": title, "url": url, "icon": icon, "includeVars": False, "keepTime": True,
            "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}


NODE_FULL_LINK = url_link("Node Exporter Full (fw-wan)", NODE_DASH + "?var-job=vyos-node&var-node=10.20.10.255:9100")
# On the VRFs & routing dashboard: the picked router's node_exporter (hidden variable "node").
NODE_HOST_LINK = url_link("Node Exporter Full (${host})", NODE_DASH + "?var-job=vyos-node&var-node=${node}")
FRR_LINK = url_link("FRR / EVPN fabric", FRR_DASH)
NO_BGP = "No BGP sessions on this router"


def go(title, key):
    return (title, f"/d/{UIDS[key]}/{UIDS[key]}?${{__url_time_range}}")


def value_text(p):
    """Bar gauge values in the text color (the bars keep their colors; dark ones are hard to read as text)."""
    p["options"]["valueMode"] = "text"
    return p


def described(p, desc):
    p["description"] = desc
    return p


def inout(title, rx, tx, legend_rx, legend_tx, *, unit="bps", **kw):
    """Received above the axis, sent mirrored below it."""
    kw.setdefault("calcs", ("mean", "max", "lastNotNull"))
    overrides = kw.pop("overrides", [])
    return timeseries(title, [q(rx, legend_rx), q(tx, legend_tx)], unit=unit, overrides=[
        override("(.* )?(out|tx)$", {"custom.transform": "negative-Y"}, regex=True), *overrides], **kw)


# --- firewall rules from the snapshot ---------------------------------------------
#
# Counters come from vyos/nft-metrics.py (job vyos-node): vyos_firewall_rule_{packets,bytes}_total
# {family, kind=base|named, chain, rule} and vyos_nat_rule_{packets,bytes}_total {family, type, rule}.
# They're real counters written every minute (reset when the ruleset is reloaded). Every packet ends in
# exactly one accept, drop or reject (a rule or a default action), so summing those over all chains
# gives the final verdicts; jump and return only pass it on.

FWR = "vyos_firewall_rule_{}_total"
NATR = "vyos_nat_rule_{}_total"
BASE_CHAINS = ("input", "forward", "output")
FINAL = ("accept", "drop", "reject")
DEFAULT = {"rule": "default-action"}
BASE_DEFAULT = {"kind": "base", "rule": "default-action"}
VERDICT_COLORS = {"accept": "green", "drop": "red", "reject": "orange", "default accept": "dark-green",
                  "default drop": "dark-red", "default reject": "dark-orange", "return": "blue",
                  "default return": "dark-blue"}


def _rules():
    """{"family/chain/rule": (verb, jump target, match text)} for every rule and default action."""
    out = {}
    for fam, chains in snap.CHAINS.items():
        for chain, c in chains.items():
            for rid, r in c["rules"].items():
                verb, _, target = r["action"].partition(" ")
                text_ = r["match"] or "any"
                if r["description"]:
                    text_ += f" ({r['description']})"
                out[f"{fam}/{chain}/{rid}"] = (verb, target, text_)
            out[f"{fam}/{chain}/default-action"] = (c["default_action"], "", "default action")
        for chain in BASE_CHAINS:  # unconfigured base chains still have a default action (accept)
            out.setdefault(f"{fam}/{chain}/default-action", ("accept", "", "default action (not configured)"))
    for key in out:
        assert all(ch.isalnum() or ch in "_-/" for ch in key), key  # used unescaped in regexes below
    return out


RULES = _rules()
MATCH_MAP = [{"type": "value", "options": {k: {"text": t, "index": i} for i, (k, (_, _, t)) in enumerate(RULES.items())}}]
NAT_MAP = [{"type": "value", "options": {
    f"{r['family']}/{r['type']}/{r['rule']}": {"text": r["match"] + (f" ({r['description']})" if r["description"] else ""),
                                               "index": i} for i, r in enumerate(snap.NAT)}}]


def _relabel(e, label, groups):
    for value, keys in sorted(groups.items()):
        e = f'label_replace({e}, "{label}", "{value}", "key", "{"|".join(keys)}")'
    return e


def keyed(expr):
    """Adds key = family/chain/rule, the rule's action ("unknown" for rules added since the snapshot),
    target (jump target) and verdict (action, "default <action>" for default actions, "→ <target>"
    for jumps)."""
    e = f'label_join({expr}, "key", "/", "family", "chain", "rule")'
    e = f'label_replace({e}, "action", "unknown", "key", ".*")'
    verbs, targets = {}, {}
    for key, (verb, target, _) in RULES.items():
        verbs.setdefault(verb, []).append(key)
        if target:
            targets.setdefault(target, []).append(key)
    e = _relabel(e, "action", verbs)
    e = _relabel(e, "target", targets)
    e = f'label_replace({e}, "verdict", "$1", "action", "(.*)")'
    e = f'label_join({e}, "ra", ":", "rule", "action")'
    e = f'label_replace({e}, "verdict", "default $1", "ra", "default-action:(.*)")'
    return f'label_replace({e}, "verdict", "→ $1", "target", "(.+)")'


def only(expr, label, *values):
    """Keeps the series of expr whose label is one of values."""
    rhs = " or ".join(f'label_replace(vector(1), "{label}", "{v}", "__name__", ".*")' for v in values)
    return f"({expr}) and on ({label}) ({rhs})"


def fw(fn="rate", what="packets", window="$__rate_interval", **match):
    """keyed(fn(counter[window])) for the firewall rule counters (fn=None: the counter itself).
    match={label: value or tuple of values} filters on the normalized labels (family, kind, chain, rule)."""
    # nft-metrics.py names base chains input/forward/output and named chains without NAME_; nft
    # chain names (VYOS_*) only appear in series from its first runs (before eb180b3), which labelled
    # the IPv6 base filters and raw chains that way. Leave them out.
    sel = f'{FWR.format(what)}{{{FW}, chain!~"VYOS_.*"}}'
    e = f"{fn}({sel}[{window}])" if fn else sel
    for label, values in match.items():
        e = only(e, label, *((values,) if isinstance(values, str) else values))
    return keyed(e)


def deny_rate(by="", window="$__rate_interval"):
    agg = f"sum by ({by})" if by else "sum"
    return f"{agg} ({only(fw(window=window), 'action', 'drop', 'reject')})"


def nat(fn="rate", what="packets", window="$__rate_interval"):
    sel = f"{NATR.format(what)}{{{FW}}}"
    e = f"{fn}({sel}[{window}])" if fn else sel
    return f'label_join({e}, "key", "/", "family", "type", "rule")'


def rule_reference():
    lines = [f"Snapshot of fw-wan's filter chains taken {snap.TAKEN} by `fwwan_config.py`.", "",
             "| Family | Chain | Entered from | Rule | Action | Match |", "| --- | --- | --- | --- | --- | --- |"]
    for fam, chains in snap.CHAINS.items():
        for chain, c in chains.items():
            src = ", ".join(c["from"]) or ("hook" if c["kind"] == "base" else "(nothing)")
            for rid, r in c["rules"].items():
                desc = f" ({r['description']})" if r["description"] else ""
                lines.append(f"| {fam} | {chain} | {src} | {rid} | {r['action']} | {r['match'] or 'any'}{desc} |")
                src = ""
            lines.append(f"| {fam} | {chain} | {src} | default | **{c['default_action']}** | |")
    lines += ["", "**NAT** (counters see the first packet of each connection)", "",
              "| Family | Type | Rule | Match / translation |", "| --- | --- | --- | --- |"]
    for r in snap.NAT:
        desc = f" ({r['description']})" if r["description"] else ""
        lines.append(f"| {r['family']} | {r['type']} | {r['rule']} | {r['match']}{desc} |")
    return text("Rule reference", "\n".join(lines))


# Interface -> VRF from the snapshot, applied only to fw-wan's series (other hosts get vrf="n/a":
# nothing exports their interfaces' VRF membership).
def with_vrf(expr):
    e = f'label_replace(label_join({expr}, "hd", ":", "host", "device"), "vrf", "default", "hd", "fw-wan:.*")'
    by_vrf = {}
    for dev, i in snap.INTERFACES.items():
        by_vrf.setdefault(i["vrf"], []).append(dev.replace(".", "\\\\."))
    for vrf, devs in sorted(by_vrf.items()):
        if vrf != "default":
            e = f'label_replace({e}, "vrf", "{vrf}", "hd", "fw-wan:({"|".join(devs)})")'
    return f'label_replace({e}, "vrf", "n/a", "vrf", "")'


def in_vrf(expr, vrf):
    """Keeps the series of expr (with a vrf label, see with_vrf) whose vrf matches the regex vrf ("$vrf")."""
    return only(f'label_replace({expr}, "vrf_match", "1", "vrf", "{vrf}")', "vrf_match", "1")


def vrf_devices(h):
    """The VRF master devices (named after the VRFs frr_exporter reports routes for)."""
    return f'label_replace(group by (host, vrf) (frr_route_total{{{h}}}), "device", "$1", "vrf", "(.+)")'


def ports(h):
    """Selector for interfaces without loopback, PIM register and dummy devices (see phys)."""
    return f'{{{h}, {NOT_VRF_DEV}}}'


def phys(expr, h):
    """Drops the VRF master devices from a per-device expression."""
    return f"({expr}) unless on (host, device) {vrf_devices(h)}"


def port_rate(h, window):
    """Bytes/s in + out per interface."""
    sel = ports(h)
    return phys(f"rate(node_network_receive_bytes_total{sel}[{window}]) + rate(node_network_transmit_bytes_total{sel}[{window}])", h)


# --- Logs (Loki) ---------------------------------------------------------------------
#
# fw-wan's syslog reaches Loki through Alloy on the logging VIP (set system syslog remote 10.5.11.101):
# labels host="fw-wan", app (the syslog tag: kernel, charon-systemd, ...) and level (informational,
# notice, warning, ...). The firewall's log lines are kernel lines starting with VyOS's prefix
# [ipv4-<HOOK>-<chain>-<rule>-<A|D|R>]. Until 2026-11-13 these panels read a second copy from
# Telegraf (InfluxDB bucket vyos), which carried notice and above only; the router log panels keep
# that floor (informational lines are mostly charon's packet chatter).

FWLOG_SEL = '{host="fw-wan", app="kernel"} |~ `\\[ipv[46]-[A-Z]+-[^\\]]+-[A-Z]\\]`'
FWLOG_PREFIX = r"| regexp `\[ipv[46]-[A-Z]+-(?P<chain>.+)-(?P<rule>[^-]+)-(?P<act>[A-Z])\]`"
FWLOG = (FWLOG_SEL + " " + FWLOG_PREFIX +
         " | label_format action=`{{ if eq .act \"A\" }}accept{{ else if eq .act \"D\" }}drop"
         "{{ else if eq .act \"R\" }}reject{{ else }}{{ .act }}{{ end }}`"
         # One regexp per field: a line without that field (ICMP has no ports) just leaves it empty.
         + "".join(f" | regexp `{k}=(?P<{k.lower()}>\\S*)`" for k in ("IN", "OUT", "PROTO", "SRC", "SPT", "DST", "DPT")))
FWLOG_COUNT = f"sum(count_over_time({FWLOG_SEL} [$__range])) or vector(0)"
FWLOG_RATE = (f"sum by (rule) (count_over_time({FWLOG_SEL} {FWLOG_PREFIX} | label_format rule=`{{{{ .chain }}}} #{{{{ .rule }}}}` "
              "[$__auto]))")
NOTICE_UP = 'level!~"informational|debug"'

LEVEL_MAP = mapping(**{"emerg": ("emerg", "red"), "alert": ("alert", "red"), "crit": ("crit", "red"),
                       "err": ("err", "red"), "error": ("error", "red"), "warning": ("warning", "orange"),
                       "notice": ("notice", "blue"), "informational": ("info", "text"), "debug": ("debug", "text")})


def router_log(title, expr, desc, max_lines=300):
    """Log lines as Time / Severity / App / Message, newest first."""
    return log_table(title, expr, ["level", "app"], desc=desc, max_lines=max_lines, no_value="No log lines in range",
                     rename={"level": "Severity", "app": "App"}, widths={"Severity": 90, "App": 150},
                     overrides=[cell("Severity", "color-text"), override("Severity", {"mappings": LEVEL_MAP})])


# --- shared panels -----------------------------------------------------------------

def bgp_table(sel, no_value=None):
    lbl = "max without (instance, job, role, host)"
    return table("BGP peers", [
        q(f"{lbl} (frr_bgp_peer_state{{{sel}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_uptime_seconds{{{sel}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_prefixes_received_count_total{{{sel}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_prefixes_advertised_count_total{{{sel}}})", table=True),
        q(f"{lbl} (rate(frr_bgp_peer_message_received_total{{{sel}}}[5m]) + rate(frr_bgp_peer_message_sent_total{{{sel}}}[5m]))",
          table=True),
        q(f"{lbl} (resets(frr_bgp_peer_uptime_seconds{{{sel}}}[$__range]))", table=True),
    ], desc="One row per session (VRF, address family, peer). Interface peers (eth1.1000/eth2.1000 on fw-wan) are BGP "
            "unnumbered; the hostname comes from the peer's BGP hostname capability.", no_value=no_value,
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "vrf": "VRF", "afi": "AFI", "safi": "SAFI", "peer": "Peer", "peer_hostname": "Hostname",
            "peer_desc": "Description", "peer_type": "Type", "peer_as": "Peer AS", "local_as": "Local AS",
            "Value #A": "State", "Value #B": "Uptime", "Value #C": "Prefixes rx", "Value #D": "Prefixes tx",
            "Value #E": "Msgs/s", "Value #F": "Flaps in range"},
            order=["VRF", "AFI", "SAFI", "Peer", "Hostname", "Description", "Type", "Peer AS", "Local AS", "State",
                   "Uptime", "Prefixes rx", "Prefixes tx", "Msgs/s", "Flaps in range"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": BGP_MAP}),
                   override("Uptime", {"unit": "dtdurations"}), override("Msgs/s", {"decimals": 2}),
                   override("Flaps in range", {"thresholds": ORANGE_IF_ANY, "custom.cellOptions": {"type": "color-text"}}),
                   override("Prefixes rx", {"custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"},
                                            "color": {"mode": "fixed", "fixedColor": IN}}),
                   override("Prefixes tx", {"custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"},
                                            "color": {"mode": "fixed", "fixedColor": OUT}})],
        sort="VRF")


def bgp_state(sel, no_value=None):
    return state_timeline("BGP session state", [
        q(f"max without (instance, job, role, local_as, peer_as, peer_hostname, peer_desc, peer_type) "
          f"(frr_bgp_peer_state{{{sel}}})", "{{vrf}} · {{peer}} {{afi}}"),
    ], mappings=BGP_MAP, thresholds=steps(("red", None), ("green", 1), ("orange", 2)), no_value=no_value,
        desc="Gaps mean frr_exporter wasn't scraped.")


def interface_table(h, desc, vrf=None):
    """vrf: keep only the interfaces in VRFs matching this regex (e.g. "$vrf")."""
    sel = ports(h)

    def col(expr, by="host, device"):
        e = phys(expr, h)
        if vrf:
            e = in_vrf(with_vrf(e), vrf)
        elif "vrf" in by:
            e = with_vrf(e)
        return q(f"max by ({by}) ({e})", table=True)

    return table("Interfaces", [
        col(f"node_network_up{sel}", "host, device, vrf"),
        col(f"node_network_info{sel}", "host, device, ifalias, operstate"),
        col(f"node_network_mtu_bytes{sel}"),
        col(f"node_network_speed_bytes{sel} * 8 > 0"),
        col(f"rate(node_network_receive_bytes_total{sel}[5m]) * 8"),
        col(f"rate(node_network_transmit_bytes_total{sel}[5m]) * 8"),
        col(f"rate(node_network_receive_errs_total{sel}[5m]) + rate(node_network_transmit_errs_total{sel}[5m])"),
        col(f"rate(node_network_receive_drop_total{sel}[5m]) + rate(node_network_transmit_drop_total{sel}[5m])"),
    ], desc=desc, transformations=[MERGE, organize(exclude=["Time", "host", "Value #A", "Value #B"], rename={
        "vrf": "VRF", "device": "Interface", "ifalias": "Description", "operstate": "Oper state", "Value #C": "MTU",
        "Value #D": "Speed", "Value #E": "In", "Value #F": "Out", "Value #G": "Errors/s", "Value #H": "Drops/s"},
        order=["VRF", "Interface", "Description", "Oper state", "MTU", "Speed", "In", "Out", "Errors/s", "Drops/s"])],
        overrides=[override("Speed", {"unit": "bps"}),
                   override("In", {"unit": "bps", "color": {"mode": "fixed", "fixedColor": IN},
                                   "custom.cellOptions": {"type": "gauge", "mode": "lcd", "valueDisplayMode": "text"}}),
                   override("Out", {"unit": "bps", "color": {"mode": "fixed", "fixedColor": OUT},
                                    "custom.cellOptions": {"type": "gauge", "mode": "lcd", "valueDisplayMode": "text"}}),
                   override("Errors/s|Drops/s", {"decimals": 2, "thresholds": steps(("green", None), ("red", 0.01)),
                                                 "custom.cellOptions": {"type": "color-text"}}, regex=True),
                   override("Oper state", {"mappings": mapping(**{"up": ("up", "green"), "down": ("down", "red"),
                                                                  "unknown": ("unknown", "text")}),
                                           "custom.cellOptions": {"type": "color-text"}})],
        sort="VRF")


# --- tiles on the lylat.space overview -------------------------------------------------

def overview_row(b):
    """A row of fw-wan tiles for custom.overview(), each linking to the fw-wan overview."""
    link = [go("fw-wan overview", "overview")]
    b.add(stat("fw-wan", [
        q(f'min(up{{{FW}}}) * min(probe_success{{{FW}}})')], mappings=UP_MAP, thresholds=UP_STEPS, links=link,
        desc="UP when the ICMP probe and all three exporters (node, FRR, Telegraf) answer."), 3, 5)
    b.add(stat("WAN", [
        q(f'rate(node_network_receive_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8', "in"),
        q(f'rate(node_network_transmit_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8', "out"),
    ], unit="bps", text_mode="value_and_name", color_mode="value", graph=True, links=link,
        overrides=[fixed_color("in", IN), fixed_color("out", OUT)], desc="fw-wan eth5 (Spectrum)."), 6, 5)
    b.add(stat("VPN tunnels", [
        q(f"vyos_ipsec_ike_up{{{FW}}}", "{{connection}}"), q(f"vyos_wireguard_peer_up{{{FW}}}", "wg {{peer}}"),
    ], text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal",
        links=[go("fw-wan VPNs", "vpn")], desc="IPsec IKE SAs and WireGuard peers on fw-wan."), 6, 5)
    b.add(stat("Firewall drops + rejects", [q(deny_rate() + " or vector(0)")], unit="pps", decimals=2,
               thresholds=steps(("green", None), ("orange", 1), ("red", 50)), graph=True, color_mode="value",
               links=[go("fw-wan firewall", "firewall")], desc="Dropped or rejected by any fw-wan filter chain."), 5, 5)
    b.add(gauge("fw-wan conntrack", [q(f"node_nf_conntrack_entries{{{FW}}} / node_nf_conntrack_entries_limit{{{FW}}}")],
                unit="percentunit", min_=0, max_=1, decimals=2,
                thresholds=steps(("green", None), ("orange", 0.75), ("red", 0.9)), links=link), 4, 5)


# --- fw-wan overview -----------------------------------------------------------------

def overview():
    b = Board()
    b.row("Status")
    b.grid(6, 4, [
        stat("Reachable (ICMP)", [q(f'probe_success{{job="blackbox-icmp", {FW}}}')], mappings=UP_MAP,
             thresholds=UP_STEPS, desc="Blackbox ICMP probe from mon01 to fw-wan's mgmt address."),
        stat("Uptime", [q(f"time() - node_boot_time_seconds{{{FW}}}")], unit="dtdurations", color_mode="value",
             thresholds=steps(("orange", None), ("green", 3600)), desc="Orange in the first hour after a reboot."),
        stat("Exporters", [q(f'label_replace(up{{{FW}, job=~"vyos-.*"}}, "job", "$1", "job", "vyos-(.*)")', "{{job}}")],
             text_mode="name", mappings=UP_MAP, thresholds=UP_STEPS,
             desc="node_exporter (vyos-node), frr_exporter (vyos-frr) and Telegraf (vyos-telegraf) on fw-wan."),
        stat("WAN address", [q(f'max by (ip_addresses) (vyos_interface_info{{{FW}, interface="eth5"}})', "{{ip_addresses}}",
                               instant=True)],
             text_mode="name", color_mode="value", thresholds=BLUE,
             desc="eth5 (DHCP from Spectrum), from VyOS (status-metrics.py)."),
    ], per_row=2)
    spark = dict(graph=True, color_mode="value", text_mode="value_and_name")
    b.add(stat("WAN in", [q(f'rate(node_network_receive_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8', "eth5")],
               unit="bps", thresholds=steps((IN, None)), desc="eth5 received.", **spark), 4, 8)
    b.add(stat("WAN out", [q(f'rate(node_network_transmit_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8', "eth5")],
               unit="bps", thresholds=steps((OUT, None)), desc="eth5 sent.", **spark), 4, 8)
    b.col(4,
          (gauge("CPU", [q(f'1 - avg(rate(node_cpu_seconds_total{{{FW}, mode="idle"}}[$__rate_interval]))')],
                 unit="percentunit", min_=0, max_=1, thresholds=steps(("green", None), ("orange", 0.75), ("red", 0.9)),
                 links=[("Node Exporter Full", NODE_FULL)]), 4),
          (gauge("Memory", [q(f"1 - node_memory_MemAvailable_bytes{{{FW}}} / node_memory_MemTotal_bytes{{{FW}}}")],
                 unit="percentunit", min_=0, max_=1, thresholds=steps(("green", None), ("orange", 0.75), ("red", 0.9)),
                 links=[("Node Exporter Full", NODE_FULL)]), 4))
    b.col(6,
          (gauge("Conntrack table", [q(f"node_nf_conntrack_entries{{{FW}}} / node_nf_conntrack_entries_limit{{{FW}}}")],
                 unit="percentunit", min_=0, max_=1, decimals=2, thresholds=steps(("green", None), ("orange", 0.75), ("red", 0.9)),
                 desc="Tracked connections / nf_conntrack_max. New flows are dropped when it's full.",
                 links=[go("fw-wan firewall", "firewall")]), 4),
          (stat("Conntrack entries", [q(f"node_nf_conntrack_entries{{{FW}}}", "entries")], decimals=0, thresholds=BLUE,
                links=[go("fw-wan firewall", "firewall")], **spark), 4))

    b.add(described(bgp_summary(f"{{{FW}}}"),
                    "IPv4 unicast BGP sessions from frr_exporter: BORDER-LEAF-18/19 (VRF lylat_service, BGP unnumbered "
                    "over eth1.1000/eth2.1000) and the haystack peer (VRF vpn_hay). If the exporter is down, all three "
                    "show 0; check the Exporters stat."), 5, 5)
    b.add(stat("VPN tunnels", [
        q(f"vyos_ipsec_ike_up{{{FW}}}", "{{connection}}"),
        q(f"vyos_wireguard_peer_up{{{FW}}}", "wg {{peer}}"),
    ], text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal",
        desc="IPsec IKE SAs established and WireGuard peers with a handshake in the last 3 minutes (vpn-metrics.py).",
        links=[go("fw-wan VPNs", "vpn")]), 5, 5)
    b.add(stat("VyOS services", [
        q(f"max by (service) (vyos_service_status{{{FW}}})", "{{service}}", instant=True),
    ], text_mode="name", mappings=UP_MAP, thresholds=UP_STEPS,
        desc="Daemons VyOS expects for its config (zebra, staticd, bgpd, charon...), from status-metrics.py."), 6, 5)
    b.add(stat("Units failed / restarting", [
        q(f'count(systemd_units_active_code{{{FW}, load="loaded"}} == 3) or vector(0)', "failed"),
        q(f'count(systemd_units_active_code{{{FW}, load="loaded"}} >= 4) or vector(0)', "(re)starting"),
    ], text_mode="value_and_name", thresholds=ORANGE_IF_ANY,
        overrides=[override("failed", {"thresholds": RED_IF_ANY})],
        desc="systemd units that failed, and units stuck activating (crash-looping with Restart=). See the table "
             "under System."), 4, 5)
    b.add(stat("Firewall drops + rejects", [q(deny_rate() + " or vector(0)", "per second")], unit="pps", decimals=2,
               thresholds=steps(("green", None), ("orange", 1), ("red", 50)), graph=True, color_mode="value",
               desc="Packets dropped or rejected by any rule or default action (input, forward, output and the "
                    "named chains; IPv4 + IPv6).",
               links=[go("fw-wan firewall", "firewall")]), 4, 5)

    b.row("Traffic")
    b.add(inout("WAN (eth5)",
                f'rate(node_network_receive_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8',
                f'rate(node_network_transmit_bytes_total{{{FW}, device="eth5"}}[$__rate_interval]) * 8',
                "in", "out", fill=20, gradient="opacity",
                overrides=[fixed_color("in", IN), fixed_color("out", OUT)],
                desc="Received above the axis, sent below."), 12, 9)
    vrf_dev = vrf_devices(FW)
    b.add(inout("Traffic per VRF",
                f"rate(node_network_receive_bytes_total{{{FW}}}[$__rate_interval]) * 8 and on (host, device) {vrf_dev}",
                f"rate(node_network_transmit_bytes_total{{{FW}}}[$__rate_interval]) * 8 and on (host, device) {vrf_dev}",
                "{{device}} in", "{{device}} out", calcs=("mean", "max"), placement="right",
                desc="Counters of the VRF devices: traffic received on or sent from the VRF's interfaces "
                     "(received above the axis, sent below).",
                links=[go("fw-wan VRFs & routing", "routing")]), 12, 9)
    b.add(bargauge("Top interfaces now (in + out)", [
        q(f"topk(12, {with_vrf(port_rate(FW, '5m'))} * 8)",
          "{{device}} · {{vrf}}"),
    ], unit="bps", mode="gradient", thresholds=steps(("blue", None)), color={"mode": "continuous-BlPu"},
        desc="Physical, VLAN and tunnel interfaces over the last 5 minutes, with the VRF from the config snapshot."), 8, 10)
    b.add(timeseries("Top interfaces (in + out)", [
        q(f"topk(8, {with_vrf(port_rate(FW, '$__rate_interval'))} * 8)",
          "{{device}} · {{vrf}}"),
    ], unit="bps", fill=0, calcs=("mean", "max"), placement="right"), 16, 10)

    b.row("Firewall")
    b.add(timeseries("Final verdicts", [
        q(f"sum by (action) ({only(fw(), 'action', *FINAL)})", "{{action}}"),
    ], unit="pps", stack=True, fill=40, calcs=("mean", "max"),
        overrides=[fixed_color(a, ACTION_COLORS[a]) for a in FINAL],
        desc="Packets accepted, dropped and rejected per second over every chain (rules and default actions, "
             "IPv4 + IPv6).", links=[go("fw-wan firewall", "firewall")]), 8, 9)
    b.add(timeseries("Drops + rejects by chain", [
        q(f"{deny_rate('family, chain')} > 0", "{{chain}} ({{family}})"),
    ], unit="pps", stack=True, fill=40, calcs=("mean", "max"), no_value="No drops or rejects in range",
        desc="Drop/reject rules and default actions per chain; input/forward are the base filters' default drops.",
        links=[go("fw-wan firewall", "firewall")]), 8, 9)
    b.add(timeseries("NAT connections", [
        q(f"sum by (type) ({nat()}) * 60", "{{type}} NAT"),
    ], unit="short", fill=20, calcs=("mean", "max"),
        desc="New connections per minute through the NAT rules (masquerade to the WAN address).",
        links=[go("fw-wan firewall", "firewall")]), 8, 9)

    b.row("VPNs")
    b.add(state_timeline("Tunnels", [
        q(f"vyos_ipsec_ike_up{{{FW}}}", "IKE {{connection}}"),
        q(f"vyos_ipsec_child_up{{{FW}}}", "CHILD {{child}}"),
        q(f"vyos_wireguard_peer_up{{{FW}}}", "WG {{interface}} {{peer}}"),
    ], mappings=UP_MAP, thresholds=UP_STEPS, desc="IPsec SAs and WireGuard peers (vpn-metrics.py, every minute).",
        links=[go("fw-wan VPNs", "vpn")]), 12, 8)
    b.add(inout("Tunnel interface traffic",
                f'rate(node_network_receive_bytes_total{{{FW}, device=~"vti.*|wg.*"}}[$__rate_interval]) * 8',
                f'rate(node_network_transmit_bytes_total{{{FW}, device=~"vti.*|wg.*"}}[$__rate_interval]) * 8',
                "{{device}} in", "{{device}} out", calcs=("mean", "max"),
                links=[go("fw-wan VPNs", "vpn")]), 12, 8)

    b.row("System")
    b.add(timeseries("CPU", [
        q(f'sum by (mode) (rate(node_cpu_seconds_total{{{FW}, mode!="idle"}}[$__rate_interval])) '
          f'/ scalar(count(node_cpu_seconds_total{{{FW}, mode="idle"}}))', "{{mode}}"),
    ], unit="percentunit", stack=True, fill=40, calcs=("mean", "max"), min_=0,
        desc="Busy time by mode, as a share of all CPUs. softirq is where packet forwarding shows up."), 8, 8)
    b.add(timeseries("Memory", [
        q(f"node_memory_MemTotal_bytes{{{FW}}} - node_memory_MemAvailable_bytes{{{FW}}}", "used"),
        q(f"node_memory_MemAvailable_bytes{{{FW}}}", "available"),
    ], unit="bytes", stack=True, fill=30, calcs=("mean", "lastNotNull"),
        overrides=[fixed_color("used", "orange"), fixed_color("available", "green")]), 8, 8)
    b.add(timeseries("Temperatures", [
        q(f"node_hwmon_temp_celsius{{{FW}}} * on (host, chip, sensor) group_left (label) node_hwmon_sensor_label{{{FW}}}",
          "{{label}}"),
    ], unit="celsius", fill=0, calcs=("mean", "max", "lastNotNull"),
        thresholds=steps(("green", None), ("orange", 80), ("red", 95))), 8, 8)
    b.add(timeseries("Softnet drops and squeezes", [
        q(f"sum(rate(node_softnet_dropped_total{{{FW}}}[$__rate_interval]))", "dropped"),
        q(f"sum(rate(node_softnet_times_squeezed_total{{{FW}}}[$__rate_interval]))", "squeezed"),
    ], unit="short", fill=0, calcs=("max", "lastNotNull"),
        overrides=[fixed_color("dropped", "red"), fixed_color("squeezed", "orange")],
        desc="Packets the kernel dropped because a CPU's backlog was full, and NAPI polls cut short (budget "
             "exhausted). Both should stay at 0."), 8, 8)
    b.add(timeseries("Load", [
        q(f"node_load1{{{FW}}}", "1m"), q(f"node_load5{{{FW}}}", "5m"), q(f"node_load15{{{FW}}}", "15m"),
    ], fill=0, calcs=("max", "lastNotNull")), 8, 8)
    b.add(table("systemd units not active", [
        q(f'max by (name, active, sub) (systemd_units_active_code{{{FW}, load="loaded"}} != 0 != 2)', table=True),
    ], no_value="All loaded units are active or inactive",
        desc="Loaded units that are failed, activating, reloading or deactivating (Telegraf systemd_units).",
        transformations=[organize(exclude=["Time"], rename={"name": "Unit", "active": "Active", "sub": "Sub", "Value": "State"},
                                  order=["Unit", "Active", "Sub", "State"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": UNIT_MAP})]), 8, 8)

    b.row("Interfaces", collapsed=True)
    b.add(interface_table(FW, "fw-wan's interfaces with the VRF from the config snapshot (default = no VRF; the VLAN "
                              "parents eth1-3 are in the default VRF). Rates over the last 5 minutes."), 24, 12)

    b.row("Router log", collapsed=True)
    b.add(router_log("Syslog (without firewall lines)",
                     f'{{host="fw-wan", {NOTICE_UP}}} !~ `\\[ipv[46]-[A-Z]+-[^\\]]+-[A-Z]\\]`',
                     "fw-wan's syslog in Loki, notice and above (informational lines are left out: mostly charon's packet "
                     "chatter; the Logs dashboards show everything), newest first, up to 300 lines. Firewall log lines "
                     "are on the firewall dashboard."), 24, 12)

    return dashboard(UIDS["overview"], "fw-wan overview",
                     "The VyOS edge router: health, WAN and VRF traffic, firewall verdicts, VPN tunnels, system.",
                     b, tags=["fw-wan", "vyos"], time_from="now-6h", extra_links=[FW_LINK, NODE_FULL_LINK, FRR_LINK])


# --- fw-wan firewall ------------------------------------------------------------------

def firewall():
    b = Board()
    verdict_colors = [fixed_color(v, c) for v, c in VERDICT_COLORS.items()]
    b.row("Summary")
    b.add(stat("Final verdicts", [
        q(f'sum({only(fw(), "action", a)}) or vector(0)', a) for a in FINAL
    ], unit="pps", decimals=2, text_mode="value_and_name", color_mode="value", graph=True,
        overrides=[fixed_color(a, ACTION_COLORS[a]) for a in FINAL],
        desc="Packets per second accepted, dropped and rejected, over every chain (rules and default actions, "
             "IPv4 + IPv6). Each packet gets exactly one of these per hook it passes."), 8, 6)
    b.add(stat("Dropped + rejected in range", [
        q(f"sum({only(fw('increase', window='$__range'), 'action', 'drop', 'reject')}) or vector(0)")],
        decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 1)),
        desc="Packets dropped or rejected anywhere in the selected time range."), 4, 6)
    b.add(stat("Default-action drops in range", [
        q(f"sum by (chain) ({only(fw('increase', window='$__range', **BASE_DEFAULT), 'verdict', 'default drop', 'default reject')})",
          "{{chain}}")
    ], decimals=0, text_mode="value_and_name", color_mode="value", thresholds=steps(("green", None), ("orange", 1)),
        no_value="0", desc="Packets that fell through every rule of input, forward and output (IPv4 + IPv6) to the "
                           "default action (drop for input and forward)."), 5, 6)
    b.add(on_loki(stat("Logged in range", [lq(FWLOG_COUNT, "logged", instant=True)], decimals=0, color_mode="value",
                       thresholds=BLUE, no_value="0", desc="Firewall log lines in the syslog (rules with `log`), from Loki.")),
          3, 6)
    b.col(4,
          (stat("Rules not in snapshot", [
              q(f'count({only(fw(None), "action", "unknown")}) or vector(0)'),
          ], thresholds=ORANGE_IF_ANY,
              desc="Rules with counters that fwwan_snapshot.py doesn't know. Re-run fwwan_config.py and custom.py "
                   f"(snapshot from {snap.TAKEN})."), 3),
          (stat("Counters age", [q(f"time() - vyos_nft_metrics_last_run_timestamp_seconds{{{FW}}}")], unit="s",
                decimals=0, color_mode="value", thresholds=steps(("green", None), ("orange", 180), ("red", 600)),
                no_value="nft-metrics.py not running",
                desc="Age of nft-metrics.py's output (written every minute)."), 3))

    b.row("Base chains: input, forward, output")
    for c in BASE_CHAINS:
        b.add(timeseries(c, [
            q(f"sum by (verdict) ({fw(kind='base', chain=c)})", "{{verdict}}"),
        ], unit="pps", stack=True, fill=40, calcs=("mean", "max"), overrides=verdict_colors,
            no_value="No traffic" if c != "output" else "No output filter configured",
            desc=f"What the {c} filter (IPv4 + IPv6) does with packets, per rule action: accepted, dropped, "
                 "handed to a named chain (→ chain; its verdict is counted there) or left to the default action."),
              8, 9)
    b.add(timeseries("Default-action drops", [
        q(f"sum by (family, chain) ({only(fw(**BASE_DEFAULT), 'verdict', 'default drop', 'default reject')})",
          "{{family}} {{chain}}"),
    ], unit="pps", fill=20, calcs=("mean", "max", "sum"),
        desc="Packets the base chains dropped because no rule matched: unsolicited traffic to the router (input) or "
             "through it (forward)."), 12, 9)
    b.add(timeseries("What is being dropped", [
        q(f"sum by (family, chain, rule) ({only(fw(), 'action', 'drop', 'reject')}) > 0", "{{chain}} #{{rule}} ({{family}})"),
    ], unit="pps", fill=10, stack=True, calcs=("mean", "max"), placement="right", no_value="No drops or rejects in range",
        desc="Every drop/reject rule and default action, in any chain, while it matches."), 12, 9)

    b.row("Chains")
    b.add(state_timeline("Chain activity", [
        q(f"sum by (family, chain) ({fw()})", "{{chain}} · {{family}}"),
    ], unit="pps", row_height=0.9, thresholds=steps(("transparent", None), ("dark-blue", 0.001), ("blue", 0.1),
                                                     ("green", 1), ("yellow", 10), ("orange", 100), ("red", 1000)),
        desc="Rule matches per second in each chain. Colour steps: >0, 0.1, 1, 10, 100, 1000 pps."), 24, 12)
    b.add(timeseries("Packets per chain", [q(f"sum by (family, chain) ({fw()})", "{{chain}} · {{family}}")],
                     unit="pps", fill=10, calcs=("mean", "max"), placement="right"), 12, 9)
    b.add(timeseries("Traffic per chain", [q(f"sum by (family, chain) ({fw(what='bytes')}) * 8", "{{chain}} · {{family}}")],
                     unit="bps", fill=10, calcs=("mean", "max"), placement="right"), 12, 9)

    b.row("Rules")
    lbl = "max without (instance, job, role, host, ra, verdict)"
    b.add(table("Rules", [
        q(f"{lbl} ({fw(window='5m')})", table=True),
        q(f"{lbl} ({fw('increase', window='$__range')})", table=True),
        q(f"{lbl} ({fw('increase', what='bytes', window='$__range')})", table=True),
        q(f"{lbl} ({fw(None)})", table=True),
        q(f"{lbl} ({fw(None, what='bytes')})", table=True),
    ], desc="Every rule and default action of every chain (IPv4 and IPv6). Action, jump target and match come from "
            f"the config snapshot ({snap.TAKEN}); the counters reset when the firewall is reloaded (commit).",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "family": "Family", "kind": "Kind", "chain": "Chain", "rule": "Rule", "action": "Action",
            "target": "Jumps to", "key": "Match", "Value #A": "Packets/s", "Value #B": "Packets in range",
            "Value #C": "Bytes in range", "Value #D": "Total packets", "Value #E": "Total bytes"},
            order=["Family", "Kind", "Chain", "Rule", "Action", "Jumps to", "Match", "Packets/s", "Packets in range",
                   "Bytes in range", "Total packets", "Total bytes"])],
        overrides=[cell("Action", "color-background"), override("Action", {"mappings": ACTION_MAP, "custom.width": 100}),
                   override("Match", {"mappings": MATCH_MAP, "custom.minWidth": 280}),
                   override("Family", {"custom.width": 70}), override("Kind", {"custom.width": 70}),
                   override("Chain", {"custom.width": 140}), override("Rule", {"custom.width": 110}),
                   override("Jumps to", {"custom.width": 130}),
                   override("Packets/s", {"unit": "pps", "decimals": 2}),
                   override("Packets in range", {"decimals": 0, "custom.cellOptions": {"type": "gauge", "mode": "basic",
                                                                                       "valueDisplayMode": "text"},
                                                 "color": {"mode": "continuous-BlPu"}}),
                   override("Bytes in range|Total bytes", {"unit": "decbytes"}, regex=True),
                   override("Total packets", {"decimals": 0})],
        sort="Packets in range", desc_sort=True), 24, 18)
    b.add(bargauge("Top rules in range", [
        q(f"sort_desc(topk(12, {fw('increase', window='$__range')} > 0))", "{{chain}} #{{rule}} ({{family}}) · {{verdict}}",
          instant=True),
    ], decimals=0, mode="gradient", color={"mode": "continuous-BlPu"}, thresholds=BLUE,
        desc="The 12 rules (jumps and default actions included) with the most packets in the selected time range, "
             "largest first."), 12, 10)
    b.add(value_text(bargauge("Default actions hit in range", [
        q(f"sum by (family, chain, verdict) ({fw('increase', window='$__range', **DEFAULT)})",
          "{{chain}} ({{family}}) · {{verdict}}"),
    ], decimals=0, thresholds=GREEN, desc="Packets that fell through every rule of a chain to its default action.",
        overrides=[override(f".*· {v}$", {"color": {"mode": "fixed", "fixedColor": c}}, regex=True)
                   for v, c in VERDICT_COLORS.items()])), 12, 10)

    b.row("NAT")
    nlbl = "max without (instance, job, role, host)"
    b.add(table("NAT rules", [
        q(f"{nlbl} ({nat(window='5m')}) * 60", table=True),
        q(f"{nlbl} ({nat('increase', window='$__range')})", table=True),
        q(f"{nlbl} ({nat(None)})", table=True),
    ], desc="NAT rules only see the first packet of a connection, so the counters are connections translated. "
            "Match and translation from the config snapshot.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "family": "Family", "type": "Type", "rule": "Rule", "key": "Match / translation",
            "Value #A": "Connections/min", "Value #B": "Connections in range", "Value #C": "Total"},
            order=["Family", "Type", "Rule", "Match / translation", "Connections/min", "Connections in range", "Total"])],
        overrides=[override("Match / translation", {"mappings": NAT_MAP, "custom.minWidth": 320}),
                   override("Connections/min", {"decimals": 1}),
                   override("Connections in range", {"decimals": 0, "custom.cellOptions": {
                       "type": "gauge", "mode": "basic", "valueDisplayMode": "text"}, "color": {"mode": "continuous-BlPu"}}),
                   override("Total", {"decimals": 0})],
        sort="Connections in range", desc_sort=True), 12, 10)
    b.add(timeseries("NAT connections per rule", [
        q(f"sum by (family, type, rule) ({nat()}) * 60 > 0", "{{type}} {{rule}} ({{family}})"),
    ], unit="short", fill=10, stack=True, calcs=("mean", "max"), placement="right", no_value="No NAT matches in range",
        desc="New connections per minute translated by each NAT rule (source NAT = masquerade to the WAN address)."),
        12, 10)

    b.row("Conntrack")
    b.add(timeseries("Tracked connections", [
        q(f"node_nf_conntrack_entries{{{FW}}}", "entries"),
        q(f"node_nf_conntrack_entries_limit{{{FW}}}", "limit"),
    ], fill=10, decimals=0, calcs=("min", "max", "lastNotNull"),
        overrides=[fixed_color("entries", "blue"),
                   override("limit", {"color": {"mode": "fixed", "fixedColor": "red"}, "custom.fillOpacity": 0,
                                      "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}, "custom.hideFrom":
                                          {"legend": False, "tooltip": False, "viz": True}})],
        desc="The limit (nf_conntrack_max) is hidden from the graph to keep the scale readable; it's in the legend."), 8, 9)
    b.add(timeseries("New connections", [
        q(f"rate(node_nf_conntrack_stat_insert{{{FW}}}[$__rate_interval])", "inserted"),
    ], unit="short", fill=20, calcs=("mean", "max"), desc="Conntrack entries created per second (new flows)."), 8, 9)
    b.add(timeseries("Conntrack problems", [
        q(f"rate(node_nf_conntrack_stat_{m}{{{FW}}}[$__rate_interval])", m)
        for m in ("insert_failed", "drop", "early_drop", "invalid", "search_restart")
    ], unit="short", fill=0, calcs=("max", "lastNotNull"),
        overrides=[fixed_color("insert_failed", "red"), fixed_color("drop", "dark-red"), fixed_color("early_drop", "orange"),
                   fixed_color("invalid", "yellow"), fixed_color("search_restart", "purple")],
        desc="Per second. drop/early_drop/insert_failed mean the table was full or racing; invalid packets are "
             "dropped by conn_filter rule 20 when they reach a chain that jumps there."), 8, 9)

    b.row("Firewall log")
    b.add(on_loki(timeseries("Logged packets", [lq(FWLOG_RATE, "{{rule}}")], draw="bars", fill=80, stack=True,
                             calcs=("sum",), decimals=0, no_value="No firewall log lines in range",
                             desc="Firewall log lines per interval, per rule (Loki).")), 8, 12)
    fields = {"chain": "Chain", "rule": "Rule", "action": "Action", "in": "In", "out": "Out", "proto": "Proto",
              "src": "Source", "spt": "Sport", "dst": "Destination", "dpt": "Dport"}
    fw_log = log_table("Firewall log", FWLOG, list(fields), max_lines=500, no_value="No firewall log lines in range",
                       desc="Rules with `log` write a kernel line ([ipv4-NAM-<chain>-<rule>-<D|A|R>] IN= OUT= SRC= "
                            "DST= ...) to the syslog, which reaches Loki through Alloy. Newest first, up to 500.",
                       rename=fields, widths={"Chain": 120, "Rule": 60, "Action": 70, "Proto": 60, "Sport": 70, "Dport": 70},
                       overrides=[cell("Action", "color-text"), override("Action", {"mappings": ACTION_MAP})])
    b.add(fw_log, 16, 12)

    b.row("Rule reference", collapsed=True)
    b.add(rule_reference(), 24, 22)

    return dashboard(UIDS["firewall"], "fw-wan firewall",
                     "fw-wan's firewall: final verdicts, the input/forward/output filters and their default-action "
                     "drops, every chain and rule, NAT, conntrack, the firewall log.",
                     b, tags=["fw-wan", "vyos", "firewall"], extra_links=[FW_LINK])


# --- fw-wan VPNs ----------------------------------------------------------------------

def vpn():
    b = Board()
    b.row("Status")
    b.add(stat("IPsec connections", [q(f"vyos_ipsec_ike_up{{{FW}}}", "{{connection}} → {{remote}}")],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal",
               desc="IKE SA established per configured connection."), 6, 6)
    b.add(stat("IKE state", [q(f"vyos_ipsec_ike_state_info{{{FW}}}", "{{connection}}: {{state}}")], text_mode="name",
               color_mode="value", thresholds=BLUE, orientation="horizontal",
               desc="strongSwan's IKE SA state (CONNECTING while it keeps retrying an unreachable peer)."), 5, 6)
    b.add(stat("CHILD SAs", [q(f"vyos_ipsec_child_up{{{FW}}}", "{{child}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal"), 5, 6)
    b.add(stat("WireGuard peers", [q(f"vyos_wireguard_peer_up{{{FW}}}", "{{interface}} {{peer}}")],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, orientation="horizontal",
               desc="UP = handshake within the last 3 minutes. Road-warrior peers are DOWN while not connected."), 4, 6)
    b.col(4,
          (described(bgp_summary(f'{{{FW}, vrf=~"vpn_.*"}}'),
                     "BGP sessions in the VPN VRFs (vpn_*) from frr_exporter: the haystack peer in vpn_hay. Drops to "
                     "0 if the exporter is down."), 3),
          (stat("vpn-metrics.py", [
              q(f"vyos_vpn_metrics_ipsec_ok{{{FW}}}", "IPsec"), q(f"vyos_vpn_metrics_wireguard_ok{{{FW}}}", "WG"),
              q(f"time() - vyos_vpn_metrics_last_run_timestamp_seconds{{{FW}}}", "age"),
          ], text_mode="value_and_name", mappings=OK_MAP, thresholds=steps(("red", None), ("green", 1)),
              overrides=[override("age", {"unit": "s", "mappings": [], "decimals": 0,
                                          "thresholds": steps(("green", None), ("orange", 180), ("red", 600))})],
              desc="The textfile script could read IPsec (VICI) and WireGuard state, and how old its output is "
                   "(it runs every minute)."), 3))

    b.row("IPsec")
    b.add(state_timeline("SA state", [
        q(f"vyos_ipsec_ike_up{{{FW}}}", "IKE {{connection}}"),
        q(f"vyos_ipsec_child_up{{{FW}}}", "CHILD {{child}}"),
    ], mappings=UP_MAP, thresholds=UP_STEPS), 12, 7)
    b.add(stat("SA age", [
        q(f"vyos_ipsec_ike_established_seconds{{{FW}}} > 0", "IKE {{connection}}"),
        q(f"vyos_ipsec_child_installed_seconds{{{FW}}} > 0", "CHILD {{child}}"),
    ], unit="dtdurations", text_mode="value_and_name", color_mode="value", thresholds=BLUE, orientation="horizontal",
        no_value="no SA up", desc="Since the IKE SA was established and the newest CHILD SA installed (rekeys "
                                   "replace the CHILD SA)."), 6, 7)
    b.add(stat("Rekeys in range", [
        q(f"resets(vyos_ipsec_ike_established_seconds{{{FW}}}[$__range])", "IKE {{connection}}"),
        q(f"resets(vyos_ipsec_child_installed_seconds{{{FW}}}[$__range])", "CHILD {{child}}"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE, orientation="horizontal", decimals=0,
        desc="How often the SA age went back to 0: rekeys and re-establishments (a CHILD rekey every few hours "
             "is normal)."), 6, 7)
    b.add(inout("CHILD SA traffic",
                f"rate(vyos_ipsec_child_received_bytes{{{FW}}}[$__rate_interval]) * 8",
                f"rate(vyos_ipsec_child_sent_bytes{{{FW}}}[$__rate_interval]) * 8",
                "{{child}} in", "{{child}} out",
                desc="Decrypted traffic through each CHILD SA (counters restart at a rekey; rate() handles that)."), 12, 8)
    b.add(inout("CHILD SA packets",
                f"rate(vyos_ipsec_child_received_packets{{{FW}}}[$__rate_interval])",
                f"rate(vyos_ipsec_child_sent_packets{{{FW}}}[$__rate_interval])",
                "{{child}} in", "{{child}} out", unit="pps"), 12, 8)

    b.row("Tunnel interfaces")
    tun = f'{FW}, device=~"vti.*|wg.*"'
    b.add(inout("Traffic",
                f"rate(node_network_receive_bytes_total{{{tun}}}[$__rate_interval]) * 8",
                f"rate(node_network_transmit_bytes_total{{{tun}}}[$__rate_interval]) * 8",
                "{{device}} in", "{{device}} out"), 12, 8)
    b.add(timeseries("Errors and drops", [
        q(f"rate(node_network_receive_errs_total{{{tun}}}[$__rate_interval]) + rate(node_network_transmit_errs_total{{{tun}}}[$__rate_interval])",
          "{{device}} errors"),
        q(f"rate(node_network_receive_drop_total{{{tun}}}[$__rate_interval]) + rate(node_network_transmit_drop_total{{{tun}}}[$__rate_interval])",
          "{{device}} drops"),
    ], unit="pps", fill=0, calcs=("max", "lastNotNull"),
        desc="A VTI counts tx errors when it has no CHILD SA to send through (tunnel down)."), 6, 8)
    b.add(state_timeline("Link state", [
        # The Telegraf series (until 2026-11-13) keep the history in long ranges.
        q(f'(max by (interface) (vyos_interface_link{{{FW}, interface=~"vti.*|wg.*"}}) '
          f'+ max by (interface) (vyos_interface_state{{{FW}, interface=~"vti.*|wg.*"}})) '
          f'or (max by (interface) (show_interfaces_link{{{FW}, interface=~"vti.*|wg.*"}}) '
          f'+ max by (interface) (show_interfaces_state{{{FW}, interface=~"vti.*|wg.*"}}))', "{{interface}}"),
    ], mappings=LINK_MAP, thresholds=LINK_STEPS,
        desc="From VyOS (status-metrics.py): admin down = disabled in the config."), 6, 8)
    lbl = "max by (interface)"
    tsel = f'{FW}, interface=~"vti.*|wg.*"'
    b.add(table("Tunnel interfaces", [
        q(f"{lbl} (vyos_interface_link{{{tsel}}} + on (interface) vyos_interface_state{{{tsel}}})", table=True),
        q(f"max by (interface, ip_addresses) (vyos_interface_info{{{tsel}}})", table=True),
        q(f'{lbl} (label_replace(node_network_mtu_bytes{{{tun}}}, "interface", "$1", "device", "(.*)"))', table=True),
        q(f'{lbl} (label_replace(rate(node_network_receive_bytes_total{{{tun}}}[5m]) * 8, "interface", "$1", "device", "(.*)"))',
          table=True),
        q(f'{lbl} (label_replace(rate(node_network_transmit_bytes_total{{{tun}}}[5m]) * 8, "interface", "$1", "device", "(.*)"))',
          table=True),
    ], desc="VRF and tunnel from the config snapshot. Rates over the last 5 minutes.",
        transformations=[MERGE, organize(exclude=["Time", "Value #B"], rename={
            "interface": "Interface", "ip_addresses": "Address", "Value #A": "State", "Value #C": "MTU",
            "Value #D": "In", "Value #E": "Out"}, order=["Interface", "Address", "State", "MTU", "In", "Out"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": LINK_MAP, "thresholds": LINK_STEPS}),
                   override("In", {"unit": "bps"}), override("Out", {"unit": "bps"}),
                   override("Interface", {"mappings": [{"type": "value", "options": {
                       dev: {"text": f"{dev} · {i['vrf']}", "index": n}
                       for n, (dev, i) in enumerate(snap.INTERFACES.items())}}]})],
        sort="Interface"), 24, 6)

    b.row("WireGuard")
    b.add(stat("Last handshake", [
        q(f"time() - vyos_wireguard_latest_handshake_timestamp_seconds{{{FW}}}", "{{interface}} {{peer}}"),
    ], unit="s", text_mode="value_and_name", color_mode="value", orientation="horizontal",
        thresholds=steps(("green", None), ("orange", 180), ("red", 86400)),
        mappings=[{"type": "range", "options": {"from": 1e9, "to": None, "result": {"text": "never", "color": "text",
                                                                                 "index": 0}}}],
        desc="Age of the latest handshake per peer (WireGuard re-handshakes every 2 minutes while traffic flows)."), 6, 8)
    b.add(inout("Peer traffic",
                f"rate(vyos_wireguard_received_bytes_total{{{FW}}}[$__rate_interval]) * 8",
                f"rate(vyos_wireguard_sent_bytes_total{{{FW}}}[$__rate_interval]) * 8",
                "{{peer}} in", "{{peer}} out"), 12, 8)
    b.add(state_timeline("Peer up", [q(f"vyos_wireguard_peer_up{{{FW}}}", "{{interface}} {{peer}}")],
                         mappings=UP_MAP, thresholds=UP_STEPS), 6, 8)

    vsel = f'{FW}, vrf=~"vpn_.*"'
    b.row("BGP over the tunnels")
    b.add(bgp_table(vsel), 24, 6)
    b.add(bgp_state(vsel), 8, 7)
    b.add(timeseries("Prefixes received / advertised", [
        q(f"sum by (vrf, peer) (frr_bgp_peer_prefixes_received_count_total{{{vsel}}})", "{{peer}} rx"),
        q(f"sum by (vrf, peer) (frr_bgp_peer_prefixes_advertised_count_total{{{vsel}}})", "{{peer}} tx"),
    ], decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull")), 8, 7)
    b.add(timeseries("Routes in the VPN VRFs", [
        q(f"sum by (vrf) (frr_route_total{{{vsel}}})", "{{vrf}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull"), desc="IPv4 + IPv6 zebra routes."), 8, 7)

    b.row("VPN firewall chains")
    vpn_chains = dict(family="ipv4", chain=("ipsec", "haystack", "haystack_dns", "haystack_ssh", "haystack_vxlan",
                                            "vpn_me_FW", "wg70_fw", "bgp_peers"))
    b.add(timeseries("Matches per chain", [
        q(f"sum by (chain) ({fw(**vpn_chains)})", "{{chain}}"),
    ], unit="pps", fill=10, calcs=("mean", "max"),
        desc="ipsec (IKE/ESP to fw-wan, input filter 500-502), haystack* (forwarded from vpn_hay), vpn_me_FW "
             "(from vpn_me), wg70_fw and bgp_peers.", links=[go("fw-wan firewall", "firewall")]), 12, 8)
    b.add(timeseries("Drops and rejects", [
        q(f"sum by (chain, rule) ({only(fw(**vpn_chains), 'action', 'drop', 'reject')})",
          "{{chain}} #{{rule}}"),
    ], unit="pps", fill=10, calcs=("mean", "max"),
        desc="ipsec default-action: IKE/ESP from addresses that aren't configured peers."), 12, 8)

    b.row("IPsec log", collapsed=True)
    b.add(router_log("charon", f'{{host="fw-wan", app=~"charon.*", {NOTICE_UP}}}',
                     "strongSwan's log lines in Loki, notice and above (its informational lines are every packet sent and "
                     "retransmitted), newest first, up to 1000 lines. While a peer is unreachable charon logs a retry every "
                     "few minutes, so long ranges can hit the cap.", max_lines=1000), 24, 12)

    return dashboard(UIDS["vpn"], "fw-wan VPNs",
                     "fw-wan's IPsec connections, VTI and WireGuard interfaces, WireGuard peers, BGP over the tunnels.",
                     b, tags=["fw-wan", "vyos", "vpn"], extra_links=[FW_LINK, FRR_LINK])


# --- fw-wan VRFs & routing -------------------------------------------------------------

def routing():
    h = 'host="$host"'
    b = Board()
    b.row("Summary")
    b.add(bgp_summary(f"{{{h}}}"), 6, 5)
    b.add(bfd_summary(f"{{{h}}}"), 5, 5)
    b.add(stat("Routes", [
        q(f'sum(frr_route_total{{{h}, afi="ipv4"}})', "IPv4"), q(f'sum(frr_route_total{{{h}, afi="ipv6"}})', "IPv6"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE, graph=True,
        desc="Zebra RIB routes over all VRFs."), 5, 5)
    b.add(stat("VRFs", [q(f'count(count by (vrf) (frr_route_total{{{h}, vrf!="default"}}))')], color_mode="value",
               thresholds=BLUE, desc="VRFs with a routing table (default not counted)."), 2, 5)
    b.add(stat("Route changes in range", [q(f"sum(changes(frr_route_total{{{h}}}[$__range])) or vector(0)")],
               decimals=0, thresholds=ORANGE_IF_ANY,
               desc="Times a VRF's route count changed in the selected time range (scrape resolution)."), 3, 5)
    b.add(stat("RIB not in FIB", [q(f"sum(frr_route_total{{{h}}}) - sum(frr_route_total_fib{{{h}}})")], decimals=0,
               thresholds=steps(("green", None), ("orange", 1)),
               desc="Zebra routes that aren't installed in the kernel (inactive or rejected)."), 3, 5)

    b.row("Routes per VRF")
    rv = f'{h}, vrf=~"$vrf"'
    vv = "max by (vrf)"
    b.add(table("Routing tables", [
        q(f'{vv} (frr_route_total{{{rv}, afi="ipv4"}})', table=True),
        q(f'{vv} (frr_route_total_fib{{{rv}, afi="ipv4"}})', table=True),
        q(f'{vv} (frr_route_total{{{rv}, afi="ipv6"}})', table=True),
        q(f'{vv} (frr_route_total_fib{{{rv}, afi="ipv6"}})', table=True),
        q(f"sum by (vrf) (changes(frr_route_total{{{rv}}}[$__range]))", table=True),
        q(f'{vv} (frr_bgp_rib_count_total{{{rv}, afi="ipv4"}})', table=True),
        q(f'count by (vrf) (frr_bgp_peer_state{{{rv}}} == 1)', table=True),
        q(f'{vv} (frr_bgp_rib_count_total{{{rv}, afi="ipv6", safi="unicast"}})', table=True),
    ], desc="Per VRF: zebra RIB and kernel FIB routes per address family, route count changes in range, IPv4 and "
            "IPv6 unicast BGP RIB entries (the leaves' IPv6 underlay and EVPN are in the default VRF; EVPN is on the "
            "FRR / EVPN fabric dashboard) and established BGP sessions.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "vrf": "VRF", "Value #A": "IPv4 RIB", "Value #B": "IPv4 FIB", "Value #C": "IPv6 RIB", "Value #D": "IPv6 FIB",
            "Value #E": "Changes in range", "Value #F": "BGP RIB (IPv4)", "Value #G": "BGP sessions up",
            "Value #H": "BGP RIB (IPv6)"},
            order=["VRF", "IPv4 RIB", "IPv4 FIB", "IPv6 RIB", "IPv6 FIB", "BGP RIB (IPv4)", "BGP RIB (IPv6)",
                   "BGP sessions up", "Changes in range"])],
        overrides=[override("IPv4 RIB|IPv6 RIB", {"custom.cellOptions": {"type": "gauge", "mode": "basic",
                                                                         "valueDisplayMode": "text"},
                                                  "color": {"mode": "fixed", "fixedColor": INFO}}, regex=True),
                   override("Changes in range", {"thresholds": ORANGE_IF_ANY, "custom.cellOptions": {"type": "color-text"}})],
        sort="VRF"), 12, 10)
    b.add(timeseries("Routes per VRF", [q(f"sum by (vrf) (frr_route_total{{{rv}}})", "{{vrf}}")],
                     decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull"), placement="right",
                     desc="IPv4 + IPv6 zebra routes."), 12, 10)
    b.add(timeseries("Route changes", [
        q(f"sum by (vrf) (changes(frr_route_total{{{rv}}}[$__rate_interval])) > 0", "{{vrf}}"),
    ], draw="bars", fill=80, stack=True, decimals=0, calcs=("sum",), no_value="No route changes in range",
        desc="Route count changes per interval and VRF (a flapping route shows as a column of bars)."), 12, 8)
    b.add(timeseries("RIB routes not in the FIB", [
        q(f"sum by (vrf) (frr_route_total{{{rv}}}) - sum by (vrf) (frr_route_total_fib{{{rv}}}) > 0", "{{vrf}}"),
    ], decimals=0, fill=0, calcs=("max", "lastNotNull"), no_value="All RIB routes are in the FIB"), 12, 8)

    b.row("BGP")
    b.add(bgp_table(f"{h}, vrf=~\"$vrf\"", no_value=NO_BGP), 24, 8)
    bs = f'{h}, vrf=~"$vrf"'
    b.add(bgp_state(bs, no_value=NO_BGP), 12, 7)
    b.add(timeseries("BGP RIB entries", [
        q(f"max by (vrf, afi, safi) (frr_bgp_rib_count_total{{{bs}}})", "{{vrf}} {{afi}}/{{safi}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull"), no_value=NO_BGP), 12, 7)
    b.add(timeseries("Prefixes received", [
        q(f"sum by (vrf, peer, peer_hostname) (frr_bgp_peer_prefixes_received_count_total{{{bs}}})",
          "{{vrf}} · {{peer}} {{peer_hostname}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull"), no_value=NO_BGP), 8, 8)
    b.add(timeseries("Prefixes advertised", [
        q(f"sum by (vrf, peer, peer_hostname) (frr_bgp_peer_prefixes_advertised_count_total{{{bs}}})",
          "{{vrf}} · {{peer}} {{peer_hostname}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "max", "lastNotNull"), no_value=NO_BGP), 8, 8)
    b.add(timeseries("BGP messages", [
        q(f"sum by (vrf, peer) (rate(frr_bgp_peer_message_received_total{{{bs}}}[$__rate_interval]) "
          f"+ rate(frr_bgp_peer_message_sent_total{{{bs}}}[$__rate_interval]))", "{{vrf}} · {{peer}}"),
    ], unit="short", fill=0, calcs=("mean", "max"), no_value=NO_BGP,
        desc="Messages per second (updates and keepalives), rx + tx."), 8, 8)

    b.row("Interfaces by VRF")
    vrf_dev = vrf_devices(rv)
    b.add(inout("Traffic per VRF",
                f"rate(node_network_receive_bytes_total{{{h}}}[$__rate_interval]) * 8 and on (host, device) {vrf_dev}",
                f"rate(node_network_transmit_bytes_total{{{h}}}[$__rate_interval]) * 8 and on (host, device) {vrf_dev}",
                "{{device}} in", "{{device}} out", calcs=("mean", "max"), placement="right",
                desc="Counters of the VRF devices: traffic received on or sent from the VRF's interfaces "
                     "(received above the axis, sent below)."), 12, 10)
    b.add(timeseries("Interface traffic (in + out)", [
        q(f"{in_vrf(with_vrf(port_rate(h, '$__rate_interval')), '$vrf')} * 8 > 0",
          "{{vrf}} · {{device}}"),
    ], unit="bps", fill=0, calcs=("mean", "max"), placement="right",
        desc="Interfaces with traffic in the selected VRFs, labelled with their VRF from the config snapshot. fw-wan "
             "only: other routers' interfaces show VRF n/a and are left out when a VRF is selected."), 12, 10)
    b.add(interface_table(h, "The router's interfaces in the selected VRFs (no VRF devices, loopback, dummies or PIM "
                             "registers), with the VRF from the config snapshot (default = no VRF). fw-wan only: other "
                             "routers' interfaces show VRF n/a and are left out when a VRF is selected. Rates over the "
                             "last 5 minutes.", vrf="$vrf"), 24, 12)

    b.row("BFD", collapsed=True)
    b.add(table("BFD peers", [
        q(f"max without (instance, job, role, host) (frr_bfd_peer_state{{{h}}})", table=True),
        q(f"max without (instance, job, role, host) (frr_bfd_peer_uptime{{{h}}})", table=True),
    ], no_value="No BFD peers on this router",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "local": "Local", "peer": "Peer", "Value #A": "State", "Value #B": "Uptime"},
            order=["Local", "Peer", "State", "Uptime"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": BFD_MAP}),
                   override("Uptime", {"unit": "dtdurations"})]), 12, 8)
    b.add(table("frr_exporter collectors", [
        q(f"max without (instance, job, role, host) (frr_collector_up{{{h}}})", table=True),
    ], desc="OSPF is collected but no router runs it, so there are no OSPF panels.",
        transformations=[organize(exclude=["Time"], rename={"collector": "Collector", "Value": "State"})],
        overrides=[cell("State", "color-background"), override("State", {"mappings": UP_MAP, "thresholds": UP_STEPS})]),
        12, 8)

    host = query_var("host", "Router", 'label_values(frr_route_total, host)', multi=False, include_all=False)
    host["current"] = {"selected": True, "text": "fw-wan", "value": "fw-wan"}
    node = query_var("node", "node_exporter", 'label_values(node_uname_info{job="vyos-node", host="$host"}, instance)',
                     multi=False, include_all=False)
    node["hide"] = 2  # for the Node Exporter Full link
    variables = [host, query_var("vrf", "VRF", 'label_values(frr_route_total{host="$host"}, vrf)'), node]
    return dashboard(UIDS["routing"], "fw-wan VRFs & routing",
                     "Routing tables, BGP sessions and interfaces per VRF. Router picker (default fw-wan; the VyOS "
                     "leaves and DHCP VMs work too).", b, tags=["fw-wan", "vyos", "bgp"], variables=variables,
                     extra_links=[FW_LINK, FRR_LINK, NODE_HOST_LINK])


DASHBOARDS = {
    "Edge/fw-wan-overview.json": overview,
    "Edge/fw-wan-firewall.json": firewall,
    "Edge/fw-wan-vpn.json": vpn,
    "Edge/fw-wan-routing.json": routing,
}
