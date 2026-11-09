#!/usr/bin/env python3
"""Build the custom (non-community) dashboards as JSON.

    python3 -I modules/services/monitoring/dashboards/custom.py

The JSON files it writes are committed and provisioned like the community ones,
so edit this script and re-run it rather than editing them by hand. It needs no
network access. Each dashboard:

- queries the provisioned Prometheus datasource (uid "prometheus") directly;
- uses the scrape targets' "host" label for names and pickers;
- carries the "lylat" tag and a "Dashboards" dropdown listing every dashboard
  with that tag (the overview shows them as buttons), keeping the time range.

Down targets (no exporter yet) simply have no series, so panels count what's
there; `... or vector(0)` keeps the "down"/"failing" stats at 0 rather than
"No data".
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
DS = {"type": "prometheus", "uid": "prometheus"}

NODE_JOBS = 'job=~"node|vyos-node"'
STACK_JOBS = 'job=~"prometheus|alertmanager|grafana|snmp-exporter|blackbox-exporter"'
NODE_DASH = "/d/node-exporter-full/node-exporter-full"
FRR_DASH = "/d/frr-evpn-fabric/frr-evpn-fabric"
PROBES_DASH = "/d/blackbox-probes/blackbox-probes"
STACK_DASH = "/d/monitoring-stack/monitoring-stack"
SNMP_DASH = "/d/snmp-device-summary/snmp-device-summary"


# --- building blocks -------------------------------------------------------

def mapping(**states):
    """Value mappings: mapping(**{"0": ("DOWN", "red"), "1": ("UP", "green")})."""
    return [{"type": "value", "options": {
        k: {"text": text, "color": color, "index": i} for i, (k, (text, color)) in enumerate(states.items())
    }}]


UP_MAP = mapping(**{"0": ("DOWN", "red"), "1": ("UP", "green")})
OK_MAP = mapping(**{"0": ("FAILED", "red"), "1": ("OK", "green")})
# frr_exporter: 0 = Down, 1 = Established, 2 = Administratively down.
BGP_MAP = mapping(**{"0": ("Down", "red"), "1": ("Established", "green"), "2": ("Admin down", "orange")})
BFD_MAP = mapping(**{"0": ("Down", "red"), "1": ("Up", "green")})


def steps(*pairs):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in pairs]}


GREEN = steps(("green", None))
BLUE = steps(("blue", None))
RED_IF_ANY = steps(("green", None), ("red", 1))
ORANGE_IF_ANY = steps(("green", None), ("orange", 1))
PERCENT = steps(("green", None), ("orange", 75), ("red", 90))
UP_STEPS = steps(("red", None), ("green", 1))


def q(expr, legend="__auto", table=False):
    """A Prometheus target. table=True makes it an instant query in table format."""
    t = {"datasource": DS, "editorMode": "code", "expr": expr, "legendFormat": legend,
         "range": not table, "instant": table}
    if table:
        t["format"] = "table"
        t["legendFormat"] = ""
    return t


def override(name, props, regex=False):
    return {"matcher": {"id": "byRegexp" if regex else "byName", "options": name},
            "properties": [{"id": k, "value": v} for k, v in props.items()]}


def fixed_color(name, color):
    return override(name, {"color": {"mode": "fixed", "fixedColor": color}})


def panel(type_, title, targets, *, desc="", unit=None, decimals=None, min_=None, max_=None,
          thresholds=None, mappings=None, color=None, custom=None, options=None, overrides=None,
          transformations=None, links=None, no_value=None):
    for i, t in enumerate(targets):
        t["refId"] = chr(ord("A") + i)
    defaults = {"color": color or {"mode": "thresholds"}, "thresholds": thresholds or GREEN,
                "mappings": mappings or []}
    for key, value in (("unit", unit), ("decimals", decimals), ("min", min_), ("max", max_),
                       ("noValue", no_value), ("custom", custom)):
        if value is not None:
            defaults[key] = value
    p = {"type": type_, "title": title, "description": desc, "datasource": DS, "targets": targets,
         "fieldConfig": {"defaults": defaults, "overrides": overrides or []}, "options": options or {}}
    if transformations:
        p["transformations"] = transformations
    if links:
        p["links"] = [{"title": t, "url": u, "targetBlank": False} for t, u in links]
    return p


REDUCE_LAST = {"calcs": ["lastNotNull"], "fields": "", "values": False}


def stat(title, targets, *, color_mode="background", text_mode="auto", graph=False, **kw):
    kw.setdefault("thresholds", GREEN)
    return panel("stat", title, targets, options={
        "reduceOptions": REDUCE_LAST, "colorMode": color_mode, "graphMode": "area" if graph else "none",
        "textMode": text_mode, "justifyMode": "auto", "orientation": "auto", "wideLayout": True,
        "showPercentChange": False}, **kw)


def timeseries(title, targets, *, stack=False, fill=10, calcs=("mean", "max", "lastNotNull"),
               legend="table", placement="bottom", draw="line", step=False, **kw):
    custom = {"drawStyle": draw, "lineWidth": 1, "fillOpacity": fill, "showPoints": "never",
              "spanNulls": False, "lineInterpolation": "stepAfter" if step else "linear",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"},
              "axisPlacement": "auto", "gradientMode": "none"}
    kw.setdefault("color", {"mode": "palette-classic"})
    return panel("timeseries", title, targets, custom=custom, options={
        "legend": {"displayMode": legend, "placement": placement, "calcs": list(calcs), "showLegend": True},
        "tooltip": {"mode": "multi", "sort": "desc"}}, **kw)


def table(title, targets, *, sort=None, desc_sort=False, **kw):
    custom = {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": False, "inspect": False}
    options = {"showHeader": True, "cellHeight": "sm",
               "footer": {"show": False, "reducer": ["sum"], "countRows": False, "fields": ""}}
    if sort:
        options["sortBy"] = [{"displayName": sort, "desc": desc_sort}]
    return panel("table", title, targets, custom=custom, options=options, **kw)


def bargauge(title, targets, *, mode="basic", **kw):
    return panel("bargauge", title, targets, options={
        "displayMode": mode, "orientation": "horizontal", "reduceOptions": REDUCE_LAST, "showUnfilled": True,
        "valueMode": "color", "namePlacement": "left", "sizing": "auto", "minVizHeight": 16,
        "minVizWidth": 8, "maxVizHeight": 300}, **kw)


def state_timeline(title, targets, **kw):
    return panel("state-timeline", title, targets, custom={"fillOpacity": 80, "lineWidth": 0}, options={
        "mergeValues": True, "showValue": "never", "alignValue": "left", "rowHeight": 0.85,
        "legend": {"showLegend": False, "displayMode": "list", "placement": "bottom"},
        "tooltip": {"mode": "single", "sort": "none"}}, **kw)


def text(title, content):
    return {"type": "text", "title": title, "options": {"mode": "markdown", "content": content}}


# Transformations.
MERGE = {"id": "merge", "options": {}}


def organize(exclude=(), rename=None, order=None):
    """order may use the new names; Grafana orders by the original field names."""
    rename = rename or {}
    original = {new: old for old, new in rename.items()}
    return {"id": "organize", "options": {
        "excludeByName": {k: True for k in exclude},
        "renameByName": rename,
        "indexByName": {original.get(k, k): i for i, k in enumerate(order or [])}}}


def matrix(column, row="host", value="Value", corner="Router"):
    """Pivot an instant table into rows = `row`, columns = `column`."""
    return [{"id": "groupingToMatrix", "options": {"columnField": column, "rowField": row,
                                                   "valueField": value, "emptyValue": "null"}},
            organize(rename={f"{row}\\{column}": corner})]


def hidden(*names):
    return [override(n, {"custom.hidden": True}) for n in names]


def cell(name, kind, **extra):
    return override(name, {"custom.cellOptions": {"type": kind, **extra}})


def query_var(name, label, query, *, multi=True, include_all=True, all_value=".*"):
    v = {"name": name, "label": label, "type": "query", "datasource": DS, "definition": query,
         "query": {"query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
         "refresh": 2, "multi": multi, "includeAll": include_all, "options": [], "sort": 1,
         "regex": "", "hide": 0}
    if include_all:
        v["allValue"] = all_value
        v["current"] = {"selected": True, "text": ["All"], "value": ["$__all"]}
    else:
        v["current"] = {}
    return v


class Board:
    """Places panels left to right on Grafana's 24-column grid."""

    def __init__(self):
        self.panels, self.x, self.y, self.line_h, self.next_id = [], 0, 0, 0, 1

    def _newline(self):
        self.y += self.line_h
        self.x, self.line_h = 0, 0

    def row(self, title):
        self._newline()
        self.panels.append({"type": "row", "title": title, "collapsed": False, "id": self.next_id,
                            "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y}, "panels": []})
        self.next_id += 1
        self.y += 1

    def add(self, p, w, h):
        if self.x + w > 24:
            self._newline()
        p["id"] = self.next_id
        p["gridPos"] = {"h": h, "w": w, "x": self.x, "y": self.y}
        self.next_id += 1
        self.panels.append(p)
        self.x += w
        self.line_h = max(self.line_h, h)


def dashboard(uid, title, description, board, *, tags=(), variables=(), nav_buttons=False,
              time_from="now-6h"):
    return {
        "id": None, "uid": uid, "title": title, "description": description,
        "tags": sorted(set(tags) | {"lylat"}), "editable": True, "graphTooltip": 1,
        "schemaVersion": 41, "version": 1, "refresh": "1m", "timezone": "browser",
        "fiscalYearStartMonth": 0, "weekStart": "", "liveNow": False,
        "time": {"from": time_from, "to": "now"}, "timepicker": {},
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
            "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts",
            "type": "dashboard"}]},
        "links": [{"type": "dashboards", "tags": ["lylat"], "asDropdown": not nav_buttons,
                   "title": "Dashboards", "includeVars": False, "keepTime": True,
                   "icon": "external link", "targetBlank": False, "tooltip": "", "url": ""}],
        "templating": {"list": list(variables)},
        "panels": board.panels,
    }


