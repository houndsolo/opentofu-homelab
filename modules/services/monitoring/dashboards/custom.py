#!/usr/bin/env python3
"""Build the custom (non-community) dashboards as JSON.

    python3 -I modules/services/monitoring/dashboards/custom.py

The JSON files it writes are committed and provisioned like the community ones,
so edit this script and re-run it rather than editing them by hand. It needs no
network access. The Proxmox dashboards (pvestatd) are built by pve.py, the
fw-wan ones by fwwan.py, the log dashboards (Loki) by logs.py, the wireless
ones (C9800 telemetry, wlc_* series) by wireless.py and Ceph RGW buckets by rgw.py,
which this script imports. Each dashboard:

- queries the provisioned Prometheus datasource (uid "prometheus") directly;
- uses the scrape targets' "host" label for names and pickers;
- carries the "lylat" tag and a "Dashboards" dropdown listing every dashboard
  with that tag, keeping the time range; plus a "lylat-<folder>" category tag
  (theme.categorize), and the overview shows one dropdown per category instead;
- goes through theme.apply_theme() (the desktop palette) before it's written.

Down targets (no exporter yet) simply have no series, so panels count what's
there; `... or vector(0)` keeps the "down"/"failing" stats at 0 rather than
"No data".
"""
import copy
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))  # python3 -I leaves the script's directory off the path
import theme  # noqa: E402
from theme import ACCENT, ACCENT2, ACCENT3, ERROR, INFO, OK, WARN_HIGH  # noqa: E402

DS = {"type": "prometheus", "uid": "prometheus"}

NODE_JOBS = 'job=~"node|vyos-node"'
STACK_JOBS = 'job=~"prometheus|alertmanager|grafana|snmp-exporter|blackbox-exporter|telegraf|pvestatd|mimir"'
NODE_DASH = "/d/node-exporter-full/node-exporter-full"
FRR_DASH = "/d/frr-evpn-fabric/frr-evpn-fabric"
PROBES_DASH = "/d/blackbox-probes/blackbox-probes"
STACK_DASH = "/d/monitoring-stack/monitoring-stack"
SNMP_DASH = "/d/snmp-device-summary/snmp-device-summary"
CEPH_DASH = "/d/ceph-cluster/ceph-cluster"
CEPH_OSD_DASH = "/d/ceph-osd/ceph-osd"
LOGS_DASH = "/d/logs-overview/logs-overview"  # logs.py
PG_DASH = "/d/postgres-cluster/postgres-cluster"  # databases.py
VALKEY_DASH = "/d/valkey/valkey"  # databases.py
TRIAGE_DASH = "/d/dark-triage/dark-triage"  # triage.py
NGINX_DASH = "/d/nginx-proxy/nginx-reverse-proxy"  # nginx.py

# Every dashboard tagged "ceph" (these and the ceph-mixin ones from update.py) gets
# a "Ceph dashboards" dropdown.
CEPH_LINK = {"type": "dashboards", "tags": ["ceph"], "asDropdown": True, "title": "Ceph dashboards",
             "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
             "tooltip": "", "url": ""}


# --- building blocks -------------------------------------------------------

def mapping(**states):
    """Value mappings: mapping(**{"0": ("DOWN", "red"), "1": ("UP", "green")})."""
    return [{"type": "value", "options": {
        k: {"text": text, "color": color, "index": i} for i, (k, (text, color)) in enumerate(states.items())
    }}]


# Colors: palette constants from theme.py, or Grafana's names ("green", "orange", ...), which
# theme.apply_theme() maps to the palette when main() writes the dashboard.
UP_MAP = mapping(**{"0": ("DOWN", ERROR), "1": ("UP", OK)})
OK_MAP = mapping(**{"0": ("FAILED", ERROR), "1": ("OK", OK)})
# frr_exporter: 0 = Down, 1 = Established, 2 = Administratively down.
BGP_MAP = mapping(**{"0": ("Down", ERROR), "1": ("Established", OK), "2": ("Admin down", WARN_HIGH)})
BFD_MAP = mapping(**{"0": ("Down", ERROR), "1": ("Up", OK)})


def steps(*pairs):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in pairs]}


GREEN = steps((OK, None))
BLUE = steps((INFO, None))
RED_IF_ANY = steps((OK, None), (ERROR, 1))
ORANGE_IF_ANY = steps((OK, None), (WARN_HIGH, 1))
PERCENT = steps((OK, None), (WARN_HIGH, 75), (ERROR, 90))
UP_STEPS = steps((ERROR, None), (OK, 1))
# Share of a service's members that are healthy: 1 = OK, 0 = DOWN, anything between = DEGRADED.
SERVICE_MAP = [
    {"type": "value", "options": {"1": {"text": "OK", "color": OK, "index": 0},
                                  "0": {"text": "DOWN", "color": ERROR, "index": 1}}},
    {"type": "range", "options": {"from": 0.0001, "to": 0.9999,
                                  "result": {"text": "DEGRADED", "color": WARN_HIGH, "index": 2}}},
]
SERVICE_STEPS = steps((ERROR, None), (WARN_HIGH, 0.0001), (OK, 1))


def q(expr, legend="__auto", table=False, instant=False):
    """A Prometheus target. table=True makes it an instant query in table format.

    instant=True makes it an instant query (time series format) for stats that show the current state:
    with a range query, lastNotNull keeps a series that ended inside the range (an old instance's
    last up=0, a replica that was elected before a failover) as an extra, stale tile.
    """
    t = {"datasource": DS, "editorMode": "code", "expr": expr, "legendFormat": legend,
         "range": not (table or instant), "instant": table or instant}
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
    # A deep copy: the building blocks share module-level dicts (REDUCE_LAST, GREEN, ...),
    # and callers sometimes tweak a returned panel in place.
    return copy.deepcopy(p)


REDUCE_LAST = {"calcs": ["lastNotNull"], "fields": "", "values": False}


def stat(title, targets, *, color_mode="background", text_mode="auto", graph=False, orientation="auto",
         justify="auto", text_size=None, **kw):
    """text_size=(title px, value px) fixes the font sizes instead of fitting them to the tile."""
    kw.setdefault("thresholds", GREEN)
    options = {
        "reduceOptions": REDUCE_LAST, "colorMode": color_mode, "graphMode": "area" if graph else "none",
        "textMode": text_mode, "justifyMode": justify, "orientation": orientation, "wideLayout": True,
        "showPercentChange": False}
    if text_size:
        options["text"] = {"titleSize": text_size[0], "valueSize": text_size[1]}
    return panel("stat", title, targets, options=options, **kw)


def gauge(title, targets, **kw):
    return panel("gauge", title, targets, options={
        "reduceOptions": REDUCE_LAST, "showThresholdMarkers": True, "showThresholdLabels": False,
        "orientation": "auto", "minVizWidth": 75, "minVizHeight": 75, "sizing": "auto"}, **kw)


def piechart(title, targets, *, donut=True, **kw):
    kw.setdefault("color", {"mode": "palette-classic"})
    return panel("piechart", title, targets, options={
        "reduceOptions": REDUCE_LAST, "pieType": "donut" if donut else "pie",
        "displayLabels": ["percent"], "tooltip": {"mode": "single", "sort": "none"},
        "legend": {"displayMode": "table", "placement": "right", "showLegend": True, "values": ["value"]}}, **kw)


def timeseries(title, targets, *, stack=False, fill=10, calcs=("mean", "max", "lastNotNull"),
               legend="table", placement="bottom", draw="line", step=False, gradient="none", line=1,
               **kw):
    custom = {"drawStyle": draw, "lineWidth": line, "fillOpacity": fill, "showPoints": "never",
              "spanNulls": False, "lineInterpolation": "stepAfter" if step else "linear",
              "stacking": {"mode": "normal" if stack else "none", "group": "A"},
              "axisPlacement": "auto", "gradientMode": gradient}
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


def bargauge(title, targets, *, mode="basic", bar_height=None, name_placement="left", **kw):
    """bar_height fixes each bar's height (px) instead of stretching the bars to fill the panel."""
    options = {
        "displayMode": mode, "orientation": "horizontal", "reduceOptions": REDUCE_LAST, "showUnfilled": True,
        "valueMode": "color", "namePlacement": name_placement, "sizing": "manual" if bar_height else "auto",
        "minVizHeight": bar_height or 16, "minVizWidth": 8, "maxVizHeight": bar_height or 300}
    if bar_height:
        options["text"] = {"titleSize": 12, "valueSize": 14}
    return panel("bargauge", title, targets, options=options, **kw)