# Shared queries.
def targets_by_job_table():
    return table("Targets by job", [
        q("sum by (job) (up)", table=True),
        q("count by (job) (up)", table=True),
        q("count by (job) (up == 0) or sum by (job) (up) * 0", table=True),
    ], desc="Scrape targets per job. Down targets are mostly hosts that don't run an exporter yet.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "job": "Job", "Value #A": "Up", "Value #B": "Total", "Value #C": "Down"})],
        overrides=[cell("Down", "color-background"), override("Down", {"thresholds": RED_IF_ANY})],
        sort="Down", desc_sort=True)


def bgp_summary(selector):
    return stat("BGP sessions", [
        q(f"count(frr_bgp_peer_state{selector} == 1) or vector(0)", "Established"),
        q(f"count(frr_bgp_peer_state{selector}) or vector(0)", "Total"),
        q(f"count(frr_bgp_peer_state{selector} != 1) or vector(0)", "Not established"),
    ], text_mode="value_and_name", color_mode="value",
        desc="BGP sessions reported by frr_exporter (underlay IPv6 unicast, EVPN to the spines, "
             "external peerings). A router whose exporter is down drops out of the total.",
        overrides=[fixed_color("Established", "green"), fixed_color("Total", "text"),
                   override("Not established", {"thresholds": RED_IF_ANY})],
        links=[("FRR / EVPN fabric", FRR_DASH + "?${__url_time_range}")])


def bfd_summary(selector):
    return stat("BFD peers", [
        q(f"count(frr_bfd_peer_state{selector} == 1) or vector(0)", "Up"),
        q(f"count(frr_bfd_peer_state{selector}) or vector(0)", "Total"),
        q(f"count(frr_bfd_peer_state{selector} != 1) or vector(0)", "Down"),
    ], text_mode="value_and_name", color_mode="value",
        desc="BFD sessions reported by frr_exporter.",
        overrides=[fixed_color("Up", "green"), fixed_color("Total", "text"),
                   override("Down", {"thresholds": RED_IF_ANY})],
        links=[("FRR / EVPN fabric", FRR_DASH + "?${__url_time_range}")])


def probe(expr):
    """Adds a `probe` label (icmp, http_2xx, dns_soa) from the job name."""
    return f'label_replace({expr}, "probe", "$1", "job", "blackbox-(.*)")'


# --- Overview ------------------------------------------------------------------

def overview():
    b = Board()
    b.row("Status")
    b.add(stat("Targets up", [q("sum(up)")], color_mode="value", thresholds=GREEN,
               desc="Scrape targets answering, across every job.",
               links=[("Monitoring stack", STACK_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(stat("Targets down", [q("count(up == 0) or vector(0)")], thresholds=RED_IF_ANY,
               desc="Scrape targets not answering. DNS VMs and Proxmox nodes have no exporter yet and "
                    "fw-wan isn't managed by this repo, so they count here.",
               links=[("Monitoring stack", STACK_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(stat("Firing alerts", [q('count(ALERTS{alertstate="firing"}) or vector(0)')],
               thresholds=ORANGE_IF_ANY, desc="Prometheus alerts in state firing."), 3, 5)
    b.add(stat("Probes failing", [q("count(probe_success == 0) or vector(0)")], thresholds=RED_IF_ANY,
               desc="Blackbox probes (ICMP, HTTP, DNS SOA) currently failing.",
               links=[("Probes", PROBES_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(bgp_summary(""), 6, 5)
    b.add(bfd_summary(""), 6, 5)

    b.row("Targets and alerts")
    b.add(targets_by_job_table(), 7, 10)
    b.add(table("Targets", [q("max without () (up)", table=True)],
                desc="Every scrape target, down ones first.",
                transformations=[organize(exclude=["Time"], rename={
                    "job": "Job", "host": "Host", "role": "Role", "instance": "Instance", "Value": "State"},
                    order=["Job", "Host", "Role", "Instance", "State"])],
                mappings=UP_MAP, overrides=[cell("State", "color-background")], sort="State"), 9, 10)
    b.add(table("Firing alerts", [q('max without () (ALERTS{alertstate="firing"})', table=True)],
                desc="Alertmanager routes to a null receiver for now, so these are only visible here.",
                no_value="No firing alerts",
                transformations=[organize(exclude=["Time", "Value", "alertstate", "role"], rename={
                    "alertname": "Alert", "severity": "Severity", "job": "Job", "host": "Host",
                    "instance": "Instance"}, order=["Alert", "Severity", "Job", "Host", "Instance"])]),
          8, 10)

    b.row("Probes and fabric")
    b.add(stat("Probe status", [q(probe("probe_success"), "{{host}} · {{probe}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS, desc="Last result of each blackbox probe.",
               links=[("Probes", PROBES_DASH + "?${__url_time_range}")]), 10, 8)
    b.add(timeseries("BGP sessions and BFD peers up", [
        q("count(frr_bgp_peer_state == 1)", "BGP established"),
        q("count(frr_bfd_peer_state == 1)", "BFD up"),
    ], step=True, fill=0, calcs=("min", "lastNotNull"), decimals=0,
        desc="Fabric-wide; a dip is a flap.",
        links=[("FRR / EVPN fabric", FRR_DASH + "?${__url_time_range}")]), 7, 8)
    b.add(stat("EVPN", [
        q('max(frr_bgp_l2vpn_evpn_remote_vtep_count_total{type="L2"})', "Remote VTEPs"),
        q('max(sum by (host) (frr_bgp_l2vpn_evpn_mac_count_total{type="L2"}))', "MACs"),
        q('max(sum by (host) (frr_bgp_l2vpn_evpn_arp_nd_count_total{type="L2"}))', "ARP/ND"),
        q('max(frr_bgp_rib_count_total{afi="l2vpn"})', "EVPN routes"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE,
        desc="Largest value on any router: remote VTEPs of the busiest L2 VNI, EVPN MAC and ARP/ND "
             "entries over all L2 VNIs, and EVPN routes in the BGP RIB.",
        links=[("FRR / EVPN fabric", FRR_DASH + "?${__url_time_range}")]), 7, 8)

    b.row("Hosts and routers")
    sel = NODE_JOBS
    b.add(table("Hosts and routers", [
        q(f"max without () (up{{{sel}}})", table=True),
        q(f'100 * (1 - avg by (job, host, role, instance) (rate(node_cpu_seconds_total{{mode="idle", {sel}}}[5m])))',
          table=True),
        q(f"100 * (1 - node_memory_MemAvailable_bytes{{{sel}}} / node_memory_MemTotal_bytes{{{sel}}})", table=True),
        q(f'max by (job, host, role, instance) (100 * (1 - node_filesystem_avail_bytes{{mountpoint=~"/|/usr/lib/live/mount/persistence", {sel}}} '
          f'/ node_filesystem_size_bytes{{mountpoint=~"/|/usr/lib/live/mount/persistence", {sel}}}))', table=True),
        q(f'node_load5{{{sel}}} / on (job, host, role, instance) count by (job, host, role, instance) (node_cpu_seconds_total{{mode="idle", {sel}}})',
          table=True),
        q(f"100 * node_nf_conntrack_entries{{{sel}}} / node_nf_conntrack_entries_limit{{{sel}}}", table=True),
        q(f"time() - node_boot_time_seconds{{{sel}}}", table=True),
    ], desc="node_exporter on the hosts (job node) and VyOS routers (job vyos-node). Click a host for "
            "Node Exporter Full. Disk is / (on VyOS, the persistence partition: the overlay root isn't "
            "reported). Down targets have no exporter yet.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Host", "role": "Role", "Value #A": "State", "Value #B": "CPU",
            "Value #C": "Memory", "Value #D": "Disk", "Value #E": "Load 5m / CPU",
            "Value #F": "Conntrack", "Value #G": "Uptime"},
            order=["Host", "Role", "job", "instance", "State", "CPU", "Memory", "Disk",
                   "Load 5m / CPU", "Conntrack", "Uptime"])],
        overrides=hidden("job", "instance") + [
            cell("State", "color-background"), override("State", {"mappings": UP_MAP}),
            *[override(n, {"unit": "percent", "min": 0, "max": 100, "decimals": 1, "thresholds": PERCENT,
                           "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}})
              for n in ("CPU", "Memory", "Disk", "Conntrack")],
            override("Load 5m / CPU", {"decimals": 2, "thresholds": steps(("green", None), ("orange", 0.8), ("red", 1.5)),
                                       "custom.cellOptions": {"type": "color-text"}}),
            override("Uptime", {"unit": "dtdurations"}),
            override("Host", {"links": [{"title": "Node Exporter Full",
                                         "url": NODE_DASH + "?var-job=${__data.fields.job}&var-node=${__data.fields.instance}&${__url_time_range}"}]}),
        ], sort="State", desc_sort=True), 24, 14)

    b.row("Traffic")
    b.add(timeseries("Top 10 host/router interfaces (rx + tx)", [
        q('topk(10, sum by (host, device) (rate(node_network_receive_bytes_total{device=~"eth[0-9]+"}[$__rate_interval]) '
          '+ rate(node_network_transmit_bytes_total{device=~"eth[0-9]+"}[$__rate_interval])) * 8)', "{{host}} {{device}}"),
    ], unit="bps", desc="Physical (eth*) interfaces from node_exporter.", calcs=("mean", "max")), 12, 9)
    b.add(timeseries("Top 10 switch ports (rx + tx)", [
        q("topk(10, (rate(ifHCInOctets[$__rate_interval]) + rate(ifHCOutOctets[$__rate_interval])) * 8)",
          "{{host}} {{ifName}}"),
    ], unit="bps", desc="SNMP if_mib counters from the switches and WLCs.", calcs=("mean", "max"),
        links=[("SNMP Device Summary", SNMP_DASH + "?${__url_time_range}")]), 12, 9)

    return dashboard("lylat-overview", "lylat.space overview",
                     "Landing page: target and alert status, probes, the EVPN fabric, hosts and top talkers.",
                     b, tags=["overview"], nav_buttons=True, time_from="now-3h")


# --- FRR / EVPN fabric ---------------------------------------------------------

def frr():
    h = 'host=~"$host"'
    b = Board()
    b.row("Summary")
    b.add(bgp_summary("{" + h + "}"), 6, 5)
    b.add(bfd_summary("{" + h + "}"), 6, 5)
    b.add(stat("Flaps in range", [
        q(f"sum(resets(frr_bgp_peer_uptime_seconds{{{h}}}[$__range])) or vector(0)", "BGP"),
        q(f"sum(resets(frr_bfd_peer_uptime{{{h}}}[$__range])) or vector(0)", "BFD"),
    ], text_mode="value_and_name", thresholds=ORANGE_IF_ANY,
        desc="Session restarts in the selected time range (drops in the session uptime)."), 4, 5)
    b.add(stat("Youngest BGP session", [q(f"min(frr_bgp_peer_uptime_seconds{{{h}}})")], unit="dtdurations",
               color_mode="value", thresholds=steps(("orange", None), ("green", 3600)),
               desc="Lowest session uptime; orange if a session came up within the last hour."), 4, 5)
    b.add(stat("Exporter problems", [
        q(f'count(up{{job="vyos-frr", {h}}} == 0) or vector(0)', "Targets down"),
        q(f"count(frr_collector_up{{{h}}} == 0) or vector(0)", "Collectors failing"),
    ], text_mode="value_and_name", thresholds=RED_IF_ANY,
        desc="frr_exporter targets that don't answer (fw-wan has no exporter) and collectors that failed."), 4, 5)

    b.row("BGP sessions")
    lbl = "max without (instance, job, role)"
    b.add(table("BGP peers", [
        q(f"{lbl} (frr_bgp_peer_state{{{h}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_uptime_seconds{{{h}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_prefixes_received_count_total{{{h}}})", table=True),
        q(f"{lbl} (frr_bgp_peer_prefixes_advertised_count_total{{{h}}})", table=True),
        q(f"{lbl} (rate(frr_bgp_peer_message_received_total{{{h}}}[5m]))", table=True),
        q(f"{lbl} (rate(frr_bgp_peer_message_sent_total{{{h}}}[5m]))", table=True),
    ], desc="One row per session. Underlay sessions use interface peers (eth1/eth2, BGP unnumbered); "
            "EVPN sessions go to the spines' loopbacks. peer_hostname is only filled in where FRR "
            "learns it from the peer (external sessions).",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Router", "vrf": "VRF", "afi": "AFI", "safi": "SAFI", "peer": "Peer",
            "peer_hostname": "Peer hostname", "peer_as": "Peer AS", "local_as": "Local AS",
            "Value #A": "State", "Value #B": "Uptime", "Value #C": "Prefixes rx", "Value #D": "Prefixes tx",
            "Value #E": "Msgs rx/s", "Value #F": "Msgs tx/s"},
            order=["Router", "VRF", "AFI", "SAFI", "Peer", "Peer hostname", "Peer AS", "Local AS", "State",
                   "Uptime", "Prefixes rx", "Prefixes tx", "Msgs rx/s", "Msgs tx/s"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": BGP_MAP}),
                   override("Uptime", {"unit": "dtdurations"}),
                   override("Msgs rx/s|Msgs tx/s", {"decimals": 2}, regex=True)],
        sort="Router"), 24, 12)
    b.add(state_timeline("BGP session state", [
        q(f"max without (instance, job, role, local_as, peer_as, peer_hostname) (frr_bgp_peer_state{{{h}}})",
          "{{host}} {{peer}} {{afi}}/{{safi}} {{vrf}}"),
    ], mappings=BGP_MAP, thresholds=steps(("red", None), ("green", 1), ("orange", 2)),
        desc="Gaps mean the router's exporter wasn't scraped."), 24, 14)
    b.add(timeseries("Established sessions per router", [
        q(f"count by (host) (frr_bgp_peer_state{{{h}}} == 1)", "{{host}}"),
    ], step=True, fill=0, decimals=0, calcs=("min", "lastNotNull")), 8, 9)
    b.add(table("Flaps per session in range", [
        q(f"sum by (host, vrf, afi, safi, peer) (resets(frr_bgp_peer_uptime_seconds{{{h}}}[$__range])) > 0", table=True),
    ], no_value="No BGP flaps in range", transformations=[organize(exclude=["Time"], rename={
        "host": "Router", "vrf": "VRF", "afi": "AFI", "safi": "SAFI", "peer": "Peer", "Value": "Flaps"})],
        sort="Flaps", desc_sort=True), 8, 9)
    b.add(timeseries("BGP messages per router (rx + tx)", [
        q(f"sum by (host) (rate(frr_bgp_peer_message_received_total{{{h}}}[$__rate_interval]) "
          f"+ rate(frr_bgp_peer_message_sent_total{{{h}}}[$__rate_interval]))", "{{host}}"),
    ], unit="short", desc="Messages per second (updates and keepalives)."), 8, 9)
    b.add(timeseries("Prefixes received", [
        q(f"sum by (host, afi, safi) (frr_bgp_peer_prefixes_received_count_total{{{h}}})", "{{host}} {{afi}}/{{safi}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull")), 12, 9)
    b.add(timeseries("Prefixes advertised", [
        q(f"sum by (host, afi, safi) (frr_bgp_peer_prefixes_advertised_count_total{{{h}}})", "{{host}} {{afi}}/{{safi}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull")), 12, 9)

    b.row("BFD")
    b.add(table("BFD peers", [
        q(f"max without (instance, job, role) (frr_bfd_peer_state{{{h}}})", table=True),
        q(f"max without (instance, job, role) (frr_bfd_peer_uptime{{{h}}})", table=True),
    ], desc="Link-local peers are the underlay links to the spines; fd69:255:240::1/::2 are the spine loopbacks (EVPN).",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Router", "local": "Local", "peer": "Peer", "Value #A": "State", "Value #B": "Uptime"},
            order=["Router", "Local", "Peer", "State", "Uptime"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": BFD_MAP}),
                   override("Uptime", {"unit": "dtdurations"})], sort="Router"), 10, 11)
    b.add(bargauge("BFD peers up per router", [
        q(f"sum by (host) (frr_bfd_peer_state{{{h}}}) / max by (host) (frr_bfd_peer_count{{{h}}})", "{{host}}"),
    ], unit="percentunit", min_=0, max_=1, thresholds=steps(("red", None), ("orange", 0.01), ("green", 1)),
        desc="Up / configured BFD peers. Routers without BFD peers (DHCP VMs) are left out."), 6, 11)
    b.add(timeseries("BFD peers up", [
        q(f"sum by (host) (frr_bfd_peer_state{{{h}}})", "{{host}}"),
    ], step=True, fill=0, decimals=0, calcs=("min", "lastNotNull")), 8, 11)

    b.row("EVPN")
    l2 = f'type="L2", {h}'
    b.add(timeseries("Remote VTEPs per router", [
        q(f"max by (host) (frr_bgp_l2vpn_evpn_remote_vtep_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "lastNotNull"),
        desc="Remote VTEPs of the router's busiest L2 VNI."), 8, 8)
    b.add(timeseries("EVPN MACs per router", [
        q(f"sum by (host) (frr_bgp_l2vpn_evpn_mac_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), desc="MAC entries over all L2 VNIs (local and remote)."), 8, 8)
    b.add(timeseries("EVPN ARP/ND entries per router", [
        q(f"sum by (host) (frr_bgp_l2vpn_evpn_arp_nd_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), desc="ARP/ND (MAC+IP) entries over all L2 VNIs."), 8, 8)

    def per_vni(metric):
        # Column "lan/9009": tenant VRF without the lylat_ prefix, then the VNI.
        return (f'max without (instance, job, role, vxlanIf) (label_join(label_replace({metric}{{{l2}}}, '
                f'"t", "$1", "tenantVrf", "(?:lylat_)?(.*)"), "segment", "/", "t", "vni"))')

    b.add(table("Remote VTEPs per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_remote_vtep_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI. A 0 means no other leaf has this VNI.",
                transformations=matrix("segment"), thresholds=steps(("red", None), ("green", 1)),
                overrides=[override("/", {"custom.cellOptions": {"type": "color-text"}}, regex=True)],
                sort="Router"), 12, 10)
    b.add(table("EVPN MACs per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_mac_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI.", transformations=matrix("segment"), sort="Router"), 12, 10)
    b.add(table("ARP/ND entries per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_arp_nd_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI.", transformations=matrix("segment"), sort="Router"), 12, 10)
    b.add(bargauge("EVPN MACs and ARP/ND per tenant VRF", [
        q(f"max by (tenantVrf) (sum by (host, tenantVrf) (frr_bgp_l2vpn_evpn_mac_count_total{{{l2}}}))", "{{tenantVrf}} MACs"),
        q(f"max by (tenantVrf) (sum by (host, tenantVrf) (frr_bgp_l2vpn_evpn_arp_nd_count_total{{{l2}}}))", "{{tenantVrf}} ARP/ND"),
    ], thresholds=BLUE, decimals=0, desc="Largest count on any router (each leaf sees the whole EVPN table)."), 12, 10)

    b.row("Routes")
    rv = f'{h}, vrf=~"$vrf"'
    b.add(table("Routes per VRF", [
        q(f'max without (instance, job, role) (label_join(frr_route_total{{{rv}}}, "segment", " ", "vrf", "afi"))', table=True),
    ], desc="Zebra RIB routes per VRF and address family.", transformations=matrix("segment"), sort="Router"), 24, 10)
    b.add(timeseries("Routes per VRF (largest on any router)", [
        q(f"max by (vrf, afi) (frr_route_total{{{rv}}})", "{{vrf}} {{afi}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull")), 8, 9)
    b.add(timeseries("RIB routes not in the FIB", [
        q(f"sum by (host) (frr_route_total{{{rv}}}) - sum by (host) (frr_route_total_fib{{{rv}}})", "{{host}}"),
    ], decimals=0, fill=0, calcs=("max", "lastNotNull"),
        desc="Zebra routes that aren't installed in the kernel (normally 0)."), 8, 9)
    b.add(timeseries("BGP RIB entries", [
        q(f"max without (instance, job, role, local_as) (frr_bgp_rib_count_total{{{h}}})", "{{host}} {{afi}}/{{safi}} {{vrf}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull")), 8, 9)

    b.row("Exporter")
    b.add(table("frr_exporter collectors", [q(f"max without (instance, job, role) (frr_collector_up{{{h}}})", table=True)],
                transformations=matrix("collector"), mappings=UP_MAP, thresholds=UP_STEPS,
                overrides=[override("^(?!Router$).*", {"custom.cellOptions": {"type": "color-background"}}, regex=True)],
                sort="Router"), 12, 9)
    b.add(timeseries("frr_exporter scrape duration", [
        q(f"sum by (host) (frr_scrape_duration_seconds{{{h}}})", "{{host}}"),
    ], unit="s", fill=0), 12, 9)

    variables = [
        query_var("host", "Router", "label_values(frr_collector_up, host)"),
        query_var("vrf", "VRF", 'label_values(frr_route_total{host=~"$host"}, vrf)'),
    ]
    return dashboard("frr-evpn-fabric", "FRR / EVPN fabric",
                     "frr_exporter on the VyOS leaves and DHCP VMs: BGP, BFD, EVPN and routes.",
                     b, tags=["frr", "bgp", "evpn"], variables=variables)


# --- Probes --------------------------------------------------------------------

def probes():
    s = 'job=~"$job", host=~"$host"'
    b = Board()
    b.row("Status")
    b.add(stat("Probe status", [q(probe(f"probe_success{{{s}}}"), "{{host}} · {{probe}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS), 24, 4)
    lr = "max without () ({})"
    b.add(table("Probes", [
        q(lr.format(probe(f"probe_success{{{s}}}")), table=True),
        q(lr.format(probe(f"avg_over_time(probe_success{{{s}}}[$__range])")), table=True),
        q(lr.format(probe(f"probe_duration_seconds{{{s}}}")), table=True),
        q(lr.format(probe(f"probe_http_status_code{{{s}}}")), table=True),
        q("max without (phase) ({})".format(probe(f'probe_icmp_duration_seconds{{phase="rtt", {s}}}')), table=True),
        q(lr.format(probe(f"probe_dns_serial{{{s}}}")), table=True),
    ], desc="Availability is the share of successful probes in the selected time range. Target is the "
            "address or URL the blackbox exporter probes.",
        transformations=[MERGE, organize(exclude=["Time", "job"], rename={
            "host": "Name", "probe": "Probe", "instance": "Target", "Value #A": "State",
            "Value #B": "Availability", "Value #C": "Duration", "Value #D": "HTTP status",
            "Value #E": "ICMP RTT", "Value #F": "SOA serial"},
            order=["Name", "Probe", "Target", "State", "Availability", "Duration", "HTTP status", "ICMP RTT",
                   "SOA serial"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": UP_MAP, "thresholds": UP_STEPS}),
                   override("Availability", {"unit": "percentunit", "decimals": 3,
                                             "thresholds": steps(("red", None), ("orange", 0.99), ("green", 0.999)),
                                             "custom.cellOptions": {"type": "color-text"}}),
                   override("Duration", {"unit": "s"}), override("ICMP RTT", {"unit": "s"})],
        sort="Probe"), 24, 7)
    b.add(state_timeline("Probe success", [q(probe(f"probe_success{{{s}}}"), "{{host}} · {{probe}}")],
                         mappings=UP_MAP, thresholds=UP_STEPS), 12, 8)
    b.add(timeseries("Probe duration", [q(probe(f"probe_duration_seconds{{{s}}}"), "{{host}} · {{probe}}")],
                     unit="s", fill=0, desc="Whole probe, as measured by the blackbox exporter."), 12, 8)

    b.row("ICMP")
    b.add(timeseries("ICMP round-trip time", [
        q(f'probe_icmp_duration_seconds{{phase="rtt", {s}}}', "{{host}}")], unit="s", fill=0), 12, 8)
    b.add(stat("Reply hop limit", [q(f"probe_icmp_reply_hop_limit{{{s}}}", "{{host}}")], text_mode="value_and_name",
               color_mode="value", thresholds=BLUE,
               desc="TTL / hop limit of the reply. 64 minus this is the number of routed hops for Linux hosts."), 6, 8)
    b.add(stat("IP protocol", [q(f'probe_ip_protocol{{job="blackbox-icmp", host=~"$host"}}', "{{host}}")],
               text_mode="value_and_name", color_mode="value", thresholds=BLUE,
               desc="Address family the ICMP probe used (4 or 6)."), 6, 8)

    b.row("HTTP")
    b.add(stat("HTTP status", [q(f"probe_http_status_code{{{s}}}", "{{host}}")], text_mode="value_and_name",
               thresholds=steps(("red", None), ("green", 200), ("orange", 300), ("red", 400))), 6, 8)
    b.add(timeseries("HTTP phases", [
        q(f'probe_http_duration_seconds{{phase!="tls", {s}}}', "{{host}} {{phase}}"),
    ], unit="s", fill=0, desc="resolve, connect, processing (time to first byte) and transfer. The targets "
                              "are plain HTTP, so the tls phase is left out."), 12, 8)
    b.add(stat("HTTP details", [
        q(f"probe_http_version{{{s}}}", "{{host}} version"),
        q(f"probe_http_redirects{{{s}}}", "{{host}} redirects"),
        q(f"probe_http_ssl{{{s}}}", "{{host}} TLS"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE), 6, 8)
    b.add(timeseries("HTTP response size", [
        q(f"probe_http_content_length{{{s}}}", "{{host}} content-length"),
        q(f"probe_http_uncompressed_body_length{{{s}}}", "{{host}} body"),
    ], unit="decbytes", fill=0, desc="content-length is -1 when the server doesn't send the header."), 12, 7)
    b.add(timeseries("Total HTTP time", [
        q(f'sum by (host) (probe_http_duration_seconds{{phase!="tls", {s}}})', "{{host}}"),
    ], unit="s", fill=0), 12, 7)

    b.row("DNS")
    b.add(timeseries("DNS query time", [
        q(f'probe_dns_duration_seconds{{phase="request", {s}}}', "{{host}}"),
    ], unit="s", fill=0, desc="Time for the SOA lylat.space query (request phase)."), 8, 8)
    b.add(stat("SOA serial", [
        q(f"probe_dns_serial{{{s}}}", "{{host}}"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE, decimals=0), 4, 8)
    b.add(stat("Serial drift", [
        q(f"(max(probe_dns_serial{{{s}}}) - min(probe_dns_serial{{{s}}})) or vector(0)"),
    ], thresholds=RED_IF_ANY, desc="Difference between the highest and lowest SOA serial; non-zero means a secondary is behind."), 4, 8)
    b.add(stat("Records in answer", [
        q(f"probe_dns_answer_rrs{{{s}}}", "{{host}} answer"),
        q(f"probe_dns_authority_rrs{{{s}}}", "{{host}} authority"),
        q(f"probe_dns_additional_rrs{{{s}}}", "{{host}} additional"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE), 8, 8)
    b.add(timeseries("DNS phases", [
        q(f"probe_dns_duration_seconds{{{s}}}", "{{host}} {{phase}}"),
    ], unit="s", fill=0), 12, 8)
    b.add(timeseries("Target name resolution", [
        q(probe(f"probe_dns_lookup_time_seconds{{{s}}}"), "{{host}} · {{probe}}"),
    ], unit="s", fill=0, desc="Time the blackbox exporter spends resolving the target's name. Targets are IPs, "
                              "so it's near zero."), 12, 8)

    variables = [
        query_var("job", "Probe", "label_values(probe_success, job)"),
        query_var("host", "Target", 'label_values(probe_success{job=~"$job"}, host)'),
    ]
    return dashboard("blackbox-probes", "Blackbox probes",
                     "Blackbox exporter ICMP, HTTP and DNS SOA probes: status, availability and timings.",
                     b, tags=["blackbox", "probes"], variables=variables)


# --- Monitoring stack ----------------------------------------------------------

def stack():
    b = Board()
    b.row("Components")
    b.add(stat("Component status", [q(f"up{{{STACK_JOBS}}}", "{{job}} {{host}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS), 10, 7)
    b.add(stat("Config reloads", [
        q("prometheus_config_last_reload_successful", "Prometheus"),
        q("alertmanager_config_last_reload_successful", "Alertmanager"),
        q("blackbox_exporter_config_last_reload_successful", "Blackbox"),
    ], text_mode="value_and_name", mappings=OK_MAP, thresholds=UP_STEPS), 4, 7)
    versions = " or ".join(
        # frr_exporter on VyOS doesn't report a version.
        f'label_replace(label_replace(count by (version) ({metric}_build_info), "version", "not reported", "version", ""), '
        f'"component", "{name}", "", "")'
        for name, metric in (("Prometheus", "prometheus"), ("Alertmanager", "alertmanager"), ("Grafana", "grafana"),
                             ("blackbox_exporter", "blackbox_exporter"), ("snmp_exporter", "snmp_exporter"),
                             ("node_exporter", "node_exporter"), ("frr_exporter", "frr_exporter")))
    b.add(table("Versions", [q(versions, table=True)],
                transformations=[organize(exclude=["Time"], rename={
                    "component": "Component", "version": "Version", "Value": "Instances"},
                    order=["Component", "Version", "Instances"])], sort="Component"), 10, 7)

    b.row("Prometheus")
    b.add(stat("Head series", [q("prometheus_tsdb_head_series")], color_mode="value", graph=True, thresholds=BLUE), 4, 5)
    b.add(stat("Samples / s", [q("sum(rate(prometheus_tsdb_head_samples_appended_total[$__rate_interval]))")],
               color_mode="value", graph=True, thresholds=BLUE, decimals=0), 4, 5)
    b.add(stat("TSDB size", [q("prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes "
                                "+ prometheus_tsdb_head_chunks_storage_size_bytes")],
               unit="bytes", color_mode="value", graph=True, thresholds=BLUE,
               desc="Blocks + WAL + head chunks. Retention is capped by time and size in monitoring-config."), 4, 5)
    b.add(stat("mon01 disk free", [
        q('100 * node_filesystem_avail_bytes{host="mon01", mountpoint="/"} / node_filesystem_size_bytes{host="mon01", mountpoint="/"}')],
        unit="percent", decimals=1, color_mode="value", thresholds=steps(("red", None), ("orange", 10), ("green", 25)),
        desc="Free space on the backend VM's root filesystem, where the Prometheus data lives."), 4, 5)
    b.add(stat("Rule evaluation failures", [
        q("sum(increase(prometheus_rule_evaluation_failures_total[$__range])) or vector(0)")],
        thresholds=RED_IF_ANY, decimals=0, desc="In the selected time range."), 4, 5)
    b.add(stat("Notifications dropped / errors", [
        q("(sum(increase(prometheus_notifications_dropped_total[$__range])) + "
          "sum(increase(prometheus_notifications_errors_total[$__range]))) or vector(0)")],
        thresholds=RED_IF_ANY, decimals=0, desc="Alerts Prometheus failed to deliver to Alertmanager in the selected range."), 4, 5)
    b.add(targets_by_job_table(), 8, 10)
    b.add(timeseries("Scrape duration by job (slowest target)", [
        q("max by (job) (scrape_duration_seconds)", "{{job}}")], unit="s", fill=0, calcs=("mean", "max")), 8, 10)
    b.add(timeseries("Samples scraped by job", [
        q("sum by (job) (scrape_samples_scraped)", "{{job}}")], fill=0, stack=False, calcs=("mean", "lastNotNull")), 8, 10)
    b.add(timeseries("Head series and chunks", [
        q("prometheus_tsdb_head_series", "series"), q("prometheus_tsdb_head_chunks", "chunks")], fill=0), 8, 8)
    b.add(timeseries("Storage", [
        q("prometheus_tsdb_storage_blocks_bytes", "blocks"), q("prometheus_tsdb_wal_storage_size_bytes", "WAL"),
        q("prometheus_tsdb_head_chunks_storage_size_bytes", "head chunks")], unit="bytes", stack=True), 8, 8)
    b.add(timeseries("Ingestion rate", [
        q("sum(rate(prometheus_tsdb_head_samples_appended_total[$__rate_interval]))", "samples/s")], fill=10), 8, 8)
    b.add(timeseries("Rule group evaluation", [
        q("prometheus_rule_group_last_duration_seconds", "{{rule_group}} duration"),
        q("prometheus_rule_group_interval_seconds", "{{rule_group}} interval"),
    ], unit="s", fill=0, desc="A group whose duration nears its interval misses evaluations."), 8, 8)
    b.add(timeseries("Query duration (p90)", [
        q('prometheus_engine_query_duration_seconds{quantile="0.9"}', "{{slice}}")], unit="s", fill=0), 8, 8)
    b.add(timeseries("Scrape interval (p99)", [
        q('prometheus_target_interval_length_seconds{quantile="0.99"}', "{{interval}}")], unit="s", fill=0,
        desc="Actual time between scrapes; should track the configured interval."), 8, 8)

    b.row("Alertmanager")
    b.add(stat("Alerts", [q("alertmanager_alerts", "{{state}}")], text_mode="value_and_name", color_mode="value",
               thresholds=BLUE), 4, 7)
    b.add(stat("Silences", [q("alertmanager_silences", "{{state}}")], text_mode="value_and_name", color_mode="value",
               thresholds=BLUE), 4, 7)
    b.add(timeseries("Alerts received", [
        q("sum by (status) (rate(alertmanager_alerts_received_total[$__rate_interval]))", "{{status}}")], fill=0,
        desc="Per second, from Prometheus."), 8, 7)
    b.add(timeseries("Notifications by integration", [
        q("sum by (integration) (rate(alertmanager_notifications_total[$__rate_interval])) > 0", "{{integration}} sent"),
        q("sum by (integration) (rate(alertmanager_notifications_failed_total[$__rate_interval])) > 0", "{{integration}} failed"),
        q("sum(rate(alertmanager_notifications_total[$__rate_interval]))", "all integrations"),
    ], fill=0, desc="Everything routes to the null receiver for now, so this stays at 0."), 8, 7)
    b.add(timeseries("Prometheus → Alertmanager", [
        q("rate(prometheus_notifications_sent_total[$__rate_interval])", "sent/s"),
        q("rate(prometheus_notifications_errors_total[$__rate_interval])", "errors/s"),
        q("rate(prometheus_notifications_dropped_total[$__rate_interval])", "dropped/s"),
        q("prometheus_notifications_queue_length", "queue length"),
    ], fill=0), 12, 8)
    b.add(timeseries("Firing alerts by name", [
        q('count by (alertname) (ALERTS{alertstate="firing"})', "{{alertname}}")], fill=10, stack=True, decimals=0), 12, 8)

    b.row("Grafana")
    b.add(stat("Grafana", [
        q("max(grafana_stat_totals_dashboard)", "Dashboards"), q("max(grafana_stat_total_users)", "Users"),
        q("max(grafana_stat_active_users)", "Active users"), q("max(grafana_stat_totals_alert_rules)", "Alert rules"),
        q("max(grafana_stat_totals_datasource)", "Datasources"),
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE,
        desc="Both Grafanas share one Postgres database, so these are the same on each."), 8, 8)
    b.add(timeseries("HTTP requests by status", [
        q("sum by (host, status_code) (rate(grafana_http_request_duration_seconds_count[$__rate_interval]))",
          "{{host}} {{status_code}}")], unit="reqps", fill=0), 8, 8)
    b.add(timeseries("HTTP latency (p95)", [
        q("histogram_quantile(0.95, sum by (host, le) (rate(grafana_http_request_duration_seconds_bucket[$__rate_interval])))",
          "{{host}}")], unit="s", fill=0), 8, 8)
    b.add(timeseries("Datasource requests", [
        q("sum by (host, datasource_type) (rate(grafana_datasource_request_duration_seconds_count[$__rate_interval]))",
          "{{host}} {{datasource_type}}")], unit="reqps", fill=0,
        desc="Queries Grafana sends to its datasources (only while someone views a dashboard)."), 8, 8)
    b.add(timeseries("Database connections", [
        q("grafana_database_conn_in_use", "{{host}} in use"), q("grafana_database_conn_open", "{{host}} open"),
    ], fill=0, decimals=0, desc="Connections to the shared Postgres on mon01."), 8, 8)
    b.add(timeseries("Grafana alerting", [
        q("grafana_alerting_active_alerts", "{{host}} active alerts"),
        q("rate(grafana_alerting_execution_time_milliseconds_count[$__rate_interval])", "{{host}} evaluations/s"),
    ], fill=0), 8, 8)

    b.row("Exporters")
    b.add(timeseries("SNMP walk duration", [
        q("max by (host, module) (snmp_scrape_duration_seconds)", "{{host}} {{module}}")], unit="s", fill=0), 8, 8)
    b.add(timeseries("SNMP retries and errors", [
        q("sum by (host) (snmp_scrape_packets_retried)", "{{host}} retries"),
        q("sum(rate(snmp_request_errors_total[$__rate_interval]))", "request errors/s"),
    ], fill=0), 8, 8)
    b.add(timeseries("node / frr exporter scrape duration", [
        q('scrape_duration_seconds{job=~"node|vyos-node|vyos-frr"}', "{{job}} {{host}}")], unit="s", fill=0,
        calcs=("mean", "max")), 8, 8)

    b.row("Resources")
    b.add(timeseries("Process memory", [
        q(f"process_resident_memory_bytes{{{STACK_JOBS}}}", "{{job}} {{host}}")], unit="bytes", fill=0), 12, 8)
    b.add(timeseries("Process CPU", [
        q(f"rate(process_cpu_seconds_total{{{STACK_JOBS}}}[$__rate_interval])", "{{job}} {{host}}")],
        unit="percentunit", fill=0, desc="CPU seconds per second (1 = one core)."), 12, 8)

    return dashboard("monitoring-stack", "Monitoring stack",
                     "Prometheus, Alertmanager, Grafana and the exporters running on mon01.",
                     b, tags=["prometheus", "alertmanager", "grafana"])


DASHBOARDS = {
    "Overview/overview.json": overview,
    "Network/frr-evpn-fabric.json": frr,
    "Probes/blackbox-probes.json": probes,
    "Monitoring/monitoring-stack.json": stack,
}


def main():
    for rel, build in DASHBOARDS.items():
        out = HERE / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        dash = build()
        out.write_text(json.dumps(dash, indent=2, ensure_ascii=False) + "\n")
        print(f"{rel}: {dash['title']} ({len([p for p in dash['panels'] if p['type'] != 'row'])} panels)")


if __name__ == "__main__":
    main()