def state_timeline(title, targets, *, show_value="never", row_height=0.85, **kw):
    return panel("state-timeline", title, targets, custom={"fillOpacity": 80, "lineWidth": 0}, options={
        "mergeValues": True, "showValue": show_value, "alignValue": "left", "rowHeight": row_height,
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
    """Places panels left to right on Grafana's 24-column grid.

    A collapsed row keeps its panels inside the row object (Grafana's format), so
    they're only queried once someone expands it.
    """

    def __init__(self):
        self.panels, self.x, self.y, self.line_h, self.next_id = [], 0, 0, 0, 1
        self.target = self.panels

    def _newline(self):
        self.y += self.line_h
        self.x, self.line_h = 0, 0

    def row(self, title, collapsed=False):
        self._newline()
        r = {"type": "row", "title": title, "collapsed": collapsed, "id": self.next_id,
             "gridPos": {"h": 1, "w": 24, "x": 0, "y": self.y}, "panels": []}
        self.panels.append(r)
        self.target = r["panels"] if collapsed else self.panels
        self.next_id += 1
        self.y += 1

    def _place(self, p, x, y, w, h):
        p["id"] = self.next_id
        p["gridPos"] = {"h": h, "w": w, "x": x, "y": y}
        self.next_id += 1
        self.target.append(p)

    def add(self, p, w, h):
        if self.x + w > 24:
            self._newline()
        self._place(p, self.x, self.y, w, h)
        self.x += w
        self.line_h = max(self.line_h, h)

    def col(self, w, *items):
        """Stacks (panel, height) pairs on top of each other in one column."""
        if self.x + w > 24:
            self._newline()
        y = self.y
        for p, h in items:
            self._place(p, self.x, y, w, h)
            y += h
        self.x += w
        self.line_h = max(self.line_h, y - self.y)

    def grid(self, w, h, panels, per_row):
        """A block of equally sized panels, per_row to a line, inside a w-wide column."""
        cw = w // per_row
        rows = [panels[i:i + per_row] for i in range(0, len(panels), per_row)]
        if self.x + w > 24:
            self._newline()
        x0, y = self.x, self.y
        for r in rows:
            for i, p in enumerate(r):
                self._place(p, x0 + i * cw, y, cw, h)
            y += h
        self.x += w
        self.line_h = max(self.line_h, y - self.y)


def dashboard(uid, title, description, board, *, tags=(), variables=(), nav_links=None,
              time_from="now-6h", extra_links=()):
    # nav_links replaces the "Dashboards" dropdown (the overview's per-category dropdowns).
    return {
        "id": None, "uid": uid, "title": title, "description": description,
        "tags": sorted(set(tags) | {"lylat"}), "editable": True, "graphTooltip": 1,
        "schemaVersion": 41, "version": 1, "refresh": "1m", "timezone": "browser",
        "fiscalYearStartMonth": 0, "weekStart": "", "liveNow": False,
        "time": {"from": time_from, "to": "now"}, "timepicker": {},
        "annotations": {"list": [{
            "builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
            "hide": True, "iconColor": ACCENT2, "name": "Annotations & Alerts",
            "type": "dashboard"}]},
        "links": (list(nav_links) if nav_links is not None else [{
            "type": "dashboards", "tags": ["lylat"], "asDropdown": True,
            "title": "Dashboards", "includeVars": False, "keepTime": True,
            "icon": "external link", "targetBlank": False, "tooltip": "", "url": ""}])
                 + [dict(link) for link in extra_links],
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
    import databases  # the other builders import their helpers from this module; main() makes that possible
    import fwwan
    import logs
    import nginx
    import pve
    b = Board()
    b.row("Status")
    b.add(stat("Targets up", [q("sum(up)")], color_mode="value", thresholds=GREEN,
               desc="Scrape targets answering, across every job.",
               links=[("Monitoring stack", STACK_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(stat("Targets down", [q("count(up == 0) or vector(0)")], thresholds=RED_IF_ANY,
               desc="Scrape targets not answering. The table under Targets and alerts lists them.",
               links=[("Monitoring stack", STACK_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(stat("Firing alerts", [q('count(ALERTS{alertstate="firing"}) or vector(0)')],
               thresholds=ORANGE_IF_ANY, desc="Prometheus alerts in state firing (listed under Targets and alerts)."),
          3, 5)
    b.add(stat("Probes failing", [q("count(probe_success == 0) or vector(0)")], thresholds=RED_IF_ANY,
               desc="Blackbox probes (ICMP, HTTP, HTTPS, DNS SOA) currently failing.",
               links=[("Probes", PROBES_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(bgp_summary(""), 6, 5)
    b.add(bfd_summary(""), 6, 5)

    b.row("Services")
    services = [
        # (tile, healthy fraction 0..1, dashboard)
        ("Grafana", 'avg(up{job="grafana"})', STACK_DASH),
        ("Prometheus", 'avg(up{job="prometheus"})', STACK_DASH),
        ("Alertmanager", 'avg(up{job="alertmanager"})', STACK_DASH),
        ("Mimir", 'avg(up{job="mimir"})', STACK_DASH),
        ("Loki", 'avg(up{job="loki"})', STACK_DASH),
        ("Alloy (logs)", 'avg(up{job="alloy"})', STACK_DASH),
        ("Postgres", 'avg(up{job="patroni"}) * (sum(patroni_primary{job="patroni"}) == bool 1)', PG_DASH),
        ("etcd", 'avg(up{job="etcd"})', PG_DASH),
        ("Valkey", 'avg(redis_up{job="valkey"}) * (count(redis_instance_info{job="valkey", role="master"}) == bool 1)',
         VALKEY_DASH),
        ("NetBox", 'avg(probe_success{job="blackbox-http_2xx", host=~"netbox[0-9]+"})', PROBES_DASH),
        ("dark-triage", 'avg(probe_success{job="blackbox-http_2xx", host=~"triage[0-9]+"})', TRIAGE_DASH),
        ("DNS", 'avg(probe_success{job="blackbox-dns_soa"})', PROBES_DASH),
        ("nginx proxy", 'avg(nginx_up{job="nginx"})', NGINX_DASH),
    ]
    b.add(stat("HA services", [q(f"({e}) or vector(0)", name, instant=True) for name, e, _ in services],
               text_mode="value_and_name", mappings=SERVICE_MAP, thresholds=SERVICE_STEPS, text_size=(11, 14),
               desc="Each service's members that answer, as a share: OK = all, DEGRADED = some (the service still runs "
                    "on the others), DOWN = none. Postgres and Valkey also need exactly one leader/primary. NetBox and "
                    "dark-triage: their per-node HTTP probes; DNS: the SOA probes of dns01/02. Click a tile for its "
                    "dashboard.",
               overrides=[override(name, {"links": [{"title": name, "url": dash + "?${__url_time_range}"}]})
                          for name, _, dash in services]), 12, 8)
    b.add(table("VIPs", [q('max by (role, address, host) (node_network_address_info{device=~"vrrp.*"})', table=True)],
                desc="keepalived VIPs and the VM holding each one right now (node_exporter address-info). Every VIP "
                     "should appear exactly once; one missing means nobody holds it (or that VM's node_exporter "
                     "lacks --collector.netdev.address-info).",
                transformations=[organize(exclude=["Time", "Value"], rename={
                    "role": "Service", "address": "VIP", "host": "Held by"}, order=["Service", "VIP", "Held by"])],
                sort="Service"), 6, 8)
    nginx.overview_tiles(b, 6)

    b.row("Databases")
    databases.overview_row(b)

    b.row("Ceph storage")
    ceph_link = [("Ceph cluster", CEPH_DASH + "?${__url_time_range}")]
    b.add(stat("Ceph health", [q("ceph_health_status")], mappings=HEALTH_MAP, thresholds=HEALTH_STEPS,
               no_value="no ceph metrics", links=ceph_link,
               desc="ceph health of the PVE cluster. The Ceph cluster dashboard lists the checks behind a warning."), 4, 5)
    b.add(stat("Ceph raw used", [q("ceph_cluster_total_used_raw_bytes / ceph_cluster_total_bytes")], unit="percentunit",
               decimals=1, thresholds=FILL, color_mode="value", graph=True, links=ceph_link,
               desc="Raw used / raw capacity over all OSDs (3x replication included)."), 4, 5)
    b.add(stat("Ceph client IOPS", [q("sum(rate(ceph_pool_rd[$__rate_interval]))", "read"),
                                    q("sum(rate(ceph_pool_wr[$__rate_interval]))", "write")],
               unit="iops", decimals=0, text_mode="value_and_name", color_mode="value", graph=True,
               overrides=[fixed_color("read", READ), fixed_color("write", WRITE)], links=ceph_link), 6, 5)
    b.add(stat("Ceph client throughput", [q("sum(rate(ceph_pool_rd_bytes[$__rate_interval]))", "read"),
                                          q("sum(rate(ceph_pool_wr_bytes[$__rate_interval]))", "write")],
               unit="Bps", text_mode="value_and_name", color_mode="value", graph=True,
               overrides=[fixed_color("read", READ), fixed_color("write", WRITE)], links=ceph_link), 6, 5)
    b.add(stat("Ceph OSDs / PGs", [q("count(ceph_osd_up == 0) or vector(0)", "OSDs down"),
                                   q("(sum(ceph_pg_total) - sum(ceph_pg_clean)) or vector(0)", "PGs not clean")],
               text_mode="value_and_name", thresholds=ORANGE_IF_ANY,
               overrides=[override("OSDs down", {"thresholds": RED_IF_ANY})], links=ceph_link,
               desc="OSDs down and placement groups that aren't active+clean."), 4, 5)

    b.row("Proxmox")
    pve.overview_row(b)

    b.row("Edge (fw-wan)")
    fwwan.overview_row(b)

    b.row("Targets and alerts")
    b.add(targets_by_job_table(), 7, 10)
    b.add(table("Targets", [q("max without () (up)", table=True)],
                desc="Every scrape target, down ones first.",
                transformations=[organize(exclude=["Time", "cluster"], rename={
                    "job": "Job", "host": "Host", "role": "Role", "instance": "Instance", "Value": "State"},
                    order=["Job", "Host", "Role", "Instance", "State"])],
                mappings=UP_MAP, overrides=[cell("State", "color-background")], sort="State"), 9, 10)
    b.add(table("Firing alerts", [q('max without () (ALERTS{alertstate="firing"})', table=True)],
                desc="Alertmanager routes to a null receiver for now, so these are only visible here.",
                no_value="No firing alerts",
                # Alert-specific labels (reason, address, ...) get names and a fixed place; labels that
                # only repeat the rule's origin (cluster, ceph's type) are left out.
                transformations=[organize(exclude=["Time", "Value", "alertstate", "role", "cluster", "type"], rename={
                    "alertname": "Alert", "severity": "Severity", "job": "Job", "host": "Host",
                    "instance": "Instance", "reason": "Reason", "address": "Address", "network": "Network",
                    "vip": "VIP"},
                    order=["Alert", "Severity", "Job", "Host", "Instance", "Reason", "Address", "Network", "VIP"])]),
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
            "Node Exporter Full or its logs. Disk is / (on VyOS, the persistence partition: the overlay root isn't "
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
                                         "url": NODE_DASH + "?var-job=${__data.fields.job}&var-node=${__data.fields.instance}&${__url_time_range}"},
                                        {"title": "Logs of this host",
                                         "url": LOGS_DASH + "?var-host=${__data.fields.host}&${__url_time_range}"}]}),
        ], sort="State", desc_sort=True), 24, 14)

    b.row("Traffic")
    # topk() in a range query picks a new top 10 at every step; `and on (...) topk(..[$__range] @ end())`
    # picks the 10 busiest over the whole range once and draws only those.
    eth = 'device=~"eth[0-9]+"'
    now, whole = "[$__rate_interval]", "[$__range] @ end()"

    def eth_rate(w):
        return (f"sum by (host, device) (rate(node_network_receive_bytes_total{{{eth}}}{w}) "
                f"+ rate(node_network_transmit_bytes_total{{{eth}}}{w}))")

    def port_rate(w):
        return f"rate(ifHCInOctets{w}) + rate(ifHCOutOctets{w})"

    b.add(timeseries("Top 10 host/router interfaces (rx + tx)", [
        q(f"{eth_rate(now)} * 8 and on (host, device) topk(10, {eth_rate(whole)})", "{{host}} {{device}}"),
    ], unit="bps", desc="Physical (eth*) interfaces from node_exporter: the 10 busiest over the selected range.",
        calcs=("mean", "max")), 12, 9)
    b.add(timeseries("Top 10 switch ports (rx + tx)", [
        q(f"({port_rate(now)}) * 8 and on (host, ifName) topk(10, {port_rate(whole)})", "{{host}} {{ifName}}"),
    ], unit="bps", desc="SNMP if_mib counters from the switches and WLCs: the 10 busiest ports over the selected range.",
        calcs=("mean", "max"), links=[("SNMP Device Summary", SNMP_DASH + "?${__url_time_range}")]), 12, 9)

    b.row("Logs")
    b.add(logs.by_total(logs.per_bucket("Log lines by source", [
        logs.lq('sum by (source) (count_over_time({source=~".+"} [$__auto]))', "{{source}}")],
        desc="Lines reaching Loki: syslog from the routers, switches, WLCs and PVE nodes; the systemd journal "
             "from the Linux VMs.",
        links=[("Logs overview", LOGS_DASH + "?${__url_time_range}")])), 12, 8)
    b.add(logs.top("Noisiest hosts", 'sum by (host) (count_over_time({source=~".+"} [$__range]))', "{{host}}",
                   desc="Log lines per host over the time range.",
                   links=[("Logs of this host", LOGS_DASH + "?var-host=${__field.labels.host}&${__url_time_range}")]),
          12, 8)

    return dashboard("lylat-overview", "lylat.space overview",
                     "Landing page: targets and alerts, the HA services and their VIPs, the published sites, databases, "
                     "Ceph, Proxmox, fw-wan, the EVPN fabric, hosts, top talkers and log volume.",
                     b, tags=["overview"], nav_links=theme.category_links(), time_from="now-3h")


# --- FRR / EVPN fabric ---------------------------------------------------------

def frr():
    h = 'host=~"$host"'
    # The Router picker lists every frr_exporter (the DHCP VMs run no BGP/BFD, border leafs carry
    # only L3 VNIs), so an empty panel says why.
    no_bgp, no_bfd = "No BGP sessions on the selected router(s)", "No BFD peers on the selected router(s)"
    no_l2 = "No L2 VNIs on the selected router(s)"
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
               no_value=no_bgp, desc="Lowest session uptime; orange if a session came up within the last hour."), 4, 5)
    b.add(stat("Exporter problems", [
        q(f'count(up{{job="vyos-frr", {h}}} == 0) or vector(0)', "Targets down"),
        q(f"count(frr_collector_up{{{h}}} == 0) or vector(0)", "Collectors failing"),
    ], text_mode="value_and_name", thresholds=RED_IF_ANY,
        desc="frr_exporter targets that don't answer and collectors that failed."), 4, 5)

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
        no_value=no_bgp, sort="Router"), 24, 12)
    b.add(state_timeline("BGP session state", [
        q(f"max without (instance, job, role, local_as, peer_as, peer_hostname) (frr_bgp_peer_state{{{h}}})",
          "{{host}} {{peer}} {{afi}}/{{safi}} {{vrf}}"),
    ], mappings=BGP_MAP, thresholds=steps(("red", None), ("green", 1), ("orange", 2)),
        no_value=no_bgp, desc="Gaps mean the router's exporter wasn't scraped."), 24, 14)
    b.add(timeseries("Established sessions per router", [
        q(f"count by (host) (frr_bgp_peer_state{{{h}}} == 1)", "{{host}}"),
    ], step=True, fill=0, decimals=0, calcs=("min", "lastNotNull"), no_value=no_bgp), 8, 9)
    b.add(table("Flaps per session in range", [
        q(f"sum by (host, vrf, afi, safi, peer) (resets(frr_bgp_peer_uptime_seconds{{{h}}}[$__range])) > 0", table=True),
    ], no_value="No BGP flaps in range", transformations=[organize(exclude=["Time"], rename={
        "host": "Router", "vrf": "VRF", "afi": "AFI", "safi": "SAFI", "peer": "Peer", "Value": "Flaps"})],
        sort="Flaps", desc_sort=True), 8, 9)
    b.add(timeseries("BGP messages per router (rx + tx)", [
        q(f"sum by (host) (rate(frr_bgp_peer_message_received_total{{{h}}}[$__rate_interval]) "
          f"+ rate(frr_bgp_peer_message_sent_total{{{h}}}[$__rate_interval]))", "{{host}}"),
    ], unit="short", no_value=no_bgp, desc="Messages per second (updates and keepalives)."), 8, 9)
    b.add(timeseries("Prefixes received", [
        q(f"sum by (host, afi, safi) (frr_bgp_peer_prefixes_received_count_total{{{h}}})", "{{host}} {{afi}}/{{safi}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), no_value=no_bgp), 12, 9)
    b.add(timeseries("Prefixes advertised", [
        q(f"sum by (host, afi, safi) (frr_bgp_peer_prefixes_advertised_count_total{{{h}}})", "{{host}} {{afi}}/{{safi}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), no_value=no_bgp), 12, 9)

    b.row("BFD")
    b.add(table("BFD peers", [
        q(f"max without (instance, job, role) (frr_bfd_peer_state{{{h}}})", table=True),
        q(f"max without (instance, job, role) (frr_bfd_peer_uptime{{{h}}})", table=True),
    ], desc="Link-local peers are the underlay links to the spines; fd69:255:240::1/::2 are the spine loopbacks (EVPN).",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Router", "local": "Local", "peer": "Peer", "Value #A": "State", "Value #B": "Uptime"},
            order=["Router", "Local", "Peer", "State", "Uptime"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": BFD_MAP}),
                   override("Uptime", {"unit": "dtdurations"})], no_value=no_bfd, sort="Router"), 10, 11)
    b.add(bargauge("BFD peers up per router", [
        q(f"sum by (host) (frr_bfd_peer_state{{{h}}}) / max by (host) (frr_bfd_peer_count{{{h}}})", "{{host}}"),
    ], unit="percentunit", min_=0, max_=1, thresholds=steps(("red", None), ("orange", 0.01), ("green", 1)),
        no_value=no_bfd, desc="Up / configured BFD peers. Routers without BFD peers (DHCP VMs) are left out."), 6, 11)
    b.add(timeseries("BFD peers up", [
        q(f"sum by (host) (frr_bfd_peer_state{{{h}}})", "{{host}}"),
    ], step=True, fill=0, decimals=0, calcs=("min", "lastNotNull"), no_value=no_bfd), 8, 11)

    b.row("EVPN")
    l2 = f'type="L2", {h}'
    b.add(timeseries("Remote VTEPs per router", [
        q(f"max by (host) (frr_bgp_l2vpn_evpn_remote_vtep_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, step=True, calcs=("min", "lastNotNull"), no_value=no_l2,
        desc="Remote VTEPs of the router's busiest L2 VNI."), 8, 8)
    b.add(timeseries("EVPN MACs per router", [
        q(f"sum by (host) (frr_bgp_l2vpn_evpn_mac_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), no_value=no_l2,
        desc="MAC entries over all L2 VNIs (local and remote)."), 8, 8)
    b.add(timeseries("EVPN ARP/ND entries per router", [
        q(f"sum by (host) (frr_bgp_l2vpn_evpn_arp_nd_count_total{{{l2}}})", "{{host}}"),
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), no_value=no_l2,
        desc="ARP/ND (MAC+IP) entries over all L2 VNIs."), 8, 8)

    def per_vni(metric):
        # Column "lan/9009": tenant VRF without the lylat_ prefix, then the VNI.
        return (f'max without (instance, job, role, vxlanIf) (label_join(label_replace({metric}{{{l2}}}, '
                f'"t", "$1", "tenantVrf", "(?:lylat_)?(.*)"), "segment", "/", "t", "vni"))')

    b.add(table("Remote VTEPs per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_remote_vtep_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI. A 0 means no other leaf has this VNI.",
                transformations=matrix("segment"), thresholds=steps(("red", None), ("green", 1)),
                overrides=[override("/", {"custom.cellOptions": {"type": "color-text"}}, regex=True)],
                no_value=no_l2, sort="Router"), 12, 10)
    b.add(table("EVPN MACs per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_mac_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI.", transformations=matrix("segment"), no_value=no_l2,
                sort="Router"), 12, 10)
    b.add(table("ARP/ND entries per L2 VNI", [q(per_vni("frr_bgp_l2vpn_evpn_arp_nd_count_total"), table=True)],
                desc="Columns are tenant VRF / VNI.", transformations=matrix("segment"), no_value=no_l2,
                sort="Router"), 12, 10)
    b.add(bargauge("EVPN MACs and ARP/ND per tenant VRF", [
        q(f"max by (tenantVrf) (sum by (host, tenantVrf) (frr_bgp_l2vpn_evpn_mac_count_total{{{l2}}}))", "{{tenantVrf}} MACs"),
        q(f"max by (tenantVrf) (sum by (host, tenantVrf) (frr_bgp_l2vpn_evpn_arp_nd_count_total{{{l2}}}))", "{{tenantVrf}} ARP/ND"),
    ], thresholds=BLUE, decimals=0, no_value=no_l2,
        desc="Largest count on any router (each leaf sees the whole EVPN table)."), 12, 10)

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
    ], decimals=0, fill=0, calcs=("min", "max", "lastNotNull"), no_value=no_bgp), 8, 9)

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
                     b, tags=["frr", "bgp", "evpn"], variables=variables,
                     extra_links=[{"type": "link", "title": "Network device logs", "icon": "doc",
                                   "url": "/d/logs-network/logs-network", "includeVars": False, "keepTime": True,
                                   "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}])


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
    b.add(stat("IP protocol", [q(f'probe_ip_protocol{{job="blackbox-icmp", {s}}}', "{{host}}")],
               text_mode="value_and_name", color_mode="value", thresholds=BLUE,
               mappings=mapping(**{"4": ("IPv4", INFO), "6": ("IPv6", INFO)}),
               desc="Address family the ICMP probe used."), 6, 8)

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
    ], text_mode="value_and_name", color_mode="value", thresholds=BLUE,
        overrides=[override(" TLS$", {"mappings": mapping(**{"0": ("no TLS", INFO), "1": ("TLS", INFO)})}, regex=True)]), 6, 8)
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
        q(f"max(probe_dns_serial{{{s}}}) - min(probe_dns_serial{{{s}}})"),
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
    ], unit="s", fill=0, no_value="No probe matches the selection",  # every probe type, not only DNS
        desc="Time the blackbox exporter spends resolving the target's name. Targets are IPs, so it's near zero."), 12, 8)

    # The Probe and Target pickers empty the other protocols' rows: say so instead of "No data".
    no_value = {"Status": "No probe matches the selection", "ICMP": "No ICMP probe selected",
                "HTTP": "No HTTP probe selected", "DNS": "No DNS probe selected"}
    row = None
    for p in b.panels:
        if p["type"] == "row":
            row = p["title"]
        else:
            p["fieldConfig"]["defaults"].setdefault("noValue", no_value[row])

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
    b.add(stat("Component status", [q(f"up{{{STACK_JOBS}}}", "{{job}} {{host}}", instant=True)], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS), 10, 7)
    b.add(stat("Config reloads", [
        q("prometheus_config_last_reload_successful", "Prometheus {{host}}", instant=True),
        q("alertmanager_config_last_reload_successful", "Alertmanager {{host}}", instant=True),
        q("blackbox_exporter_config_last_reload_successful", "Blackbox", instant=True),
    ], text_mode="value_and_name", mappings=OK_MAP, thresholds=UP_STEPS), 4, 7)
    versions = " or ".join(
        # frr_exporter on VyOS doesn't report a version.
        f'label_replace(label_replace(count by (version) ({metric}_build_info), "version", "not reported", "version", ""), '
        f'"component", "{name}", "", "")'
        for name, metric in (("Prometheus", "prometheus"), ("Alertmanager", "alertmanager"), ("Grafana", "grafana"),
                             ("blackbox_exporter", "blackbox_exporter"), ("snmp_exporter", "snmp_exporter"),
                             ("node_exporter", "node_exporter"), ("frr_exporter", "frr_exporter"),
                             ("Loki", "loki"), ("Alloy", "alloy"), ("Mimir", "cortex")))
    b.add(table("Versions", [q(versions, table=True)],
                transformations=[organize(exclude=["Time"], rename={
                    "component": "Component", "version": "Version", "Value": "Instances"},
                    order=["Component", "Version", "Instances"])], sort="Component"), 10, 7)

    b.row("Prometheus")
    # Two replicas (mon01, mon02) scrape the same targets; per-replica panels use the host label.
    b.add(stat("Head series", [q('prometheus_tsdb_head_series{job="prometheus"}', "{{host}}")],
               text_mode="value_and_name", color_mode="value", graph=True, thresholds=BLUE,
               desc="Per Prometheus replica: both scrape the same targets, so they should be close."), 4, 5)
    b.add(stat("Samples / s", [q('sum by (host) (rate(prometheus_tsdb_head_samples_appended_total{job="prometheus"}[$__rate_interval]))', "{{host}}")],
               text_mode="value_and_name", color_mode="value", graph=True, thresholds=BLUE, decimals=0), 4, 5)
    b.add(stat("TSDB size", [q('prometheus_tsdb_storage_blocks_bytes{job="prometheus"} + prometheus_tsdb_wal_storage_size_bytes{job="prometheus"} '
                                '+ prometheus_tsdb_head_chunks_storage_size_bytes{job="prometheus"}', "{{host}}")],
               unit="bytes", text_mode="value_and_name", color_mode="value", graph=True, thresholds=BLUE,
               desc="Blocks + WAL + head chunks per replica. Retention is capped by time and size in monitoring-config."), 4, 5)
    b.add(stat("Backend disk free", [
        q('100 * node_filesystem_avail_bytes{role="monitoring", mountpoint="/"} / node_filesystem_size_bytes{role="monitoring", mountpoint="/"}', "{{host}}")],
        unit="percent", decimals=1, text_mode="value_and_name", color_mode="value", thresholds=steps(("red", None), ("orange", 10), ("green", 25)),
        desc="Free space on each backend VM's root filesystem, where the Prometheus data lives (and the retired InfluxDB's until it is removed)."), 4, 5)
    b.add(stat("Rule evaluation failures", [
        q("sum(increase(prometheus_rule_evaluation_failures_total[$__range])) or vector(0)")],
        thresholds=RED_IF_ANY, decimals=0, desc="In the selected time range."), 4, 5)
    # Two counters, not a sum: a failed send counts in errors (per Alertmanager) and the same alerts
    # usually in dropped as well.
    b.add(stat("Notifications dropped / errors", [
        q("sum(increase(prometheus_notifications_dropped_total[$__range])) or vector(0)", "dropped"),
        q("sum(increase(prometheus_notifications_errors_total[$__range])) or vector(0)", "send errors"),
    ], text_mode="value_and_name", thresholds=RED_IF_ANY, decimals=0,
        desc="In the selected range: alerts Prometheus dropped (not delivered), and alerts in failed sends to an "
             "Alertmanager (counted per Alertmanager, so one failure to both counts twice)."), 4, 5)
    b.add(targets_by_job_table(), 8, 10)
    b.add(timeseries("Scrape duration by job (slowest target)", [
        q("max by (job) (scrape_duration_seconds)", "{{job}}")], unit="s", fill=0, calcs=("mean", "max")), 8, 10)
    b.add(timeseries("Samples scraped by job", [
        q("sum by (job) (scrape_samples_scraped)", "{{job}}")], fill=0, stack=False, calcs=("mean", "lastNotNull")), 8, 10)
    b.add(timeseries("Head series and chunks", [
        q('prometheus_tsdb_head_series{job="prometheus"}', "{{host}} series"),
        q('prometheus_tsdb_head_chunks{job="prometheus"}', "{{host}} chunks")], fill=0), 8, 8)
    b.add(timeseries("Storage", [
        q('prometheus_tsdb_storage_blocks_bytes{job="prometheus"}', "{{host}} blocks"),
        q('prometheus_tsdb_wal_storage_size_bytes{job="prometheus"}', "{{host}} WAL"),
        q('prometheus_tsdb_head_chunks_storage_size_bytes{job="prometheus"}', "{{host}} head chunks")], unit="bytes", stack=True), 8, 8)
    b.add(timeseries("Ingestion rate", [
        q('sum by (host) (rate(prometheus_tsdb_head_samples_appended_total{job="prometheus"}[$__rate_interval]))', "{{host}}")], fill=0), 8, 8)
    b.add(timeseries("Rule group evaluation", [
        q('prometheus_rule_group_last_duration_seconds{job="prometheus"}', "{{host}} {{rule_group}} duration"),
        q('max by (rule_group) (prometheus_rule_group_interval_seconds{job="prometheus"})', "{{rule_group}} interval"),
    ], unit="s", fill=0, desc="A group whose duration nears its interval misses evaluations."), 8, 8)
    b.add(timeseries("Query duration (p90)", [
        q('prometheus_engine_query_duration_seconds{job="prometheus", quantile="0.9"}', "{{host}} {{slice}}")], unit="s", fill=0), 8, 8)
    b.add(timeseries("Remote write to Mimir", [
        q('sum by (host) (rate(prometheus_remote_storage_samples_total{job="prometheus"}[$__rate_interval]))', "{{host}} sent/s"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_failed_total{job="prometheus"}[$__rate_interval])) > 0', "{{host}} failed/s"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_retried_total{job="prometheus"}[$__rate_interval])) > 0', "{{host}} retried/s"),
        q('max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job="prometheus"}) - '
          'max by (host) (prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job="prometheus"})', "{{host}} lag (s)"),
    ], fill=0, desc="Both replicas send everything; Mimir's HA tracker keeps one replica's samples (the other's "
                    "are accepted and discarded, not failed). Lag: newest sample appended vs newest sent."), 8, 8)

    # Mimir on mim01-03 (metrics.tf): long-term store behind both Prometheus replicas (HA tracker).
    b.row("Mimir (long-term metrics)")
    mj = 'job="mimir"'
    b.add(stat("Mimir / haproxy", [q('up{job=~"mimir|haproxy-mimir"}', "{{job}} {{host}}", instant=True)],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS,
               desc="Mimir and haproxy (S3 to the RGWs) on mim01-03. Prometheus pushes to the VIP 10.13.11.103."), 8, 7)
    b.add(stat("Ring members ACTIVE", [q(f'min by (name) (cortex_ring_members{{{mj}, state="ACTIVE"}})', "{{name}}")],
               text_mode="value_and_name", thresholds=steps(("red", None), ("orange", 2), ("green", 3)),
               desc="ACTIVE members of each Mimir ring, as seen by the Mimir that sees fewest. 3 = all Mimir VMs."), 6, 7)
    b.add(stat("Accepted Prometheus replica", [
        q(f"max by (replica) (cortex_ha_tracker_elected_replica_status{{{mj}}}) == 1", "{{replica}}", instant=True)],
        text_mode="name", color_mode="value", thresholds=BLUE,
        desc="The HA tracker keeps one replica's samples (label __replica__) and drops the other's. It fails over "
             "when the elected replica sends nothing for 30 s."), 5, 7)
    b.add(stat("Write problems", [
        q(f'sum(increase(cortex_discarded_samples_total{{{mj}, reason!="replicas_did_not_match"}}[$__range])) or vector(0)',
          "discarded samples"),
        q(f"sum(increase(cortex_ingester_shipper_upload_failures_total{{{mj}}}[$__range])) or vector(0)", "block uploads failed"),
        q('sum(increase(prometheus_remote_storage_samples_failed_total{job="prometheus"}[$__range])) or vector(0)',
          "remote_write failed"),
    ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=RED_IF_ANY,
        desc="In the time range: samples Mimir rejected (limits, out of order; not the HA dedup), TSDB blocks that "
             "failed to upload to S3, samples Prometheus gave up sending."), 5, 7)
    b.add(timeseries("Samples received / deduplicated", [
        q(f"sum(rate(cortex_distributor_received_samples_total{{{mj}}}[$__rate_interval]))", "accepted"),
        q(f"sum(rate(cortex_distributor_deduped_samples_total{{{mj}}}[$__rate_interval]))", "dropped (other replica)"),
        q(f'sum by (reason) (rate(cortex_discarded_samples_total{{{mj}, reason!="replicas_did_not_match"}}[$__rate_interval])) > 0',
          "discarded: {{reason}}"),
    ], fill=0, desc="Samples/s at the distributors: accepted from the elected replica, dropped from the other one, "
                    "and anything rejected."), 8, 8)
    b.add(timeseries("Active series", [
        q(f"sum by (host) (cortex_ingester_active_series{{{mj}}})", "{{host}}")], fill=0, decimals=0,
        desc="Series each ingester holds (RF 3: every ingester has all of them). The per-tenant limit is "
             "metrics_settings.max_series (300k)."), 8, 8)
    b.add(timeseries("Prometheus remote_write", [
        q('sum by (host) (rate(prometheus_remote_storage_samples_total{job="prometheus"}[$__rate_interval]))', "{{host}} sent/s"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_retried_total{job="prometheus"}[$__rate_interval])) > 0',
          "{{host}} retried/s"),
        q('sum by (host) (rate(prometheus_remote_storage_samples_failed_total{job="prometheus"}[$__rate_interval])) > 0',
          "{{host}} failed/s"),
    ], fill=0, desc="Both Prometheus replicas send everything; Mimir keeps one copy."), 8, 8)
    b.add(timeseries("remote_write lag", [
        q('max by (host) (prometheus_remote_storage_highest_timestamp_in_seconds{job="prometheus"} - ignoring(remote_name, url) '
          'group_right prometheus_remote_storage_queue_highest_sent_timestamp_seconds{job="prometheus"})', "{{host}}")],
        unit="s", fill=0, desc="How far each Prometheus is behind in sending to Mimir. It grows while Mimir is "
                               "unreachable and drains from the WAL afterwards (alert PrometheusRemoteWriteBehind)."), 8, 8)
    b.add(timeseries("Blocks to S3 and compaction", [
        q(f"sum by (host) (increase(cortex_ingester_shipper_uploads_total{{{mj}}}[1h]))", "{{host}} blocks uploaded/h"),
        q(f"(time() - max(cortex_compactor_last_successful_run_timestamp_seconds{{{mj}}})) / 3600", "hours since compaction"),
    ], fill=0, desc="Each ingester ships a 2 h block every 2 h; the compactor merges them and applies retention (396 d)."), 8, 8)
    b.add(timeseries("Query latency (p95)", [
        q(f'histogram_quantile(0.95, sum by (le, route) (rate(cortex_request_duration_seconds_bucket{{{mj}, '
          f'route=~"prometheus_api_v1_(query|query_range|series|labels|label_name_values)"}}[$__rate_interval])))', "{{route}}")],
        unit="s", fill=0, desc="Grafana's queries through the query-frontend (only while someone views a dashboard)."), 8, 8)
    b.add(timeseries("S3 operations", [
        q(f"sum by (operation) (rate(thanos_objstore_bucket_operations_total{{{mj}}}[$__rate_interval]))", "{{operation}}"),
        q(f"sum by (operation) (rate(thanos_objstore_bucket_operation_failures_total{{{mj}}}[$__rate_interval])) > 0",
          "{{operation}} failed"),
    ], unit="reqps", fill=0, desc="Requests to the RGWs through each Mimir VM's haproxy."), 8, 8)

    # Grafana's database: the Patroni cluster on pg01-03 (postgres.tf), VIP 10.13.11.104 on the leader.
    b.row("Postgres (Patroni, Grafana's database)")
    pj, ej = 'job="patroni"', 'job="etcd"'
    b.add(stat("Patroni / etcd / exporters", [q('up{job=~"patroni|etcd|postgres|haproxy-postgres"}', "{{job}} {{host}}", instant=True)],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS,
               desc="Patroni REST API, etcd, postgres_exporter and haproxy (S3 to the RGWs) on pg01-03."), 6, 7)
    b.add(stat("Leader", [q(f"max by (host) (patroni_primary{{{pj}}}) == 1", "{{host}}", instant=True)],
               text_mode="name", color_mode="value", thresholds=BLUE,
               desc="The member that holds Patroni's leader key and the VIP 10.13.11.104 (keepalived checks /primary). "
                    "None or two: alert PatroniNoLeader."), 3, 7)
    b.add(stat("Members", [
        q(f"sum(patroni_postgres_running{{{pj}}})", "Postgres running"),
        q(f"sum(patroni_replica{{{pj}}} == 1 and on (host) patroni_postgres_streaming{{{pj}}} == 1) or vector(0)", "replicas streaming"),
        q(f"count(etcd_server_has_leader{{{ej}}} == 1) or vector(0)", "etcd with leader"),
        q('count(node_network_address_info{job="node", role="postgres", address="10.13.11.104"}) or vector(0)', "VIP held"),
    ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=BLUE,
        desc="3 / 2 / 3 / 1 when healthy."), 5, 7)
    b.add(stat("Timeline / backups", [
        q(f"max(patroni_postgres_timeline{{{pj}}})", "timeline"),
        q('max(pg_stat_archiver_last_archive_age{job="postgres"} and on (host) patroni_primary{job="patroni"} == 1)', "WAL archive age (s)"),
        q('(time() - max(pgbackrest_backup_last_success_timestamp_seconds{job="node"})) / 3600', "hours since backup"),
        q('sum(increase(pg_stat_archiver_failed_count{job="postgres"}[$__range])) or vector(0)', "archive failures"),
    ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=BLUE,
        desc="The timeline grows by one per failover/switchover. WAL is archived to S3 (pgBackRest) at least every "
             "archive_timeout (300 s) when Grafana writes; a full backup runs daily on the leader (PITR 14 days)."), 6, 7)
    b.add(stat("etcd leader changes", [q(f"sum(increase(etcd_server_leader_changes_seen_total{{{ej}}}[$__range])) or vector(0)")],
               decimals=0, color_mode="value", thresholds=BLUE, desc="In the time range, summed over the members."), 4, 7)
    b.add(state_timeline("Role", [
        q(f"patroni_primary{{{pj}}} * 2 + patroni_replica{{{pj}}}", "{{host}}")],
        mappings=mapping(**{"2": ("leader", "green"), "1": ("replica", "blue"), "0": ("down", "red")}),
        desc="Which member led when: a failover shows up as the green bar moving."), 8, 8)
    b.add(timeseries("Replication lag", [
        q(f"scalar(max(patroni_xlog_location{{{pj}}} and on (host) patroni_primary{{{pj}}} == 1)) - "
          f"(patroni_xlog_replayed_location{{{pj}}} and on (host) patroni_replica{{{pj}}} == 1)", "{{host}}")],
        unit="bytes", fill=0, desc="WAL bytes each replica has not replayed yet. Past maximum_lag_on_failover (1 MiB) "
                                   "it can't become leader (alert PatroniReplicaLag)."), 8, 8)
    b.add(timeseries("Transactions and connections", [
        q('sum by (host) (rate(pg_stat_database_xact_commit{job="postgres", datname="grafana"}[$__rate_interval]))', "{{host}} commits/s"),
        q('sum by (host) (pg_stat_database_numbackends{job="postgres", datname="grafana"})', "{{host}} connections"),
    ], fill=0, desc="Grafana's database: only the leader takes writes; replicas show 0 commits."), 8, 8)
    b.add(timeseries("WAL archiving", [
        q('rate(pg_stat_archiver_archived_count{job="postgres"}[$__rate_interval]) * 300 > 0', "{{host}} segments / 5 min"),
        q('increase(pg_stat_archiver_failed_count{job="postgres"}[$__rate_interval]) > 0', "{{host}} failed"),
    ], fill=0, desc="Only the leader archives. Failures mean pgBackRest can't reach S3 (alert PostgresWALArchiveFailing)."), 8, 8)
    b.add(timeseries("etcd", [
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{{{ej}}}[$__rate_interval])))", "{{host}} WAL fsync p99"),
        q(f"histogram_quantile(0.99, sum by (le, host) (rate(etcd_network_peer_round_trip_time_seconds_bucket{{{ej}}}[$__rate_interval])))", "{{host}} peer RTT p99"),
    ], unit="s", fill=0, desc="Slow fsyncs or peer round trips cause leader elections (Ceph RBD latency shows up here)."), 8, 8)
    b.add(timeseries("Database size", [
        q('pg_database_size_bytes{job="postgres", datname="grafana"}', "{{host}}")], unit="bytes", fill=0), 8, 8)

    b.row("Alertmanager")
    b.add(stat("Alerts", [q("max by (state) (alertmanager_alerts)", "{{state}}")], text_mode="value_and_name", color_mode="value",
               thresholds=BLUE, desc="The cluster members share alerts and silences: the highest member's count."), 4, 7)
    b.add(stat("Silences", [q("max by (state) (alertmanager_silences)", "{{state}}")], text_mode="value_and_name", color_mode="value",
               thresholds=BLUE), 4, 7)
    b.add(stat("Cluster", [
        q('alertmanager_cluster_members{job="alertmanager"}', "{{host}} members", instant=True),
        q('count by (host) (node_network_address_info{job="node", role="monitoring", address=~"10\\\\.(5|13)\\\\.11\\\\.102"})', "{{host}} holds VIPs",
          instant=True),
    ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=BLUE,
        desc="Members each Alertmanager sees in its gossip cluster (2 = both backends, over the ha_monitor VLAN), "
             "and which backend holds the keepalived VIPs 10.5.11.102/10.13.11.102 (2 = both)."), 4, 7)
    b.add(timeseries("Alerts received", [
        q("sum by (host, status) (rate(alertmanager_alerts_received_total[$__rate_interval]))", "{{host}} {{status}}")], fill=0,
        desc="Per second, from both Prometheus replicas and the Loki ruler (each sends to every member)."), 4, 7)
    b.add(timeseries("Notifications by integration", [
        q("sum by (integration) (rate(alertmanager_notifications_total[$__rate_interval])) > 0", "{{integration}} sent"),
        q("sum by (integration) (rate(alertmanager_notifications_failed_total[$__rate_interval])) > 0", "{{integration}} failed"),
        q("sum(rate(alertmanager_notifications_total[$__rate_interval]))", "all integrations"),
    ], fill=0, desc="Everything routes to the null receiver for now, so this stays at 0."), 8, 7)
    b.add(timeseries("Prometheus → Alertmanager", [
        q('sum by (host) (rate(prometheus_notifications_sent_total{job="prometheus"}[$__rate_interval]))', "{{host}} sent/s"),
        q('sum by (host) (rate(prometheus_notifications_errors_total{job="prometheus"}[$__rate_interval]))', "{{host}} errors/s"),
        q('sum by (host) (rate(prometheus_notifications_dropped_total{job="prometheus"}[$__rate_interval]))', "{{host}} dropped/s"),
        q('prometheus_notifications_queue_length{job="prometheus"}', "{{host}} queue length"),
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
    ], fill=0, decimals=0, desc="Connections from each Grafana to its Postgres (Patroni on pg01-03, through the VIP "
                                  "10.13.11.104 on the leader)."), 8, 8)
    b.add(timeseries("Grafana alerting", [
        q("grafana_alerting_active_alerts", "{{host}} active alerts"),
        q("rate(grafana_alerting_execution_time_milliseconds_count[$__rate_interval])", "{{host}} evaluations/s"),
    ], fill=0), 8, 8)

    b.row("Loki and Alloy (logs)")
    logs_link = [("Logs overview", LOGS_DASH + "?${__url_time_range}")]
    b.add(stat("Loki / Alloy / haproxy", [q('up{job=~"loki|alloy|haproxy"}', "{{job}} {{host}}", instant=True)],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS,
               desc="Loki and haproxy (S3 to the RGWs) on loki01-03, Alloy on every VM that ships logs."), 8, 7)
    b.add(stat("Ring members ACTIVE", [q('min by (name) (loki_ring_members{state="ACTIVE"})', "{{name}}")],
               text_mode="value_and_name", thresholds=steps(("red", None), ("orange", 2), ("green", 3)),
               desc="ACTIVE members of each Loki ring, as seen by the Loki that sees fewest. 3 = all log VMs."), 6, 7)
    b.add(stat("Ring health", [
        q('max(loki_ring_members{state="Unhealthy"}) or vector(0)', "Unhealthy members"),
        q("min(loki_memberlist_client_cluster_members_count)", "memberlist members"),
        q('min(sum by (host) (haproxy_server_status{proxy="rgw", state="UP"}))', "RGWs UP (worst VM)"),
    ], text_mode="value_and_name", color_mode="value", decimals=0,
        overrides=[override("Unhealthy members", {"thresholds": RED_IF_ANY}),
                   override("memberlist members", {"thresholds": steps(("red", None), ("orange", 2), ("green", 3))}),
                   override("RGWs UP (worst VM)", {"thresholds": steps(("red", None), ("orange", 2), ("green", 3))})],
        desc="Unhealthy ring members (missed heartbeats), memberlist gossip members (VLAN 214), and the fewest "
             "Ceph RGWs any monitoring VM's haproxy (loki, mim, pg) sees UP."), 5, 7)
    b.add(stat("Flush failures", [
        q("sum(increase(loki_ingester_chunks_flush_failures_total[$__range])) or vector(0)", "chunk flushes"),
        q("sum(increase(loki_write_dropped_entries_total[$__range])) or vector(0)", "Alloy drops"),
        q("sum(increase(loki_source_syslog_parsing_errors_total[$__range])) or vector(0)", "syslog parse errors"),
    ], text_mode="value_and_name", color_mode="value", decimals=0, thresholds=RED_IF_ANY,
        desc="In the time range: chunk flushes to S3 that failed, entries Alloy gave up on, syslog lines Alloy "
             "couldn't parse.", links=logs_link), 5, 7)
    b.add(timeseries("Lines received (distributors)", [
        q("sum by (host) (rate(loki_distributor_lines_received_total[$__rate_interval]))", "{{host}}")],
        fill=10, stack=True, desc="Lines/s each Loki's distributor accepts (pushes land on the VIP holder, or the "
                                  "local Loki for each log VM's own Alloy).", links=logs_link), 8, 8)
    b.add(timeseries("Bytes received", [
        q("sum by (host) (rate(loki_distributor_bytes_received_total[$__rate_interval]))", "{{host}}")],
        unit="Bps", fill=10, stack=True), 8, 8)
    b.add(timeseries("Alloy: entries sent / syslog received", [
        q("sum by (host) (rate(loki_write_sent_entries_total[$__rate_interval]))", "{{host}} sent"),
        q("sum by (host) (rate(loki_source_syslog_entries_total[$__rate_interval]))", "{{host}} syslog in"),
        q("sum by (host) (rate(loki_write_dropped_entries_total[$__rate_interval])) > 0", "{{host}} dropped"),
    ], fill=0, desc="Per Alloy: entries pushed to Loki, syslog lines received (log VMs; the VIP holder gets the "
                    "devices), and drops."), 8, 8)
    b.add(timeseries("Chunks flushed to S3 (RGW)", [
        q("sum by (host, reason) (rate(loki_ingester_chunks_flushed_total[$__rate_interval]))", "{{host}} {{reason}}"),
        q("sum by (host) (rate(loki_ingester_chunks_flush_failures_total[$__rate_interval])) > 0", "{{host}} failed"),
    ], fill=0, desc="Chunk flushes by reason (idle, max_age, full, synced). With RF 3 every ingester flushes the "
                    "same chunks."), 8, 8)
    b.add(timeseries("S3 requests", [
        q("sum by (operation, status_code) (rate(loki_s3_request_duration_seconds_count[$__rate_interval]))",
          "{{operation}} {{status_code}}")], unit="reqps", fill=0,
        desc="Requests to the RGWs through the local haproxy, by operation and HTTP status."), 8, 8)
    b.add(timeseries("S3 latency (p95)", [
        q("histogram_quantile(0.95, sum by (le, operation) (rate(loki_s3_request_duration_seconds_bucket[$__rate_interval])))",
          "{{operation}}")], unit="s", fill=0), 8, 8)
    b.add(timeseries("Ingester streams and flush queue", [
        q("sum by (host) (loki_ingester_memory_streams)", "{{host}} streams"),
        q("sum by (host) (loki_ingester_flush_queue_length)", "{{host}} flush queue"),
    ], fill=0, decimals=0, desc="Streams held in memory, and chunks waiting to be flushed (should drain to 0)."),
        8, 8)

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
    # Telegraf on each backend: job telegraf = the C9800s' model-driven telemetry -> wlc_* (job wlc);
    # job pvestatd = the PVE metric servers' writes -> Prometheus (scraped by container name, host "pvestatd").
    tg = 'job="telegraf"'
    b.add(timeseries("Telegraf: metrics received", [
        q(f"sum by (host, input) (rate(internal_gather_metrics_gathered{{{tg}}}[$__rate_interval]))", "{{host}} {{input}}"),
        q('sum by (input) (rate(internal_gather_metrics_gathered{job="pvestatd", input="influxdb_v2_listener"}[$__rate_interval]))',
          "pvestatd (PVE metric servers)")],
        unit="short", fill=0, calcs=("mean", "max", "lastNotNull"),
        desc="Metrics per second from each Telegraf input; cisco_telemetry_mdt is the C9800s' gRPC dial-out "
             "(one metric per YANG list entry per push), 0 for long fires WlcTelemetryStopped; pvestatd is every PVE "
             "node's pvestatd (each Prometheus scrapes its own backend's Telegraf), 0 for long fires PveMetricsStopped."), 12, 8)
    b.add(timeseries("Telegraf: output buffer", [
        q(f'max by (host, output) (internal_write_buffer_size{{{tg}}})', "{{host}} {{output}}"),
        q(f'max by (output) (internal_write_buffer_limit{{{tg}}})', "{{output}} limit")],
        fill=0, decimals=0, desc="Metrics waiting to be written to the prometheus_client outputs (normally near 0); "
                                 "past the limit Telegraf drops the oldest."), 12, 8)
    b.row("Resources")
    b.add(timeseries("Process memory", [
        q(f"process_resident_memory_bytes{{{STACK_JOBS}}}", "{{job}} {{host}}")], unit="bytes", fill=0), 12, 8)
    b.add(timeseries("Process CPU", [
        q(f"rate(process_cpu_seconds_total{{{STACK_JOBS}}}[$__rate_interval])", "{{job}} {{host}}")],
        unit="percentunit", fill=0, desc="CPU seconds per second (1 = one core)."), 12, 8)

    return dashboard("monitoring-stack", "Monitoring stack",
                     "Prometheus, Alertmanager, Grafana, the exporters and Telegraf (C9800 telemetry) on the "
                     "backends mon01/mon02 (Prometheus HA pair, Alertmanager cluster), "
                     "and the logging stack (Loki rings, ingest, S3 flushes, Alloy).",
                     b, tags=["prometheus", "alertmanager", "grafana", "loki"],
                     # Deep dives per store: Databases/{prometheus,mimir,loki,telegraf}.json (and Postgres, Valkey).
                     extra_links=[{"type": "dashboards", "tags": ["databases"], "asDropdown": True,
                                   "title": "Database dashboards", "includeVars": False, "keepTime": True,
                                   "icon": "external link", "targetBlank": False, "tooltip": "", "url": ""}])


# --- Ceph ----------------------------------------------------------------------
#
# The mgr prometheus module (job "ceph") exports cluster-wide series without a
# host label (instance="ceph_cluster"); per-daemon series carry ceph_daemon
# ("osd.3", "mon.zoness", "mds.fortuna"). Host names come from the *_metadata
# series (hostname label). node_exporter on the PVE nodes would join on its
# "host" label = PVE hostname; until it's installed those panels say so.

HEALTH_MAP = mapping(**{"0": ("HEALTH_OK", "green"), "1": ("HEALTH_WARN", "orange"), "2": ("HEALTH_ERR", "red")})
CHECK_MAP = mapping(**{"0": ("clear", "green"), "1": ("WARN", "orange"), "2": ("ERR", "red")})
HEALTH_STEPS = steps(("green", None), ("orange", 1), ("red", 2))
# ceph_osd_up * 2 + ceph_osd_in
OSD_STATE_MAP = mapping(**{"3": ("up · in", "green"), "2": ("up · out", "blue"),
                           "1": ("down · in", "red"), "0": ("down · out", "purple")})
OSD_STATE_STEPS = steps(("purple", None), ("red", 1), ("blue", 2), ("green", 3))
MGR_MAP = mapping(**{"0": ("standby", "blue"), "1": ("active", "green")})
QUORUM_MAP = mapping(**{"0": ("out of quorum", "red"), "1": ("in quorum", "green")})
FILL = steps(("green", None), ("yellow", 0.7), ("orange", 0.85), ("red", 0.95))  # nearfull 0.85, full 0.95
LAT_S = steps(("green", None), ("yellow", 0.05), ("orange", 0.1), ("red", 0.5))
LAT_MS = steps(("green", None), ("yellow", 50), ("orange", 100), ("red", 500))
READ, WRITE, RECOVERY = ACCENT2, ACCENT, ACCENT3  # directions, not states: the accents
NO_NODE = "No data from node_exporter (job=node, role=proxmox) for this OSD's disk"

POOL_META = "ceph_pool_metadata"


def by_pool(expr, labels="name"):
    return f"({expr}) * on (pool_id) group_left ({labels}) {POOL_META}"


def by_osd_host(expr):
    return f"({expr}) * on (ceph_daemon) group_left (hostname) ceph_osd_metadata"


def lat(metric, window="$__rate_interval", by=None):
    """Average of a Ceph latency pair (<metric>_sum / <metric>_count) over the window, idle (NaN) dropped.

    metric may carry a selector ('ceph_osd_op_r_latency{ceph_daemon="osd.1"}'). by=None keeps the
    series apart, by="" sums over all of them, by="label" sums by that label.
    """
    name, sel = (metric.split("{", 1) + [""])[:2]
    sel = "{" + sel if sel else ""

    def agg(e):
        return e if by is None else f"sum({e})" if by == "" else f"sum by ({by}) ({e})"

    return (f"({agg(f'rate({name}_sum{sel}[{window}])')} / "
            f"{agg(f'rate({name}_count{sel}[{window}])')}) >= 0")


def rw_overrides(read="Read", write="Write"):
    """Reads above the axis in cyan, writes mirrored below it in pink."""
    return [override(f"(?i).*{read}.*", {"color": {"mode": "fixed", "fixedColor": READ}}, regex=True),
            override(f"(?i).*{write}.*", {"color": {"mode": "fixed", "fixedColor": WRITE},
                                          "custom.transform": "negative-Y"}, regex=True)]


# One row per OSD for the tables: ceph_daemon, hostname, device_class, device (sda) and model.
OSD_LABELS = "ceph_daemon, hostname, device_class, device, model"
OSD_INFO = (
    f"max by ({OSD_LABELS}) ("
    "(ceph_osd_metadata * on (ceph_daemon) group_left (device, model) "
    'label_replace(label_replace(max by (ceph_daemon, devices, device_ids) (ceph_disk_occupation), '
    '"device", "$1", "devices", "(.*)"), "model", "$1", "device_ids", "[^=]*=(.*)_[^_]*")) '
    "or on (ceph_daemon) ceph_osd_metadata)")


def osd_col(expr):
    return f"max by ({OSD_LABELS}) (({expr}) * on (ceph_daemon) group_left (hostname, device_class, device, model) {OSD_INFO})"


# The disk under each OSD as node_exporter labels it: host = PVE hostname, device = sda.
OSD_DISK = ('label_replace(label_replace(max by (ceph_daemon, instance, devices) (ceph_disk_occupation), '
            '"host", "$1", "instance", "(.*)"), "device", "$1", "devices", "(.*)")')


def osd_disk(expr):
    return f'({expr}) * on (host, device) group_left (ceph_daemon) {OSD_DISK}'


PG_PROBLEM_STATES = ["degraded", "undersized", "peering", "activating", "remapped", "recovering",
                     "recovery_wait", "backfilling", "backfill_wait", "backfill_toofull",
                     "recovery_toofull", "inconsistent", "incomplete", "stale", "down", "unknown",
                     "laggy", "wait", "peered", "creating", "repair", "failed_repair",
                     "backfill_unfound", "recovery_unfound", "snaptrim_error"]
PG_BUSY_STATES = ["scrubbing", "deep", "snaptrim", "snaptrim_wait", "premerge", "forced_backfill",
                  "forced_recovery"]
OSD_FLAGS = ["noout", "noin", "nodown", "noup", "nobackfill", "norecover", "norebalance", "noscrub",
             "nodeep_scrub"]
MDS_OPS = ["getattr", "lookup", "open", "readdir", "create", "mkdir", "setattr", "unlink", "rename",
           "rmdir", "symlink", "setxattr"]
BLUESTORE_SLOW = {"committed kv": "ceph_bluestore_slow_committed_kv_count",
                  "aio wait": "ceph_bluestore_slow_aio_wait_count",
                  "read onode meta": "ceph_bluestore_slow_read_onode_meta_count",
                  "read wait aio": "ceph_bluestore_slow_read_wait_aio_count"}
# BLUESTORE_SLOW_OP_ALERT counts slow ops over bluestore_slow_ops_warn_lifetime (default 24 h), so
# the BlueStore slow-op panels use the same window rather than the dashboard's time range.
BLUESTORE_SLOW_ALL = " + ".join(f"increase({m}[24h])" for m in BLUESTORE_SLOW.values())
VMID = 'label_replace({}, "vmid", "$1", "image", "(?:vm|base)-([0-9]+)-.*")'


def health_checks(expr_filter=""):
    """Active health checks, value 1 = HEALTH_WARN, 2 = HEALTH_ERR."""
    return (f'max by (name) (ceph_health_detail{{severity="HEALTH_WARN"{expr_filter}}}) '
            f'or 2 * max by (name) (ceph_health_detail{{severity="HEALTH_ERR"{expr_filter}}})')


def ceph():
    b = Board()
    osd_link = [("Ceph OSD", CEPH_OSD_DASH + "?${__url_time_range}")]

    # Status ---------------------------------------------------------------------
    b.row("Status")
    b.add(stat("Health", [q("ceph_health_status")], mappings=HEALTH_MAP, thresholds=HEALTH_STEPS,
               no_value="no ceph metrics", graph=False,
               desc="Overall cluster health (ceph health). The checks behind a WARN/ERR are listed next to it."), 4, 8)
    b.col(7,
          (stat("Active health checks", [q(f"({health_checks()}) > 0", "{{name}}")], text_mode="name",
                mappings=CHECK_MAP, thresholds=HEALTH_STEPS, no_value="No active health checks",
                desc="Health checks currently raised (ceph health detail): orange = HEALTH_WARN, red = HEALTH_ERR. "
                     "BLUESTORE_SLOW_OP_ALERT means OSDs saw BlueStore operations slower than "
                     "bluestore_slow_ops_warn_threshold; see Slow ops and BlueStore below."), 4),
          (state_timeline("Health history", [
              q("ceph_health_status", "cluster"),
              q(health_checks(), "{{name}}"),
          ], mappings=CHECK_MAP, thresholds=HEALTH_STEPS, row_height=0.8,
              desc="Cluster health and every check the active mgr has seen since it started (green = clear)."), 4))
    b.add(gauge("Raw capacity used", [q("ceph_cluster_total_used_raw_bytes / ceph_cluster_total_bytes")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FILL,
                desc="Raw used / raw total over all OSDs (replication included). Ceph warns per OSD at "
                     "nearfull (85%) and stops writes at full (95%); see Fullest OSD."), 4, 8)
    b.grid(9, 4, [
        stat("OSDs", [q("sum(ceph_osd_up)", "up"), q("sum(ceph_osd_in)", "in"),
                      q("count(ceph_osd_metadata)", "total")],
             text_mode="value_and_name", color_mode="value", desc="OSDs up and in, of all OSDs in the OSD map.",
             overrides=[fixed_color("up", "green"), fixed_color("in", "green"), fixed_color("total", "text")],
             links=osd_link),
        stat("OSDs down / out", [q("count(ceph_osd_up == 0) or vector(0)", "down"),
                                 q("count(ceph_osd_in == 0) or vector(0)", "out")],
             text_mode="value_and_name", thresholds=RED_IF_ANY, desc="OSDs that are down or marked out."),
        stat("Monitors", [q("sum(ceph_mon_quorum_status)", "quorum"), q("count(ceph_mon_metadata)", "total")],
             text_mode="value_and_name", color_mode="value",
             overrides=[fixed_color("quorum", "green"), fixed_color("total", "text")],
             desc="Monitors in quorum / monitors in the monmap."),
        stat("Managers", [q("ceph_mgr_status == 1 and on (ceph_daemon) ceph_mgr_metadata", "{{ceph_daemon}}"),
                          q("count(ceph_mgr_status == 0) or vector(0)", "standby")],
             text_mode="value_and_name", color_mode="value", mappings=[],
             overrides=[fixed_color("standby", "blue"), override("mgr\\..*", {"color": {"mode": "fixed", "fixedColor": "green"}, "mappings": mapping(**{"1": ("active", "green")})}, regex=True)],
             desc="The active mgr (serves the metrics) and the number of standbys."),
        stat("MDS", [q('ceph_mds_metadata{rank!="-1"}', "{{ceph_daemon}}"),
                     q('count(ceph_mds_metadata{rank="-1"}) or vector(0)', "standby")],
             text_mode="value_and_name", color_mode="value",
             overrides=[fixed_color("standby", "blue"), override("mds\\..*", {"color": {"mode": "fixed", "fixedColor": "green"}, "mappings": mapping(**{"1": ("active", "green")})}, regex=True)],
             desc="Active MDS for CephFS (rank ≥ 0) and standbys."),
        stat("PGs", [q("sum(ceph_pg_total)", "total"),
                     q("sum(ceph_pg_total) - sum(ceph_pg_clean)", "not clean")],
             text_mode="value_and_name", color_mode="value",
             overrides=[fixed_color("total", "text"), override("not clean", {"thresholds": ORANGE_IF_ANY})],
             desc="Placement groups, and how many aren't active+clean (recovering, degraded, peering, …)."),
    ], per_row=3)

    spark = dict(color_mode="value", graph=True)
    b.add(stat("Read IOPS", [q("sum(rate(ceph_pool_rd[$__rate_interval]))")], unit="iops", decimals=0,
               color=dict(mode="fixed", fixedColor=READ), desc="Client read operations per second, all pools.", **spark), 3, 5)
    b.add(stat("Write IOPS", [q("sum(rate(ceph_pool_wr[$__rate_interval]))")], unit="iops", decimals=0,
               color=dict(mode="fixed", fixedColor=WRITE), desc="Client write operations per second, all pools.", **spark), 3, 5)
    b.add(stat("Read rate", [q("sum(rate(ceph_pool_rd_bytes[$__rate_interval]))")], unit="Bps",
               color=dict(mode="fixed", fixedColor=READ), **spark), 3, 5)
    b.add(stat("Write rate", [q("sum(rate(ceph_pool_wr_bytes[$__rate_interval]))")], unit="Bps",
               color=dict(mode="fixed", fixedColor=WRITE), **spark), 3, 5)
    b.add(stat("Read latency", [q(lat("ceph_osd_op_r_latency", by=""))], unit="s", thresholds=LAT_S,
               desc="Average OSD client read latency (queue + processing) over all OSDs.", **spark), 3, 5)
    b.add(stat("Write latency", [q(lat("ceph_osd_op_w_latency", by=""))], unit="s", thresholds=LAT_S,
               desc="Average OSD client write latency over all OSDs. HDD OSDs without a flash DB/WAL "
                    "usually sit in the tens of ms.", **spark), 3, 5)
    b.add(stat("Recovery", [q("sum(rate(ceph_osd_recovery_bytes[$__rate_interval]))")], unit="Bps",
               color=dict(mode="fixed", fixedColor=RECOVERY),
               desc="Recovery and backfill traffic between OSDs.", **spark), 3, 5)
    b.add(stat("Objects at risk", [
        q("ceph_num_objects_degraded + ceph_num_objects_misplaced + ceph_num_objects_unfound")],
        thresholds=steps(("green", None), ("orange", 1)), decimals=0, **spark,
        desc="Object copies degraded (missing replicas) + misplaced (waiting to move) + unfound. "
             "The breakdown is under Placement groups and recovery."), 3, 5)

    # Capacity -------------------------------------------------------------------
    b.row("Capacity")
    b.add(stat("Raw capacity", [
        q("ceph_cluster_total_bytes", "total"), q("ceph_cluster_total_used_raw_bytes", "used"),
        q("ceph_cluster_total_bytes - ceph_cluster_total_used_raw_bytes", "available")],
        unit="bytes", text_mode="value_and_name", color_mode="value", orientation="horizontal",
        overrides=[fixed_color("total", "text"), fixed_color("used", "orange"), fixed_color("available", "green")],
        desc="Raw bytes over all OSDs. Pools are 3× replicated, so usable space is about a third."), 4, 8)
    b.add(bargauge("Pool usage", [q(by_pool("ceph_pool_percent_used"), "{{name}}")],
                   mode="gradient", unit="percentunit", min_=0, max_=1, decimals=2, thresholds=FILL,
                   desc="Stored / (stored + max available) per pool. Max available is what the fullest "
                        "OSD in the pool's CRUSH rule still allows, so all pools share it."), 6, 8)
    b.add(piechart("Data stored per pool", [q(by_pool("ceph_pool_stored"), "{{name}}")], unit="bytes",
                   desc="Logical data per pool, before replication."), 6, 8)
    used = "max(ceph_osd_stat_bytes_used / ceph_osd_stat_bytes)"
    b.col(4,
          (gauge("Fullest OSD", [q(used)], unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FILL,
                 desc="The most-used OSD. Ceph raises OSD_NEARFULL at 85% and blocks writes at 95%, "
                      "whatever the cluster average."), 5),
          (stat("Fullest OSD nearfull in", [q(
              f"((max(ceph_osd_nearfull_ratio) - {used}) / (deriv({used}[7d:1h]) > 0)) or vector(-1)")],
              unit="dtdurations", color_mode="value",
              mappings=[{"type": "range", "options": {"from": -1, "to": -1, "result": {
                  "text": "not filling up", "color": "green", "index": 0}}}],
              thresholds=steps(("green", None), ("red", 0), ("orange", 7 * 86400), ("green", 30 * 86400)),
              desc="Linear forecast from the last 7 days of the fullest OSD's growth. Empty when it isn't growing."), 3))
    b.add(stat("Raw used in 30 days", [
        q("predict_linear(ceph_cluster_total_used_raw_bytes[7d], 30 * 86400) / ceph_cluster_total_bytes", "forecast"),
        q("ceph_cluster_total_used_raw_bytes / ceph_cluster_total_bytes", "now")],
        unit="percentunit", decimals=1, text_mode="value_and_name", color_mode="value", thresholds=FILL,
        orientation="horizontal",
        desc="predict_linear over the last 7 days (or as much history as Prometheus has)."), 4, 8)

    pool_labels = "pool_id, name, application, description"

    def pool_col(expr):
        return f"max by ({pool_labels}) ({by_pool(expr, 'name, application, description')})"

    b.add(table("Pools", [
        q(pool_col("ceph_pool_stored"), table=True),
        q(pool_col("ceph_pool_stored_raw"), table=True),
        q(pool_col("ceph_pool_percent_used"), table=True),
        q(pool_col("ceph_pool_max_avail"), table=True),
        q(pool_col("ceph_pool_objects"), table=True),
        q(pool_col("sum by (pool_id) (ceph_pg_total)"), table=True),
        q(pool_col("predict_linear(ceph_pool_stored[7d], 30 * 86400)"), table=True),
        q(pool_col("rate(ceph_pool_rd[5m]) + rate(ceph_pool_wr[5m])"), table=True),
    ], desc="Stored = logical data, Raw = with replication. Forecast = stored in 30 days, linear over the last 7 days.",
        transformations=[MERGE, organize(exclude=["Time", "pool_id"], rename={
            "name": "Pool", "application": "Application", "description": "Replication",
            "Value #A": "Stored", "Value #B": "Raw", "Value #C": "Used", "Value #D": "Max available",
            "Value #E": "Objects", "Value #F": "PGs", "Value #G": "Stored in 30 d", "Value #H": "IOPS"},
            order=["Pool", "Application", "Replication", "PGs", "Objects", "Stored", "Raw", "Used",
                   "Max available", "Stored in 30 d", "IOPS"])],
        overrides=[override("Stored|Raw|Max available|Stored in 30 d", {"unit": "bytes"}, regex=True),
                   override("Used", {"unit": "percentunit", "min": 0, "max": 1, "decimals": 2, "thresholds": FILL,
                                     "custom.cellOptions": {"type": "gauge", "mode": "lcd", "valueDisplayMode": "text"}}),
                   override("IOPS", {"unit": "iops", "decimals": 1}), override("Objects", {"unit": "short"})],
        sort="Stored", desc_sort=True), 24, 7)
    b.add(timeseries("Raw capacity and forecast", [
        q("ceph_cluster_total_used_raw_bytes", "used"),
        q("ceph_cluster_total_bytes * on () group_left max(ceph_osd_nearfull_ratio)", "nearfull (85%)"),
        q("ceph_cluster_total_bytes", "total"),
        q("predict_linear(ceph_cluster_total_used_raw_bytes[7d], 30 * 86400)", "forecast for 30 days later"),
    ], unit="bytes", fill=20, gradient="opacity", calcs=("lastNotNull",), min_=0,
        overrides=[fixed_color("used", "orange"),
                   override("total", {"color": {"mode": "fixed", "fixedColor": "text"}, "custom.fillOpacity": 0,
                                      "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}}),
                   override("nearfull (85%)", {"color": {"mode": "fixed", "fixedColor": "red"}, "custom.fillOpacity": 0,
                                               "custom.lineStyle": {"fill": "dash", "dash": [4, 6]}}),
                   override("forecast for 30 days later", {"color": {"mode": "fixed", "fixedColor": "purple"},
                                                           "custom.fillOpacity": 0,
                                                           "custom.lineStyle": {"fill": "dash", "dash": [2, 4]}})],
        desc="The forecast line shows, at each point, where raw usage would be 30 days later at the "
             "growth rate of the 7 days before it."), 8, 9)
    b.add(timeseries("Data stored per pool", [q(by_pool("ceph_pool_stored"), "{{name}}")], unit="bytes",
                     stack=True, fill=30, gradient="opacity", calcs=("lastNotNull",)), 8, 9)
    b.add(timeseries("Objects per pool", [q(by_pool("ceph_pool_objects"), "{{name}}")], unit="short",
                     fill=0, calcs=("lastNotNull",)), 8, 9)

    # Client I/O -----------------------------------------------------------------
    b.row("Client I/O")
    b.add(timeseries("Client IOPS", [
        q("sum(rate(ceph_pool_rd[$__rate_interval]))", "Read"),
        q("sum(rate(ceph_pool_wr[$__rate_interval]))", "Write"),
    ], unit="iops", fill=25, gradient="opacity", overrides=rw_overrides(),
        desc="Reads above the axis, writes below."), 8, 9)
    b.add(timeseries("Client throughput", [
        q("sum(rate(ceph_pool_rd_bytes[$__rate_interval]))", "Read"),
        q("sum(rate(ceph_pool_wr_bytes[$__rate_interval]))", "Write"),
    ], unit="Bps", fill=25, gradient="opacity", overrides=rw_overrides()), 8, 9)
    b.add(timeseries("Client op latency (OSD average)", [
        q(lat("ceph_osd_op_r_latency", by=""), "Read"),
        q(lat("ceph_osd_op_w_latency", by=""), "Write"),
        q(lat("ceph_osd_op_rw_latency", by=""), "Read-modify-write"),
    ], unit="s", fill=0, line=2, min_=0,
        overrides=[fixed_color("Read", READ), fixed_color("Write", WRITE), fixed_color("Read-modify-write", "purple")],
        desc="Sum of OSD op latency / ops over all OSDs, including queueing."), 8, 9)
    b.add(timeseries("IOPS per pool", [
        q(by_pool("rate(ceph_pool_rd[$__rate_interval])"), "{{name}} read"),
        q(by_pool("rate(ceph_pool_wr[$__rate_interval])"), "{{name}} write"),
    ], unit="iops", fill=10, overrides=[override("(?i).* write", {"custom.transform": "negative-Y"}, regex=True)],
        calcs=("mean", "max"), desc="Writes below the axis."), 12, 9)
    b.add(timeseries("Throughput per pool", [
        q(by_pool("rate(ceph_pool_rd_bytes[$__rate_interval])"), "{{name}} read"),
        q(by_pool("rate(ceph_pool_wr_bytes[$__rate_interval])"), "{{name}} write"),
    ], unit="Bps", fill=10, overrides=[override("(?i).* write", {"custom.transform": "negative-Y"}, regex=True)],
        calcs=("mean", "max"), desc="Writes below the axis."), 12, 9)

    # Recovery & PGs ------------------------------------------------------------
    b.row("Placement groups and recovery")
    pg_targets = [q("sum(ceph_pg_active)", "active"), q("sum(ceph_pg_clean)", "clean")]
    pg_targets += [q(f"sum(ceph_pg_{s}) > 0", s.replace("_", " ")) for s in PG_BUSY_STATES + PG_PROBLEM_STATES]
    b.add(bargauge("PG states", pg_targets, mode="gradient", min_=0, decimals=0, bar_height=22,
                   name_placement="top",
                   thresholds=steps(("orange", None)),
                   overrides=[fixed_color("active", "green"), fixed_color("clean", "green"),
                              *[fixed_color(s.replace("_", " "), "blue") for s in PG_BUSY_STATES],
                              *[fixed_color(s.replace("_", " "), "red") for s in
                                ("inconsistent", "incomplete", "stale", "down", "unknown", "failed_repair",
                                 "backfill_unfound", "recovery_unfound", "snaptrim_error")]],
                   desc="PGs per state (a PG is in several at once). Only non-zero states besides active and "
                        "clean are listed: blue = routine (scrubbing, snap trimming), orange = recovering or "
                        "degraded, red = needs attention."), 6, 10)
    b.add(timeseries("PGs not clean, by state", [
        q("sum(ceph_pg_total) - sum(ceph_pg_clean)", "not clean"),
        *[q(f"sum(ceph_pg_{s}) > 0", s.replace("_", " ")) for s in PG_PROBLEM_STATES],
    ], fill=0, decimals=0, step=True, calcs=("max", "lastNotNull"),
        overrides=[override("not clean", {"color": {"mode": "fixed", "fixedColor": "orange"}, "custom.fillOpacity": 20})],
        desc="Gaps mean zero."), 9, 10)
    b.add(timeseries("Scrubbing PGs", [
        q("sum(ceph_pg_scrubbing)", "scrubbing"), q("sum(ceph_pg_deep)", "deep scrubbing"),
        q("sum(ceph_pg_snaptrim) + sum(ceph_pg_snaptrim_wait)", "snap trimming"),
    ], fill=20, decimals=0, step=True, calcs=("max", "lastNotNull"),
        overrides=[fixed_color("scrubbing", "light-blue"), fixed_color("deep scrubbing", "blue"),
                   fixed_color("snap trimming", "purple")]), 9, 10)
    b.add(timeseries("Recovery and backfill", [
        q("sum(rate(ceph_osd_recovery_bytes[$__rate_interval]))", "OSD recovery bytes/s"),
        q("sum(ceph_pool_recovering_bytes_per_sec)", "pool recovering bytes/s"),
        q("sum(rate(ceph_osd_recovery_ops[$__rate_interval]))", "recovery ops/s"),
    ], unit="Bps", fill=20, gradient="opacity",
        overrides=[fixed_color("OSD recovery bytes/s", RECOVERY), fixed_color("pool recovering bytes/s", "light-purple"),
                   override("recovery ops/s", {"unit": "ops", "custom.axisPlacement": "right", "custom.fillOpacity": 0,
                                               "color": {"mode": "fixed", "fixedColor": "yellow"}})]), 8, 8)
    b.add(timeseries("Degraded, misplaced and unfound objects", [
        q("ceph_num_objects_degraded", "degraded"), q("ceph_num_objects_misplaced", "misplaced"),
        q("ceph_num_objects_unfound", "unfound"),
    ], fill=10, decimals=0, calcs=("max", "lastNotNull"),
        overrides=[fixed_color("degraded", "orange"), fixed_color("misplaced", "yellow"), fixed_color("unfound", "red")]), 8, 8)
    b.add(stat("OSD flags", [q(f"ceph_osd_flag_{f}", f) for f in OSD_FLAGS],
               text_mode="value_and_name", mappings=mapping(**{"0": ("off", "green"), "1": ("SET", "orange")}),
               thresholds=steps(("green", None), ("orange", 1)), color_mode="value", text_size=(12, 20),
               desc="Cluster-wide OSD flags (ceph osd set …). noout is normal during maintenance; "
                    "anything left set stops recovery or scrubbing."), 8, 8)

    # OSDs -----------------------------------------------------------------------
    b.row("OSDs")
    state = "ceph_osd_up * 2 + ceph_osd_in"
    b.add(stat("OSD status", [q(by_osd_host(state), "{{hostname}} · {{ceph_daemon}}")], text_mode="value_and_name",
               mappings=OSD_STATE_MAP, thresholds=OSD_STATE_STEPS, justify="center",
               desc="One tile per OSD: green = up and in, blue = up but out, red = down but still in "
                    "(data is degraded), purple = down and out. Click for the OSD dashboard.",
               links=[("Ceph OSD", CEPH_OSD_DASH + "?${__url_time_range}")]), 13, 9)
    b.add(table("OSD hosts", [
        q("count by (hostname) (ceph_osd_metadata)", table=True),
        q(f"sum by (hostname) ({by_osd_host('ceph_osd_up')})", table=True),
        q(f"sum by (hostname) ({by_osd_host('ceph_osd_in')})", table=True),
        q(f"sum by (hostname) ({by_osd_host('ceph_osd_stat_bytes')})", table=True),
        q(f"sum by (hostname) ({by_osd_host('ceph_osd_stat_bytes_used')}) / sum by (hostname) ({by_osd_host('ceph_osd_stat_bytes')})", table=True),
        q(f"sum by (hostname) ({by_osd_host('ceph_osd_numpg')})", table=True),
        q(f"sum by (hostname) ({by_osd_host('rate(ceph_osd_op_r[5m]) + rate(ceph_osd_op_w[5m])')})", table=True),
    ], desc="OSDs per PVE node.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "hostname": "Host", "Value #A": "OSDs", "Value #B": "Up", "Value #C": "In", "Value #D": "Raw size",
            "Value #E": "Used", "Value #F": "PGs", "Value #G": "IOPS"},
            order=["Host", "OSDs", "Up", "In", "Raw size", "Used", "PGs", "IOPS"])],
        overrides=[override("Raw size", {"unit": "bytes"}),
                   override("Used", {"unit": "percentunit", "min": 0, "max": 1, "decimals": 1, "thresholds": FILL,
                                     "custom.cellOptions": {"type": "gauge", "mode": "lcd", "valueDisplayMode": "text"}}),
                   override("IOPS", {"unit": "iops", "decimals": 1})],
        sort="Host"), 11, 9)

    b.add(table("OSD details", [
        q(osd_col(state), table=True),
        q(osd_col("ceph_osd_weight"), table=True),
        q(osd_col("ceph_osd_numpg"), table=True),
        q(osd_col("ceph_osd_stat_bytes"), table=True),
        q(osd_col("ceph_osd_stat_bytes_used / ceph_osd_stat_bytes"), table=True),
        q(osd_col("ceph_osd_apply_latency_ms"), table=True),
        q(osd_col("ceph_osd_commit_latency_ms"), table=True),
        q(osd_col(lat("ceph_osd_op_r_latency", "5m")), table=True),
        q(osd_col(lat("ceph_osd_op_w_latency", "5m")), table=True),
        q(osd_col("rate(ceph_osd_op_r[5m]) + rate(ceph_osd_op_w[5m])"), table=True),
        q(osd_col("increase(ceph_trackedop_slow_ops_count[$__range])"), table=True),
        q(osd_col(BLUESTORE_SLOW_ALL), table=True),
    ], desc="Latencies are averages over the last 5 minutes. Slow ops = ops over 10 s in the time range; "
            "BlueStore slow 24h = BlueStore operations over its slow-op threshold in the last 24 h (these "
            "raise BLUESTORE_SLOW_OP_ALERT). Click an OSD for its dashboard.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "ceph_daemon": "OSD", "hostname": "Host", "device_class": "Class", "device": "Disk", "model": "Model",
            "Value #A": "State", "Value #B": "Reweight", "Value #C": "PGs", "Value #D": "Size", "Value #E": "Used",
            "Value #F": "Apply", "Value #G": "Commit", "Value #H": "Read lat", "Value #I": "Write lat",
            "Value #J": "IOPS", "Value #K": "Slow ops", "Value #L": "BlueStore slow 24h"},
            order=["OSD", "Host", "Disk", "Model", "Class", "State", "Reweight", "PGs", "Size", "Used", "Apply",
                   "Commit", "Read lat", "Write lat", "IOPS", "Slow ops", "BlueStore slow 24h"])],
        overrides=[cell("State", "color-background"), override("State", {"mappings": OSD_STATE_MAP, "thresholds": OSD_STATE_STEPS}),
                   override("Size", {"unit": "bytes"}), override("Reweight", {"decimals": 2}),
                   override("Used", {"unit": "percentunit", "min": 0, "max": 1, "decimals": 1, "thresholds": FILL,
                                     "custom.cellOptions": {"type": "gauge", "mode": "lcd", "valueDisplayMode": "text"}}),
                   *[override(n, {"unit": "ms", "thresholds": LAT_MS, "custom.cellOptions": {"type": "color-text"}})
                     for n in ("Apply", "Commit")],
                   *[override(n, {"unit": "s", "thresholds": LAT_S, "custom.cellOptions": {"type": "color-text"}})
                     for n in ("Read lat", "Write lat")],
                   override("IOPS", {"unit": "iops", "decimals": 1}),
                   *[override(n, {"decimals": 0, "thresholds": ORANGE_IF_ANY, "custom.cellOptions": {"type": "color-background", "mode": "basic"}})
                     for n in ("Slow ops", "BlueStore slow 24h")],
                   override("OSD", {"links": [{"title": "Ceph OSD",
                                               "url": CEPH_OSD_DASH + "?var-osd=${__data.fields.ceph_daemon}&${__url_time_range}"}]}),
                   *[override(n, {"custom.width": px}) for n, px in (
                       ("OSD", 65), ("Host", 80), ("Disk", 50), ("Model", 170), ("Class", 55), ("State", 90),
                       ("Reweight", 75), ("PGs", 50), ("Size", 80), ("Used", 130), ("Apply", 70), ("Commit", 70),
                       ("Read lat", 85), ("Write lat", 85), ("IOPS", 80), ("Slow ops", 75))]],
        sort="OSD"), 24, 17)
    b.add(state_timeline("OSD state history", [q(by_osd_host(state), "{{ceph_daemon}} ({{hostname}})")],
                         mappings=OSD_STATE_MAP, thresholds=OSD_STATE_STEPS, row_height=0.8,
                         desc="Flaps show up as red/blue slivers."), 24, 9)

    b.row("OSD performance")
    b.add(timeseries("Commit latency per OSD", [q(by_osd_host("ceph_osd_commit_latency_ms"), "{{ceph_daemon}} ({{hostname}})")],
                     unit="ms", fill=0, calcs=("mean", "max", "lastNotNull"), legend="table", placement="right",
                     desc="BlueStore commit latency as reported by each OSD (ceph osd perf)."), 12, 10)
    b.add(bargauge("Utilization per OSD", [q(by_osd_host("ceph_osd_stat_bytes_used / ceph_osd_stat_bytes"), "{{ceph_daemon}} ({{hostname}})")],
                   mode="lcd", unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FILL,
                   desc="Uneven fill means uneven CRUSH weights or too few PGs; the balancer module evens it out."), 6, 10)
    b.add(bargauge("PGs per OSD", [q(by_osd_host("ceph_osd_numpg"), "{{ceph_daemon}}")], mode="gradient",
                   min_=0, decimals=0, thresholds=steps(("blue", None), ("orange", 250), ("red", 300)),
                   desc="mon_max_pg_per_osd defaults to 250."), 6, 10)
    b.add(timeseries("Read latency per OSD", [q(by_osd_host(lat("ceph_osd_op_r_latency", by="ceph_daemon")), "{{ceph_daemon}} ({{hostname}})")],
                     unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right"), 12, 10)
    b.add(timeseries("Write latency per OSD", [q(by_osd_host(lat("ceph_osd_op_w_latency", by="ceph_daemon")), "{{ceph_daemon}} ({{hostname}})")],
                     unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right"), 12, 10)
    b.add(timeseries("IOPS per OSD", [q(by_osd_host("rate(ceph_osd_op_r[$__rate_interval]) + rate(ceph_osd_op_w[$__rate_interval])"),
                                        "{{ceph_daemon}} ({{hostname}})")],
                     unit="iops", fill=0, calcs=("mean", "max"), legend="table", placement="right",
                     desc="Client ops each OSD served as primary."), 12, 10)
    b.add(timeseries("Throughput per OSD", [
        q(by_osd_host("rate(ceph_osd_op_out_bytes[$__rate_interval]) + rate(ceph_osd_op_in_bytes[$__rate_interval])"),
          "{{ceph_daemon}} ({{hostname}})")],
        unit="Bps", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        desc="Client reads + writes per OSD."), 12, 10)

    # Slow ops & BlueStore ------------------------------------------------------
    b.row("Slow ops and BlueStore")
    b.add(stat("BlueStore slow-op alert", [q('max(ceph_health_detail{name="BLUESTORE_SLOW_OP_ALERT"}) or vector(0)')],
               mappings=mapping(**{"0": ("clear", "green"), "1": ("RAISED", "orange")}),
               thresholds=ORANGE_IF_ANY,
               desc="Health check BLUESTORE_SLOW_OP_ALERT: OSDs logged more than bluestore_slow_ops_warn_threshold "
                    "slow BlueStore ops within bluestore_slow_ops_warn_lifetime. Common on busy HDDs without "
                    "a flash DB device."), 6, 5)
    b.add(stat("Daemons with slow ops now", [q('count(ceph_daemon_health_metrics{type="SLOW_OPS"} > 0) or vector(0)')],
               thresholds=RED_IF_ANY, desc="Daemons currently reporting blocked ops (SLOW_OPS health check)."), 6, 5)
    b.add(stat("Slow ops in range", [q("sum(increase(ceph_trackedop_slow_ops_count[$__range])) or vector(0)")],
               decimals=0, thresholds=ORANGE_IF_ANY, graph=False,
               desc="Ops that took over 10 s, on any daemon, in the selected time range."), 6, 5)
    b.add(stat("BlueStore slow ops, last 24 h", [q(f"sum({BLUESTORE_SLOW_ALL}) or vector(0)")],
               decimals=0, thresholds=ORANGE_IF_ANY,
               desc="All four BlueStore slow-op counters, all OSDs, over the 24 h the health check looks back "
                    "(bluestore_slow_ops_warn_lifetime). Needs 24 h of Prometheus history to be complete."), 6, 5)
    b.add(bargauge("Slow ops per daemon in range", [
        q("sort_desc(increase(ceph_trackedop_slow_ops_count[$__range]) > 0)", "{{ceph_daemon}}")],
        mode="gradient", decimals=0, min_=0, thresholds=steps(("yellow", None), ("orange", 10), ("red", 100)),
        no_value="No slow ops in range", desc="OSDs, monitors and the MDS (ops over 10 s)."), 8, 10)
    b.add(table("BlueStore slow ops per OSD, last 24 h", [
        q(f"max by (ceph_daemon, hostname) ({by_osd_host(f'increase({m}[24h])')})", table=True)
        for m in BLUESTORE_SLOW.values()
    ], desc="Each column is one BlueStore slow-op counter: committed kv = slow RocksDB commits, "
            "aio wait = slow disk I/O, read onode meta / read wait aio = slow reads.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "ceph_daemon": "OSD", "hostname": "Host",
            **{f"Value #{chr(65 + i)}": name for i, name in enumerate(BLUESTORE_SLOW)}},
            order=["OSD", "Host", *BLUESTORE_SLOW])],
        overrides=[override(n, {"decimals": 0, "thresholds": ORANGE_IF_ANY, "custom.cellOptions": {"type": "color-text"}})
                   for n in BLUESTORE_SLOW],
        sort="committed kv", desc_sort=True), 8, 10)
    b.add(timeseries("Slow ops per daemon", [
        q("sum by (ceph_daemon) (increase(ceph_trackedop_slow_ops_count[$__rate_interval])) > 0", "{{ceph_daemon}}"),
        q(f"sum by (ceph_daemon) (increase(ceph_bluestore_slow_committed_kv_count[$__rate_interval]) "
          f"+ increase(ceph_bluestore_slow_aio_wait_count[$__rate_interval])) > 0", "{{ceph_daemon}} BlueStore"),
    ], draw="bars", fill=80, decimals=0, stack=True, calcs=("sum",), legend="table", placement="right",
        no_value="No slow ops in range", desc="Slow ops counted per interval; bars only where there were any."), 8, 10)
    b.add(timeseries("BlueStore kv commit latency per OSD", [
        q(by_osd_host(lat("ceph_bluestore_kv_commit_lat", by="ceph_daemon")), "{{ceph_daemon}} ({{hostname}})")],
        unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        desc="Time to commit a RocksDB batch. On HDD-only OSDs the DB shares the spindle, so this tracks disk load."), 12, 9)
    b.add(timeseries("BlueStore latency breakdown (all OSDs)", [
        q(lat(f"ceph_bluestore_{m}", by=""), label) for m, label in (
            ("kv_commit_lat", "kv commit"), ("kv_sync_lat", "kv sync"), ("kv_flush_lat", "kv flush"),
            ("txc_commit_lat", "txc commit"), ("state_aio_wait_lat", "aio wait"), ("read_lat", "read"),
            ("state_kv_queued_lat", "kv queued"))
    ], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        desc="Average per operation over all OSDs."), 12, 9)
    b.add(bargauge("BlueStore free-space fragmentation", [
        q(by_osd_host("ceph_bluestore_fragmentation_micros / 1e6"), "{{ceph_daemon}}")],
        mode="gradient", unit="percentunit", min_=0, max_=1, decimals=1,
        thresholds=steps(("green", None), ("orange", 0.5), ("red", 0.8)),
        desc="Allocator fragmentation score per OSD (0 = contiguous free space, 1 = fully fragmented)."), 8, 9)
    b.add(timeseries("BlueStore onode cache hit ratio", [
        q("sum(rate(ceph_bluestore_onode_hits[$__rate_interval])) / (sum(rate(ceph_bluestore_onode_hits[$__rate_interval])) "
          "+ sum(rate(ceph_bluestore_onode_misses[$__rate_interval])))", "hit ratio")],
        unit="percentunit", fill=20, gradient="opacity", min_=0, max_=1, calcs=("mean", "min"),
        overrides=[fixed_color("hit ratio", "green")]), 8, 9)
    b.add(timeseries("RocksDB (BlueFS DB) used per OSD", [
        q(by_osd_host("ceph_bluefs_db_used_bytes"), "{{ceph_daemon}}")],
        unit="bytes", fill=0, calcs=("lastNotNull",), legend="table", placement="right",
        desc="No separate DB/WAL devices: the DB lives on the OSD's HDD."), 8, 9)

    # Monitors & managers -------------------------------------------------------
    b.row("Monitors and managers", collapsed=True)
    mon = "ceph_daemon, hostname, rank"
    b.add(table("Monitors", [
        q(f"max by ({mon}) (ceph_mon_quorum_status * on (ceph_daemon) group_left (hostname, rank) ceph_mon_metadata)", table=True),
        q(f"max by ({mon}) (ceph_mon_num_sessions * on (ceph_daemon) group_left (hostname, rank) ceph_mon_metadata)", table=True),
        q(f"max by ({mon}) (increase(ceph_mon_num_elections[$__range]) * on (ceph_daemon) group_left (hostname, rank) ceph_mon_metadata)", table=True),
        q(f'max by ({mon}) (ceph_daemon_health_metrics{{type="SLOW_OPS"}} * on (ceph_daemon) group_left (hostname, rank) ceph_mon_metadata)', table=True),
    ], transformations=[MERGE, organize(exclude=["Time"], rename={
        "ceph_daemon": "Monitor", "hostname": "Host", "rank": "Rank", "Value #A": "Quorum", "Value #B": "Sessions",
        "Value #C": "Elections in range", "Value #D": "Slow ops"},
        order=["Monitor", "Host", "Rank", "Quorum", "Sessions", "Elections in range", "Slow ops"])],
        overrides=[cell("Quorum", "color-background"), override("Quorum", {"mappings": QUORUM_MAP}),
                   override("Elections in range", {"decimals": 0, "thresholds": ORANGE_IF_ANY, "custom.cellOptions": {"type": "color-text"}}),
                   override("Slow ops", {"thresholds": RED_IF_ANY, "custom.cellOptions": {"type": "color-text"}})],
        sort="Rank"), 9, 7)
    b.add(table("Managers", [
        q("max by (ceph_daemon, hostname) (ceph_mgr_status * on (ceph_daemon) group_left (hostname) ceph_mgr_metadata)", table=True),
    ], transformations=[organize(exclude=["Time"], rename={"ceph_daemon": "Manager", "hostname": "Host", "Value": "Role"},
                                 order=["Manager", "Host", "Role"])],
        overrides=[cell("Role", "color-background"), override("Role", {"mappings": MGR_MAP})],
        desc="Only the active mgr serves metrics; Prometheus scrapes every mgr host so a failover needs no change.",
        sort="Role", desc_sort=True), 7, 7)
    b.add(stat("Mgr modules", [q("ceph_mgr_module_status > 0", "{{name}}")], text_mode="name",
               mappings=mapping(**{"1": ("enabled", "blue"), "2": ("always on", "green")}),
               thresholds=steps(("green", None)), color_mode="background",
               desc="Enabled mgr modules: blue = enabled by an admin, green = always on."), 8, 7)
    versions = ('count by (type, version) (label_replace(label_replace(ceph_osd_metadata or ceph_mon_metadata '
                'or ceph_mgr_metadata or ceph_mds_metadata, "type", "$1", "ceph_daemon", "([a-z]+)\\\\..*"), '
                '"version", "$1 $2", "ceph_version", "ceph version (\\\\S+) \\\\(\\\\S+\\\\) (\\\\S+).*"))')
    b.add(table("Daemon versions", [q(versions, table=True)],
                transformations=[organize(exclude=["Time"], rename={"type": "Daemon", "version": "Version", "Value": "Count"},
                                          order=["Daemon", "Version", "Count"])],
                desc="More than one version per daemon type means an upgrade is in progress.", sort="Daemon"), 10, 6)
    b.add(timeseries("Monitor sessions", [q("ceph_mon_num_sessions", "{{ceph_daemon}}")], fill=0, decimals=0,
                     calcs=("min", "max", "lastNotNull")), 7, 6)
    b.add(timeseries("Paxos commit latency", [q(lat("ceph_paxos_commit_latency", by="ceph_daemon"), "{{ceph_daemon}}")],
                     unit="s", fill=0, calcs=("mean", "max"), desc="How long the monitors take to commit a map change."), 7, 6)
    b.add(table("Mgr exporter targets", [q('max by (host, instance) (up{job="ceph"})', table=True)],
                transformations=[organize(exclude=["Time"], rename={"host": "Host", "instance": "Target", "Value": "Scrape"})],
                mappings=UP_MAP, overrides=[cell("Scrape", "color-background")],
                desc="Prometheus scrapes every mgr host; standbys answer with an empty page, so they're up but add no series.",
                sort="Host"), 10, 6)
    b.add(timeseries("Mgr prometheus module collection time", [
        q("sum(rate(ceph_prometheus_collect_duration_seconds_sum[$__rate_interval])) by (method) "
          "/ sum(rate(ceph_prometheus_collect_duration_seconds_count[$__rate_interval])) by (method)", "{{method}}")],
        unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right"), 14, 6)

    # CephFS ---------------------------------------------------------------------
    b.row("CephFS", collapsed=True)
    b.add(stat("Filesystem", [q("ceph_fs_metadata", "{{name}}")], text_mode="name", thresholds=BLUE,
               color_mode="background", desc="CephFS filesystems."), 3, 4)
    b.add(stat("Active MDS", [q('ceph_mds_metadata{rank!="-1"}', "{{ceph_daemon}} · rank {{rank}}")], text_mode="name",
               thresholds=GREEN, no_value="no active MDS", desc="MDS daemons holding a rank."), 5, 4)
    b.add(stat("Standby MDS", [q('ceph_mds_metadata{rank="-1"}', "{{ceph_daemon}}")], text_mode="name",
               thresholds=BLUE, no_value="none", desc="Standby MDS daemons ready to take over a rank."), 4, 4)
    b.add(stat("Clients", [q("sum(ceph_mds_sessions_session_count)")], color_mode="value", graph=True,
               thresholds=BLUE, desc="Client sessions on the active MDS (kernel/fuse mounts, PVE nodes)."), 3, 4)
    b.add(stat("Caps", [q("sum(ceph_mds_caps)")], color_mode="value", graph=True, thresholds=BLUE,
               desc="Capabilities handed out to clients."), 2, 4)
    b.add(stat("Files", [q("max(ceph_mds_root_rfiles)")], color_mode="value", thresholds=BLUE,
               desc="Files in the filesystem (recursive count at /)."), 2, 4)
    b.add(stat("Data", [q("max(ceph_mds_root_rbytes)")], unit="bytes", color_mode="value", thresholds=BLUE,
               desc="Bytes in the filesystem (recursive size of /), before replication."), 3, 4)
    b.add(stat("RSS", [q("sum(ceph_mds_mem_rss) * 1024")], unit="bytes", color_mode="value",
               graph=True, thresholds=BLUE, desc="RSS of the active MDS (mds_cache_memory_limit caps the cache)."), 2, 4)
    b.add(timeseries("MDS requests", [
        q("sum by (ceph_daemon) (rate(ceph_mds_request[$__rate_interval]))", "{{ceph_daemon}} requests/s"),
        q("sum by (ceph_daemon) (rate(ceph_mds_forward[$__rate_interval]))", "{{ceph_daemon}} forwarded/s"),
        q("sum by (ceph_daemon) (rate(ceph_mds_slow_reply[$__rate_interval]))", "{{ceph_daemon}} slow replies/s"),
    ], unit="reqps", fill=20, gradient="opacity",
        overrides=[override(".*slow.*", {"color": {"mode": "fixed", "fixedColor": "red"}}, regex=True)]), 8, 8)
    b.add(timeseries("MDS reply latency", [
        q(lat("ceph_mds_reply_latency", by="ceph_daemon"), "{{ceph_daemon}} average")],
        unit="s", fill=20, gradient="opacity", calcs=("mean", "max")), 8, 8)
    b.add(timeseries("Request latency by operation", [
        q(f"sum(rate(ceph_mds_server_req_{op}_latency_sum[$__rate_interval])) / "
          f"sum(rate(ceph_mds_server_req_{op}_latency_count[$__rate_interval])) >= 0", op) for op in MDS_OPS
    ], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        desc="Average MDS service time per request type; idle types drop out."), 8, 8)
    b.add(timeseries("Sessions and caps", [
        q("sum(ceph_mds_sessions_session_count)", "sessions"), q("sum(ceph_mds_caps)", "caps"),
        q("sum(ceph_mds_inodes_with_caps)", "inodes with caps"),
    ], fill=0, decimals=0, overrides=[override("caps|inodes with caps", {"custom.axisPlacement": "right"}, regex=True)]), 8, 8)
    b.add(timeseries("Cap operations", [
        q("sum(rate(ceph_mds_ceph_cap_op_grant[$__rate_interval]))", "grant"),
        q("sum(rate(ceph_mds_ceph_cap_op_revoke[$__rate_interval]))", "revoke"),
        q("sum(rate(ceph_mds_handle_client_cap_release[$__rate_interval]))", "release"),
    ], unit="ops", fill=0), 8, 8)
    b.add(timeseries("MDS cache", [
        q("sum(ceph_mds_inodes)", "inodes"), q("sum(ceph_mds_mem_dn)", "dentries"),
        q("sum(ceph_mds_mem_rss) * 1024", "RSS"),
    ], fill=0, decimals=0, overrides=[override("RSS", {"unit": "bytes", "custom.axisPlacement": "right"})]), 8, 8)
    b.add(timeseries("Journal and purge queue", [
        q("sum(ceph_mds_log_ev)", "journal events"), q("sum(ceph_mds_log_seg)", "journal segments"),
        q("sum(ceph_purge_queue_pq_executing)", "purges in flight"), q("sum(ceph_mds_cache_num_strays)", "strays"),
    ], fill=0, decimals=0, desc="Strays are deleted files waiting for the purge queue."), 12, 7)
    fs_pools = ('label_replace(ceph_fs_metadata, "pool_id", "$1", "data_pools", "(.*)") '
                'or label_replace(ceph_fs_metadata, "pool_id", "$1", "metadata_pool", "(.*)")')
    b.add(timeseries("CephFS pools", [
        q(f"{by_pool('ceph_pool_stored')} and on (pool_id) ({fs_pools})", "{{name}} stored"),
        q(f"{by_pool('ceph_pool_stored_raw')} and on (pool_id) ({fs_pools})", "{{name}} raw"),
    ], unit="bytes", fill=10, calcs=("lastNotNull",),
        desc="Data and metadata pool of each filesystem (one data pool each here)."), 12, 7)

    # RBD ------------------------------------------------------------------------
    b.row("RBD images")
    rng = "$__range"
    active = (f"(rate(ceph_rbd_read_ops[{rng}]) + rate(ceph_rbd_write_ops[{rng}])) > 0")

    def rbd_col(expr):
        return f"max by (pool, image, vmid) ({VMID.format(f'({expr}) and on (pool, namespace, image) ({active})')})"

    b.add(table("RBD images (average over the time range)", [
        q(rbd_col(f"rate(ceph_rbd_read_ops[{rng}])"), table=True),
        q(rbd_col(f"rate(ceph_rbd_write_ops[{rng}])"), table=True),
        q(rbd_col(f"rate(ceph_rbd_read_bytes[{rng}])"), table=True),
        q(rbd_col(f"rate(ceph_rbd_write_bytes[{rng}])"), table=True),
        q(rbd_col(f"(rate(ceph_rbd_read_latency_sum[{rng}]) / rate(ceph_rbd_read_latency_count[{rng}]) / 1e9) >= 0"), table=True),
        q(rbd_col(f"(rate(ceph_rbd_write_latency_sum[{rng}]) / rate(ceph_rbd_write_latency_count[{rng}]) / 1e9) >= 0"), table=True),
    ], desc="Images with any I/O in the selected time range (rbd_stats_pools = ceph_rbd). VM is the Proxmox VM id "
            "from the image name (vm-<id>-disk-N, base-<id>-… for templates).",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "vmid": "VM", "image": "Image", "pool": "Pool", "Value #A": "Read IOPS", "Value #B": "Write IOPS",
            "Value #C": "Read", "Value #D": "Write", "Value #E": "Read latency", "Value #F": "Write latency"},
            order=["VM", "Image", "Pool", "Read IOPS", "Write IOPS", "Read", "Write", "Read latency", "Write latency"])],
        overrides=[*[override(n, {"unit": "iops", "decimals": 2,
                                  "custom.cellOptions": {"type": "gauge", "mode": "gradient", "valueDisplayMode": "text"},
                                  "color": {"mode": "continuous-BlYlRd"}}) for n in ("Read IOPS", "Write IOPS")],
                   *[override(n, {"unit": "Bps", "custom.cellOptions": {"type": "gauge", "mode": "gradient", "valueDisplayMode": "text"},
                                  "color": {"mode": "continuous-BlPu"}}) for n in ("Read", "Write")],
                   *[override(n, {"unit": "s", "thresholds": LAT_S, "custom.cellOptions": {"type": "color-text"}})
                     for n in ("Read latency", "Write latency")]],
        sort="Write IOPS", desc_sort=True), 24, 11)
    img = VMID.format("{}")
    b.add(timeseries("Top 10 images by IOPS", [
        q(img.format("topk(10, sum by (pool, image) (rate(ceph_rbd_read_ops[$__rate_interval]) + rate(ceph_rbd_write_ops[$__rate_interval])))"),
          "VM {{vmid}} · {{image}}")], unit="iops", fill=10, calcs=("mean", "max"), legend="table", placement="right"), 12, 9)
    b.add(timeseries("Top 10 images by throughput", [
        q(img.format("topk(10, sum by (pool, image) (rate(ceph_rbd_read_bytes[$__rate_interval]) + rate(ceph_rbd_write_bytes[$__rate_interval])))"),
          "VM {{vmid}} · {{image}}")], unit="Bps", fill=10, calcs=("mean", "max"), legend="table", placement="right"), 12, 9)
    b.add(timeseries("Top 10 images by write latency", [
        q(img.format("topk(10, (sum by (pool, image) (rate(ceph_rbd_write_latency_sum[$__rate_interval])) / "
                     "sum by (pool, image) (rate(ceph_rbd_write_latency_count[$__rate_interval])) / 1e9) >= 0)"),
          "VM {{vmid}} · {{image}}")], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        desc="Latency seen by librbd (the VM), including the network and all replicas."), 12, 9)
    b.add(timeseries("Top 10 images by read latency", [
        q(img.format("topk(10, (sum by (pool, image) (rate(ceph_rbd_read_latency_sum[$__rate_interval])) / "
                     "sum by (pool, image) (rate(ceph_rbd_read_latency_count[$__rate_interval])) / 1e9) >= 0)"),
          "VM {{vmid}} · {{image}}")], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right"), 12, 9)

    # Hosts (node_exporter) -----------------------------------------------------
    b.row("OSD hosts (node_exporter)", collapsed=True)
    node = 'job="node", role="proxmox"'
    b.add(table("PVE nodes", [
        q('count by (host) (label_replace(ceph_osd_metadata, "host", "$1", "hostname", "(.*)"))', table=True),
        q(f"max by (host) (up{{{node}}})", table=True),
        q(f'100 * (1 - avg by (host) (rate(node_cpu_seconds_total{{mode="idle", {node}}}[5m])))', table=True),
        q(f"max by (host) (100 * (1 - node_memory_MemAvailable_bytes{{{node}}} / node_memory_MemTotal_bytes{{{node}}}))", table=True),
        q(f'max by (host) (node_load5{{{node}}}) / count by (host) (node_cpu_seconds_total{{mode="idle", {node}}})', table=True),
        q(f'max by (host) (100 * avg by (host) (rate(node_disk_io_time_seconds_total{{{node}}}[5m]) and on (host, device) {OSD_DISK}))', table=True),
    ], desc="OSD count per host from Ceph; CPU, memory, load and OSD disk busy % from node_exporter "
            "(job node, role proxmox), joined on the host label. Exporter shows DOWN when a node's "
            "node_exporter isn't scraped.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Host", "Value #A": "OSDs", "Value #B": "Exporter", "Value #C": "CPU", "Value #D": "Memory",
            "Value #E": "Load 5m / CPU", "Value #F": "OSD disks busy"},
            order=["Host", "OSDs", "Exporter", "CPU", "Memory", "Load 5m / CPU", "OSD disks busy"])],
        overrides=[cell("Exporter", "color-background"), override("Exporter", {"mappings": UP_MAP}),
                   *[override(n, {"unit": "percent", "min": 0, "max": 100, "decimals": 1, "thresholds": PERCENT,
                                  "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}})
                     for n in ("CPU", "Memory", "OSD disks busy")],
                   override("Load 5m / CPU", {"decimals": 2, "thresholds": steps(("green", None), ("orange", 0.8), ("red", 1.5)),
                                              "custom.cellOptions": {"type": "color-text"}})],
        sort="Host"), 24, 9)
    b.add(timeseries("OSD disk utilization", [
        q(osd_disk(f"rate(node_disk_io_time_seconds_total{{{node}}}[$__rate_interval])"), "{{ceph_daemon}} ({{host}} {{device}})")],
        unit="percentunit", min_=0, max_=1, fill=0, calcs=("mean", "max"), legend="table", placement="right",
        no_value=NO_NODE, desc="Share of time each OSD's disk was busy (node_exporter, joined via ceph_disk_occupation)."), 12, 9)
    b.add(timeseries("OSD disk await", [
        q(osd_disk(f"rate(node_disk_read_time_seconds_total{{{node}}}[$__rate_interval]) / rate(node_disk_reads_completed_total{{{node}}}[$__rate_interval])"),
          "{{ceph_daemon}} read"),
        q(osd_disk(f"rate(node_disk_write_time_seconds_total{{{node}}}[$__rate_interval]) / rate(node_disk_writes_completed_total{{{node}}}[$__rate_interval])"),
          "{{ceph_daemon}} write"),
    ], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right", no_value=NO_NODE,
        desc="Average time per disk I/O as the kernel sees it."), 12, 9)

    return dashboard("ceph-cluster", "Ceph cluster",
                     "PVE Ceph cluster lylat: health, capacity and forecast, client I/O, PGs and recovery, OSDs, "
                     "slow ops/BlueStore, monitors and managers, CephFS, RBD images and OSD hosts.",
                     b, tags=["ceph", "storage"], extra_links=[CEPH_LINK])


# --- Ceph OSD (drill-down) ------------------------------------------------------

def ceph_osd():
    o = 'ceph_daemon="$osd"'
    b = Board()
    b.row("OSD")
    b.add(stat("State", [q(f"ceph_osd_up{{{o}}} * 2 + ceph_osd_in{{{o}}}")], mappings=OSD_STATE_MAP,
               thresholds=OSD_STATE_STEPS), 3, 5)
    b.add(stat("Host", [q(f"ceph_osd_metadata{{{o}}}", "{{hostname}}")], text_mode="name", thresholds=BLUE,
               links=[("Ceph cluster", CEPH_DASH + "?${__url_time_range}")]), 3, 5)
    b.add(stat("Disk", [q(f'label_replace(max by (devices, device_ids) (ceph_disk_occupation{{{o}}}), '
                          f'"model", "$1", "device_ids", "[^=]*=(.*)")', "{{devices}} · {{model}}")],
               text_mode="name", thresholds=BLUE, desc="Physical device(s) and model/serial under the OSD's LVM volume."), 6, 5)
    b.add(stat("Class / objectstore", [q(f"ceph_osd_metadata{{{o}}}", "{{device_class}} · {{objectstore}}")],
               text_mode="name", thresholds=BLUE), 3, 5)
    b.add(gauge("Used", [q(f"ceph_osd_stat_bytes_used{{{o}}} / ceph_osd_stat_bytes{{{o}}}")], unit="percentunit",
                min_=0, max_=1, decimals=1, thresholds=FILL), 3, 5)
    b.add(stat("Size / PGs / reweight", [
        q(f"ceph_osd_stat_bytes{{{o}}}", "size"), q(f"ceph_osd_numpg{{{o}}}", "PGs"),
        q(f"ceph_osd_weight{{{o}}}", "reweight")],
        text_mode="value_and_name", color_mode="value", thresholds=BLUE,
        overrides=[override("size", {"unit": "bytes"}), override("reweight", {"decimals": 2})]), 6, 5)

    b.add(stat("Apply latency", [q(f"ceph_osd_apply_latency_ms{{{o}}}")], unit="ms", thresholds=LAT_MS,
               color_mode="value", graph=True), 4, 5)
    b.add(stat("Commit latency", [q(f"ceph_osd_commit_latency_ms{{{o}}}")], unit="ms", thresholds=LAT_MS,
               color_mode="value", graph=True), 4, 5)
    b.add(stat("Read latency", [q(lat(f"ceph_osd_op_r_latency{{{o}}}", by=""))], unit="s", thresholds=LAT_S,
               color_mode="value", graph=True), 4, 5)
    b.add(stat("Write latency", [q(lat(f"ceph_osd_op_w_latency{{{o}}}", by=""))], unit="s", thresholds=LAT_S,
               color_mode="value", graph=True), 4, 5)
    b.add(stat("Slow ops in range", [q(f"sum(increase(ceph_trackedop_slow_ops_count{{{o}}}[$__range])) or vector(0)")],
               decimals=0, thresholds=ORANGE_IF_ANY), 4, 5)
    b.add(stat("BlueStore slow ops, 24 h", [
        q(f"sum({' + '.join(f'increase({m}{{{o}}}[24h])' for m in BLUESTORE_SLOW.values())}) or vector(0)")],
        decimals=0, thresholds=ORANGE_IF_ANY,
        desc="The window BLUESTORE_SLOW_OP_ALERT looks at (bluestore_slow_ops_warn_lifetime)."), 4, 5)

    b.row("Client I/O")
    b.add(timeseries("IOPS", [
        q(f"rate(ceph_osd_op_r{{{o}}}[$__rate_interval])", "Read"),
        q(f"rate(ceph_osd_op_w{{{o}}}[$__rate_interval])", "Write"),
        q(f"rate(ceph_osd_op_rw{{{o}}}[$__rate_interval])", "Read-modify-write"),
    ], unit="iops", fill=25, gradient="opacity",
        # Exact names: rw_overrides' regexes match "Read-modify-write" as both Read and Write.
        overrides=[fixed_color("Read", READ),
                   override("Write", {"color": {"mode": "fixed", "fixedColor": WRITE}, "custom.transform": "negative-Y"}),
                   fixed_color("Read-modify-write", "purple")]), 8, 9)
    b.add(timeseries("Throughput", [
        q(f"rate(ceph_osd_op_out_bytes{{{o}}}[$__rate_interval])", "Read"),
        q(f"rate(ceph_osd_op_in_bytes{{{o}}}[$__rate_interval])", "Write"),
    ], unit="Bps", fill=25, gradient="opacity", overrides=rw_overrides()), 8, 9)
    b.add(timeseries("Op latency", [
        q(lat(f"ceph_osd_op_r_latency{{{o}}}"), "Read"),
        q(lat(f"ceph_osd_op_w_latency{{{o}}}"), "Write"),
        q(lat(f"ceph_osd_op_r_process_latency{{{o}}}"), "Read (processing only)"),
        q(lat(f"ceph_osd_op_w_process_latency{{{o}}}"), "Write (processing only)"),
        q(lat(f"ceph_osd_op_before_queue_op_lat{{{o}}}"), "before queue"),
    ], unit="s", fill=0, line=2, overrides=[
        fixed_color("Read", READ), fixed_color("Write", WRITE), fixed_color("Read (processing only)", theme.SERIES[2]),
        fixed_color("Write (processing only)", theme.SERIES[3]), fixed_color("before queue", theme.SERIES[4])],
        desc="Total latency includes time in the OSD's op queue; processing excludes it."), 8, 9)
    b.add(timeseries("Apply and commit latency", [
        q(f"ceph_osd_apply_latency_ms{{{o}}}", "apply"), q(f"ceph_osd_commit_latency_ms{{{o}}}", "commit"),
    ], unit="ms", fill=10), 8, 8)
    b.add(timeseries("Ops in flight", [
        q(f"ceph_osd_op_wip{{{o}}}", "replication ops in progress"),
        q(f"ceph_objecter_op_active{{{o}}}", "objecter ops active"),
    ], fill=10, decimals=0), 8, 8)
    b.add(timeseries("Recovery", [
        q(f"rate(ceph_osd_recovery_bytes{{{o}}}[$__rate_interval])", "bytes/s"),
        q(f"rate(ceph_osd_recovery_ops{{{o}}}[$__rate_interval])", "ops/s"),
    ], unit="Bps", fill=10, overrides=[
        override("ops/s", {"unit": "ops", "custom.axisPlacement": "right",
                           "color": {"mode": "fixed", "fixedColor": ACCENT2}}),
        fixed_color("bytes/s", RECOVERY)]), 8, 8)

    b.row("BlueStore")
    b.add(timeseries("BlueStore latency breakdown", [
        q(lat(f"ceph_bluestore_{m}{{{o}}}"), label) for m, label in (
            ("kv_commit_lat", "kv commit"), ("kv_sync_lat", "kv sync"), ("kv_flush_lat", "kv flush"),
            ("kv_final_lat", "kv final"), ("txc_commit_lat", "txc commit"), ("txc_submit_lat", "txc submit"),
            ("txc_throttle_lat", "txc throttle"), ("state_aio_wait_lat", "aio wait"),
            ("state_kv_queued_lat", "kv queued"), ("read_lat", "read"), ("write_lat", "write"))
    ], unit="s", fill=0, calcs=("mean", "max"), legend="table", placement="right",
        # 11 queries are more than theme.SERIES has colors, so the theme pass leaves them alone: read and
        # write in the directions' colors, the other nine in the remaining series colors.
        overrides=[{"matcher": {"id": "byFrameRefID", "options": chr(65 + i)},
                    "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
                   for i, c in enumerate([*theme.SERIES[2:], WARN_HIGH, READ, WRITE])]), 12, 10)
    b.add(timeseries("BlueStore slow ops", [
        q(f"increase({m}{{{o}}}[$__rate_interval]) > 0", name) for name, m in BLUESTORE_SLOW.items()
    ] + [q(f"increase(ceph_trackedop_slow_ops_count{{{o}}}[$__rate_interval]) > 0", "tracked ops over 10 s")],
        draw="bars", fill=80, stack=True, decimals=0, calcs=("sum",), legend="table", placement="right",
        no_value="No slow ops", desc="Counted per interval; nothing drawn when there were none."), 12, 10)
    b.add(timeseries("Space", [
        q(f"ceph_bluestore_allocated{{{o}}}", "allocated"), q(f"ceph_bluestore_stored{{{o}}}", "stored"),
        q(f"ceph_bluefs_db_used_bytes{{{o}}}", "RocksDB used"),
    ], unit="bytes", fill=10, calcs=("lastNotNull",)), 8, 8)
    b.add(timeseries("Onode cache hit ratio", [
        q(f"rate(ceph_bluestore_onode_hits{{{o}}}[$__rate_interval]) / (rate(ceph_bluestore_onode_hits{{{o}}}[$__rate_interval]) "
          f"+ rate(ceph_bluestore_onode_misses{{{o}}}[$__rate_interval]))", "hit ratio")],
        unit="percentunit", min_=0, max_=1, fill=20, gradient="opacity", overrides=[fixed_color("hit ratio", "green")]), 8, 8)
    b.add(timeseries("Fragmentation", [q(f"ceph_bluestore_fragmentation_micros{{{o}}} / 1e6", "fragmentation")],
                     unit="percentunit", min_=0, fill=10, desc="Allocator fragmentation score (0–1)."), 8, 8)

    b.row("Scrub")
    b.add(timeseries("Scrubs", [
        q(f"increase(ceph_osd_successful_scrubs_replicated{{{o}}}[$__rate_interval]) > 0", "successful"),
        q(f"increase(ceph_osd_failed_scrubs_replicated{{{o}}}[$__rate_interval]) > 0", "failed"),
    ], draw="bars", fill=80, decimals=0, calcs=("sum",), no_value="No scrubs in range",
        overrides=[fixed_color("successful", "green"), fixed_color("failed", "red")]), 12, 7)
    b.add(timeseries("Scrub reads", [
        q(f"rate(ceph_osd_scrub_replicated_read_bytes{{{o}}}[$__rate_interval])", "scrub read bytes/s")],
        unit="Bps", fill=20, gradient="opacity"), 12, 7)

    b.row("Disk (node_exporter)", collapsed=True)
    disk = 'job="node", role="proxmox"'

    def one(expr):
        return f'({expr}) * on (host, device) group_left (ceph_daemon) ({OSD_DISK.replace("ceph_disk_occupation", f"ceph_disk_occupation{{{o}}}")})'

    # One series (the OSD's disk); the {{...}} legend hides that from the theme pass.
    b.add(timeseries("Disk busy", [q(one(f"rate(node_disk_io_time_seconds_total{{{disk}}}[$__rate_interval])"), "{{host}} {{device}}")],
                     unit="percentunit", min_=0, max_=1, fill=20, no_value=NO_NODE,
                     color={"mode": "fixed", "fixedColor": ACCENT2}), 8, 8)
    b.add(timeseries("Disk IOPS", [
        q(one(f"rate(node_disk_reads_completed_total{{{disk}}}[$__rate_interval])"), "Read"),
        q(one(f"rate(node_disk_writes_completed_total{{{disk}}}[$__rate_interval])"), "Write"),
    ], unit="iops", fill=20, overrides=rw_overrides(), no_value=NO_NODE), 8, 8)
    b.add(timeseries("Disk await", [
        q(one(f"rate(node_disk_read_time_seconds_total{{{disk}}}[$__rate_interval]) / rate(node_disk_reads_completed_total{{{disk}}}[$__rate_interval])"), "Read"),
        q(one(f"rate(node_disk_write_time_seconds_total{{{disk}}}[$__rate_interval]) / rate(node_disk_writes_completed_total{{{disk}}}[$__rate_interval])"), "Write"),
    ], unit="s", fill=0, overrides=[fixed_color("Read", READ), fixed_color("Write", WRITE)], no_value=NO_NODE), 8, 8)

    osd_var = query_var("osd", "OSD", "label_values(ceph_osd_metadata, ceph_daemon)", multi=False, include_all=False)
    osd_var["sort"] = 3  # numerical: osd.2 before osd.10
    return dashboard("ceph-osd", "Ceph OSD", "One Ceph OSD: state, latency, I/O, BlueStore internals, slow ops and scrubs.",
                     b, tags=["ceph", "storage"], variables=[osd_var], extra_links=[CEPH_LINK])


DASHBOARDS = {
    "Overview/overview.json": overview,
    "Network/frr-evpn-fabric.json": frr,
    "Probes/blackbox-probes.json": probes,
    "Monitoring/monitoring-stack.json": stack,
    "Storage/ceph-cluster.json": ceph,
    "Storage/ceph-osd.json": ceph_osd,
}


def main():
    sys.modules.setdefault("custom", sys.modules[__name__])  # for the other builders' "from custom import ..."
    sys.path.insert(0, str(HERE))
    sys.dont_write_bytecode = True
    import databases
    import dns
    import fwwan
    import logs
    import loki
    import mimir
    import nginx
    import promtsdb
    import pve
    import rgw
    import snmp
    import telegraf
    import triage
    import wireless
    for rel, build in {**DASHBOARDS, **pve.DASHBOARDS, **fwwan.DASHBOARDS, **logs.DASHBOARDS,
                       **wireless.DASHBOARDS, **rgw.DASHBOARDS, **snmp.DASHBOARDS, **triage.DASHBOARDS,
                       **databases.DASHBOARDS, **nginx.DASHBOARDS, **dns.DASHBOARDS, **promtsdb.DASHBOARDS,
                       **mimir.DASHBOARDS, **loki.DASHBOARDS, **telegraf.DASHBOARDS}.items():
        out = HERE / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        dash = theme.apply_theme(theme.categorize(build(), rel))
        out.write_text(json.dumps(dash, indent=2, ensure_ascii=False) + "\n")
        panels = [p for top in dash["panels"] for p in [top, *top.get("panels", [])] if p["type"] != "row"]
        print(f"{rel}: {dash['title']} ({len(panels)} panels)")
    # Every folder with dashboards must be a category, or the overview wouldn't link it.
    folders = {f.parent.name for f in HERE.glob("*/*.json")} - {"Overview"}
    missing = folders - set(theme.CATEGORIES)
    if missing:
        raise SystemExit(f"folders not in theme.CATEGORIES (the overview's dropdowns): {sorted(missing)}")


if __name__ == "__main__":
    main()
