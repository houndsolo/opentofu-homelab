#!/usr/bin/env python3
"""Download the community dashboards and adapt them for provisioning.

    python3 -I modules/services/monitoring/dashboards/update.py

Sources: grafana.com (pinned revision) and the official ceph-mixin dashboards
from the Ceph tentacle branch (pinned commit). Re-run after bumping a revision or
the commit below. The edits are deliberately small, so a diff against the
upstream JSON stays readable:

- every Prometheus datasource reference points at the provisioned datasource
  (uid "prometheus"); datasource template variables and the import-only
  __inputs/__requires sections are dropped, so no import dialog is needed;
- extra top-bar links where a spec lists them (Node Exporter Full: the host's logs);
- the device/node picker shows the scrape target's "host" label (value stays the
  instance the queries filter on) and lists only targets that have the
  dashboard's metrics;
- a fixed, readable uid, a "lylat" tag and a "Dashboards" dropdown listing every
  dashboard with that tag; the SNMP ones also get an "snmp" tag and a dropdown
  that jumps between them keeping the selected device and time range, and the
  Ceph ones a "ceph" tag and a "Ceph dashboards" dropdown (shared with the
  custom Ceph dashboards), the Proxmox one a "proxmox" tag and a "Proxmox
  dashboards" dropdown (shared with pve.py's);
- InfluxDB references point at the provisioned InfluxDB datasource (uid
  "influxdb"), and the Proxmox bucket picker offers only pve_cluster and
  pve_greatfox;
- per-dashboard fixes for upstream bugs and for what differs here (metric names,
  labels, units, joins): query text replacements ("replace"), panel edits by
  id ("panel_patches") and panels removed by id ("drop_panels": metrics that
  cannot exist here), each failing loudly when upstream no longer matches; and
  the ceph-mixin's leftover graph-panel "negative-Y" series overrides become
  timeseries field overrides, so reads draw below the axis as labelled; singlestat
  panels become native stat/gauge panels and the few legacy graph panels timeseries
  (Grafana 13 has neither plugin), and the run fails if a bump brings one back;
- the desktop palette (theme.py, shared with custom.py): colors mapped by meaning,
  per-query series colors, thin lines with faded fills.

The custom dashboards (overview, FRR, probes, monitoring stack, Ceph cluster and
OSD) are built by custom.py instead.
"""
import json
import pathlib
import sys
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))  # python3 -I leaves the script's directory off the path
import theme  # noqa: E402

# ceph/ceph tentacle branch, monitoring/ceph-mixin/dashboards_out (Ceph 20.2 = tentacle).
CEPH_MIXIN_COMMIT = "804c592824f88ea7e06a9b84a82be359b8dec325"  # 2026-09-30
CEPH_MIXIN_URL = ("https://raw.githubusercontent.com/ceph/ceph/" + CEPH_MIXIN_COMMIT
                  + "/monitoring/ceph-mixin/dashboards_out/{}.json")


def ceph_mixin(name, uid, title, reset_vars=("cluster",)):
    # The mixin's $cluster picker lists label_values(ceph_health_status, cluster): just "lylat".
    return {"url": CEPH_MIXIN_URL.format(name), "source": f"ceph-mixin {name} @ {CEPH_MIXIN_COMMIT[:12]}",
            "uid": uid, "title": title, "group": "ceph", "reset_vars": list(reset_vars)}


# Fixes for upstream bugs and for what differs here. "replace" pairs are plain string
# replacements in every target's PromQL (expr) or Flux (query), or only in the panels
# whose ids an optional third element lists; each must match at least once, so a
# revision bump that changes the text fails loudly instead of silently dropping the
# fix. "panel_patches" maps a panel id to a function that edits it in place;
# "drop_panels" lists the ids of panels to remove (each must exist).

def defaults(**values):
    def patch(panel):
        panel.setdefault("fieldConfig", {}).setdefault("defaults", {}).update(values)
    return patch


def override_property(panel, name, prop, value):
    """Set (or add) property prop of the byName override for field name."""
    for override in panel["fieldConfig"]["overrides"]:
        if override["matcher"] == {"id": "byName", "options": name}:
            props = override["properties"]
            props[:] = [p for p in props if p["id"] != prop]
            if value is not None:
                props.append({"id": prop, "value": value})
            return
    raise SystemExit(f"panel {panel['id']}: no override for {name!r}")


def mikrotik_interfaces(panel):
    # RX/TX Sum are byte counters (mtxrInterfaceStats*Bytes), not bits.
    for name in ("RX Sum", "TX Sum"):
        override_property(panel, name, "unit", "decbytes")
    # Every target carries our relabelled "host" label and the if_mib lookups (ifIndex,
    # ifDescr, ifAlias), so the join suffixes each copy (" 1".." N") and upstream's
    # organize step, which knows only the bare names, lets them all through.
    organize = next(t for t in panel["transformations"] if t["id"] == "organize")["options"]
    for i in range(1, 11):
        organize["excludeByName"][f"host {i}"] = True
        organize["excludeByName"][f"ifDescr {i}"] = True
        organize["excludeByName"][f"ifAlias {i}"] = i > 1
        organize["excludeByName"][f"ifIndex {i}"] = i > 1
    organize["renameByName"].update({"ifAlias 1": "Comment", "ifIndex 1": "Int. index"})
    organize["indexByName"].update({"ifAlias 1": organize["indexByName"]["ifAlias"],
                                    "ifIndex 1": organize["indexByName"]["ifIndex"]})
    # ifAlias is a label here (if_mib lookup), not a metric; the target is always empty.
    panel["targets"] = [t for t in panel["targets"] if t["refId"] != "J"]


NEIGHBOR_LABELS = {"mtxrNeighborIpAddress": "IP", "mtxrNeighborPlatform": "Platform",
                   "mtxrNeighborSoftwareID": "Software ID", "mtxrNeighborVersion": "Firmware version"}


def mikrotik_neighbors(panel):
    # Upstream joins one query per column on mtxrNeighborIndex, but snmp_exporter's
    # bundled mikrotik module drops that index in favour of lookups (ifName, MAC), so the
    # join drops every frame. One query that joins on (ifName, MAC) instead.
    sel = "{instance='$instance'}"
    expr = f"mtxrNeighborIdentity{sel}" + "".join(
        f"\n  * on(ifName, mtxrNeighborMacAddress) group_left({m}) {m}{sel}" for m in NEIGHBOR_LABELS)
    target = panel["targets"][0]
    target.update({"expr": expr, "format": "table", "instant": True, "legendFormat": "", "refId": "A"})
    panel["targets"] = [target]
    names = {"ifName": "Interface", "mtxrNeighborIdentity": "identity",
             "mtxrNeighborMacAddress": "MAC", **NEIGHBOR_LABELS}
    panel["transformations"] = [{"id": "organize", "options": {
        "excludeByName": {k: True for k in ("Time", "Value", "__name__", "host", "instance", "job")},
        "indexByName": {name: i for i, name in enumerate(names)},
        "renameByName": names,
    }}]
    overrides = panel["fieldConfig"]["overrides"]
    overrides[:] = [o for o in overrides if o["matcher"].get("options") != "Neighbor index"]
    panel["options"]["sortBy"] = [{"desc": False, "displayName": "Interface"}]


def pgs_per_osd_histogram(panel):
    # Upstream: a "timeseries" with leftover graph-panel histogram settings and an instant
    # query, i.e. one point per series and no lines. A histogram panel shows the intended
    # distribution (how many OSDs hold how many PGs).
    for key in ("bars", "lines", "points", "xaxis", "yaxes", "legend", "seriesOverrides", "aliasColors",
                "dashLength", "dashes", "fill", "linewidth", "nullPointMode", "percentage", "pointradius",
                "renderer", "spaceLength", "stack", "steppedLine", "thresholds", "timeFrom", "timeShift",
                "tooltip", "fillGradient", "hiddenSeries", "options"):
        panel.pop(key, None)
    panel.update({
        "type": "histogram",
        "options": {"combine": True, "bucketCount": 10,
                    "legend": {"showLegend": False, "displayMode": "list", "placement": "bottom", "calcs": []}},
        "fieldConfig": {"defaults": {"unit": "short", "custom": {"fillOpacity": 80, "lineWidth": 1}},
                        "overrides": []},
    })


def steps(*pairs):
    """Absolute threshold steps from (color, value) pairs; the first is the base (value None)."""
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in pairs]}


def time_till_full(panel):
    # Upstream passes the singlestat arguments shifted (valueName false = mean, thresholds
    # "current") and divides by a zero growth rate (+Inf, which "> 0" keeps) for pools that
    # do not grow. Only growing pools return a series; no series reads "not filling".
    # Current value; red under 7 days, orange under 30.
    set_expr("A", '(ceph_pool_max_avail{cluster=~"$cluster|", } / deriv(ceph_pool_stored{cluster=~"$cluster|", }[6h])) *\n'
                  '  on(pool_id) group_left(instance, name) ceph_pool_metadata{name=~"$pool_name", cluster=~"$cluster|", } > 0\n',
             '(ceph_pool_max_avail{cluster=~"$cluster|", } / (deriv(ceph_pool_stored{cluster=~"$cluster|", }[6h]) > 0)) *\n'
             '  on(pool_id) group_left(instance, name) ceph_pool_metadata{name=~"$pool_name", cluster=~"$cluster|", }\n')(panel)
    panel["fieldConfig"]["defaults"].update(
        color={"mode": "thresholds"}, noValue="not filling",
        thresholds=steps(("red", None), ("orange", 604800), ("green", 2592000)))
    panel["options"]["reduceOptions"]["calcs"] = ["lastNotNull"]


def onode_hit_ratio(panel):
    # Upstream colors a healthy ratio (>= .75) orange and a poor one green: low is bad.
    panel["fieldConfig"]["defaults"].update(color={"mode": "thresholds"},
                                            thresholds=steps(("red", None), ("orange", 0.5), ("green", 0.75)))


def pool_overview_colors(panel):
    # % Used is a 0..1 fraction (red base, green above 70/85 never fit it); Growth is a
    # byte delta the same steps mean nothing for.
    override_property(panel, "Value #D", "thresholds", {"mode": "absolute", "steps": [
        {"color": "green", "value": None}, {"color": "orange", "value": 0.7}, {"color": "red", "value": 0.85}]})
    override_property(panel, "Value #F", "custom.cellOptions", {"type": "auto"})
    override_property(panel, "Value #F", "thresholds", None)
    # Target I's application label has no header of its own.
    add_override(panel, "application", displayName="Application")
    # Leftover empty target (expr "", intervalFactor ""), which the backend rejects.
    panel["targets"] = [t for t in panel["targets"] if t.get("expr")]


def add_override(panel, name, **props):
    """Append a byName override for field name with the given properties."""
    panel.setdefault("fieldConfig", {}).setdefault("overrides", []).append(
        {"matcher": {"id": "byName", "options": name}, "properties": [{"id": k, "value": v} for k, v in props.items()]})


def frame_colors(panel, colors=theme.SERIES):
    # One palette color per query. theme.py colors these only when each legend is fixed;
    # here the {{label}} in the legend is pinned by an = matcher, so each returns one series.
    targets = [t for t in panel["targets"] if not t.get("hide")]
    panel["fieldConfig"].setdefault("overrides", []).extend(
        {"matcher": {"id": "byFrameRefID", "options": t["refId"]},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": colors[i]}}]}
        for i, t in enumerate(targets))


def hide_time_columns(*names):
    # Instant table queries: a constant Time column (and labels nobody needs) next to the values.
    def patch(panel):
        panel.setdefault("transformations", []).append(
            {"id": "organize", "options": {"excludeByName": {n: True for n in ("Time", *names)},
                                           "indexByName": {}, "renameByName": {}}})
    return patch


def status_colors(colors):
    # The upstream thresholds' last (red) step has no value, so every non-up state was
    # orange. Color the states by meaning through the value mappings instead.
    def patch(panel):
        options = panel["fieldConfig"]["defaults"]["mappings"][0]["options"]
        for value, c in colors.items():
            options[value]["color"] = c
        panel["fieldConfig"]["defaults"]["thresholds"] = steps(("green", None), ("orange", 2))
    return patch


def load_avg_right_axis(panel):
    for override in panel["fieldConfig"]["overrides"]:
        if override["matcher"] == {"id": "byName", "options": "avg1"}:
            override["matcher"] = {"id": "byFrameRefID", "options": "C"}
            return
    raise SystemExit(f"panel {panel['id']}: no override for 'avg1'")


def organize_rename(**names):
    def patch(panel):
        organize = next(t for t in panel["transformations"] if t["id"] == "organize")["options"]
        organize["renameByName"].update(names)
        if "nodename" in names:  # upstream orders _time, host, _value; the node goes before the uptime
            organize["indexByName"].update(nodename=2, _value=3)
    return patch


def set_expr(ref, old, new):
    """Replace one target's whole expression (fails if upstream's is no longer old)."""
    def patch(panel):
        target = next(t for t in panel["targets"] if t["refId"] == ref)
        if target["expr"] != old:
            raise SystemExit(f"panel {panel['id']} target {ref}: upstream expr changed: {target['expr']!r}")
        target["expr"] = new
    return patch


def chain(*patches):
    def patch(panel):
        for p in patches:
            p(panel)
    return patch


def ceph_heatmap_seconds(panel):
    # rate(..._latency_sum)/rate(..._count) is in seconds, not ms.
    panel["options"]["yAxis"]["unit"] = "s"
    panel["yAxis"]["format"] = "s"


NOT_ON_THIS_HOST = defaults(noValue="N/A on this host")

LEGEND_CALCS = {"avg": "mean", "current": "lastNotNull", "max": "max", "min": "min", "total": "sum"}


def graph_to_timeseries(right=(), no_value=None):
    """Convert a legacy "graph" panel (no plugin in Grafana 13) to a timeseries panel.

    The upstream aliasColors and seriesOverrides name the author's own series (SSIDs,
    192.168.5.1), so they are dropped; the queries in right (refIds) go on the right
    axis with the second y-axis' unit. Legend hideZero becomes the same byValue
    override Grafana's own migration adds.
    """
    def patch(panel):
        yaxes = panel.get("yaxes") or [{}, {}]
        legend = panel.get("legend") or {}
        custom = {"drawStyle": "bars" if panel.get("bars") and not panel.get("lines", True) else "line",
                  "lineWidth": panel.get("linewidth", 1), "fillOpacity": 10 * panel.get("fill", 1),
                  "showPoints": "always" if panel.get("points") else "never", "pointSize": 5,
                  "spanNulls": panel.get("nullPointMode") == "connected",
                  "lineInterpolation": "stepAfter" if panel.get("steppedLine") else "linear",
                  "stacking": {"group": "A", "mode": "normal" if panel.get("stack") else "none"},
                  "axisPlacement": "auto"}
        fc_defaults = {"unit": yaxes[0].get("format") or "short", "custom": custom, "color": {"mode": "palette-classic"}}
        overrides = [{"matcher": {"id": "byFrameRefID", "options": ref},
                      "properties": [{"id": "custom.axisPlacement", "value": "right"},
                                     {"id": "unit", "value": yaxes[1].get("format") or "short"}]} for ref in right]
        if legend.get("hideZero"):
            overrides.append({"matcher": {"id": "byValue", "options": {"reducer": "allIsZero", "op": "gte", "value": 0}},
                              "properties": [{"id": "custom.hideFrom",
                                              "value": {"viz": False, "legend": True, "tooltip": True}}]})
        if no_value:
            fc_defaults["noValue"] = no_value
        options = {"legend": {"showLegend": legend.get("show", True),
                              "displayMode": "table" if legend.get("alignAsTable") else "list",
                              "placement": "right" if legend.get("rightSide") else "bottom",
                              "calcs": [c for k, c in LEGEND_CALCS.items() if legend.get(k)]},
                   "tooltip": {"mode": "multi" if (panel.get("tooltip") or {}).get("shared") else "single",
                               "sort": "none"}}
        for key in ("aliasColors", "bars", "dashLength", "dashes", "fill", "fillGradient", "hiddenSeries", "legend",
                    "lines", "linewidth", "nullPointMode", "percentage", "pluginVersion", "pointradius", "points",
                    "renderer", "seriesOverrides", "spaceLength", "stack", "steppedLine", "thresholds", "timeRegions",
                    "tooltip", "xaxis", "yaxes", "yaxis"):
            panel.pop(key, None)
        panel.update(type="timeseries", options=options, fieldConfig={"defaults": fc_defaults, "overrides": overrides})
    return patch


SINGLESTAT_KEYS = ("cacheTimeout", "colorBackground", "colorPostfix", "colorPrefix", "colorValue", "colors", "decimals",
                   "format", "gauge", "mappingType", "mappingTypes", "nullPointMode", "nullText", "postfix",
                   "postfixFontSize", "prefix", "prefixFontSize", "rangeMaps", "sparkline", "tableColumn", "thresholds",
                   "valueFontSize", "valueMaps", "valueName")
SINGLESTAT_CALCS = {"current": "lastNotNull", "avg": "mean", "min": "min", "max": "max", "total": "sum",
                    "first": "firstNotNull", "delta": "delta", "diff": "diff", "range": "range"}


def migrate_singlestat(dash):
    # Grafana 13 has no singlestat plugin; it converts these on every load and loses the
    # colors on the way. Native stat panels (gauge where the singlestat drew a gauge):
    # threshold colors where upstream set thresholds, else the theme's single-series cyan.
    # The null -> "N/A" maps only ever covered null values and are dropped.
    for panel in all_panels(dash):
        if panel.get("type") != "singlestat":
            continue
        colors = panel.get("colors") or ["green", "orange", "red"]
        try:
            levels = [float(x) for x in str(panel.get("thresholds") or "").split(",") if x.strip()]
        except ValueError:  # pool-detail's shifted arguments ("current"); its patch sets the steps
            levels = []
        fc_defaults = {"unit": panel.get("format") or "none", "mappings": []}
        if levels:
            fc_defaults["color"] = {"mode": "thresholds"}
            fc_defaults["thresholds"] = steps((colors[0], None),
                                              *((colors[min(i + 1, len(colors) - 1)], v) for i, v in enumerate(levels)))
        else:
            fc_defaults["color"] = {"mode": "fixed", "fixedColor": theme.ACCENT2}
            fc_defaults["thresholds"] = steps((theme.ACCENT2, None))
        if panel.get("decimals") is not None:
            fc_defaults["decimals"] = panel["decimals"]
        if panel.get("nullText"):
            fc_defaults["noValue"] = panel["nullText"]
        reduce = {"calcs": [SINGLESTAT_CALCS.get(panel.get("valueName"), "lastNotNull")], "fields": "", "values": False}
        gauge = panel.get("gauge") or {}
        if gauge.get("show"):
            ptype = "gauge"
            options = {"reduceOptions": reduce, "orientation": "auto",
                       "showThresholdMarkers": bool(gauge.get("thresholdMarkers", True)),
                       "showThresholdLabels": bool(gauge.get("thresholdLabels"))}
            for key in ("min", "max"):
                value = gauge.get(key + "Value")
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    fc_defaults[key] = value
        else:
            ptype = "stat"
            options = {"reduceOptions": reduce, "colorMode": "background" if panel.get("colorBackground") else "value",
                       "graphMode": "area" if (panel.get("sparkline") or {}).get("show") is True else "none",
                       "justifyMode": "auto", "orientation": "horizontal", "textMode": "auto"}
        for key in SINGLESTAT_KEYS:
            panel.pop(key, None)
        panel.update(type=ptype, options=options, fieldConfig={"defaults": fc_defaults, "overrides": []})


def snmp_throughput_panel(panel):
    graph_to_timeseries()(panel)
    panel.update(gridPos={"x": 0, "y": 0, "w": 12, "h": 8}, repeatDirection="h", maxPerRow=2)
    panel.pop("span", None)
    panel["fieldConfig"]["defaults"]["unit"] = "bps"
    frame_colors(panel, [theme.ACCENT2, theme.ACCENT])


# file (relative to this directory, subdirectory = Grafana folder) => upstream
DASHBOARDS = {
    "Network/snmp-interface-throughput-community.json": {
        "gnet_id": 1124, "revision": 1, "uid": "snmp-throughput-community", "group": "snmp",
        "title": "SNMP Interface Throughput (community)", "refresh": "1m", "legacy_rows": True,
        "picker": {"var": "Device", "metric": 'ifHCInOctets{job=~"snmp-fs-switches|snmp-mikrotik-access|snmp-spines|snmp-wlc|snmp-mikrotik-hr"}', "label": "Device"},
        "var_patches": {"Interface": {
            "query": 'label_values(ifHCInOctets{instance="$Device",job=~"snmp-fs-switches|snmp-mikrotik-access|snmp-spines|snmp-wlc|snmp-mikrotik-hr"}, ifDescr)',
            "regex": "", "hide": 0, "label": "Interface", "allValue": ".*", "current": {},
        }},
        "replace": [
            ("job='snmp'", 'job=~"snmp-fs-switches|snmp-mikrotik-access|snmp-spines|snmp-wlc|snmp-mikrotik-hr"'),
            ("ifDescr='$Interface'", 'ifDescr=~"${Interface:regex}"'),
            ("[5m]", "[$__rate_interval]"),
            ("irate(ifHCOutOctets", "-irate(ifHCOutOctets"),
            ("irate(ifOutOctets", "-irate(ifOutOctets"),
        ],
        "panel_patches": {1: snmp_throughput_panel},
    },
    "Network/snmp-device-summary.json": {
        "gnet_id": 12489, "revision": 5, "uid": "snmp-device-summary", "group": "snmp",
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
        "panel_patches": {
            # Upstream lists every interface of every device here.
            10: set_expr("A", "ifPhysAddress", 'ifPhysAddress{instance="$instance"}'),
            # irate() drops __name__, so `in or out` always kept only in: rank by max(in, out).
            # count() of nothing is no series, not 0: say 0 when no admin-up interface is down.
            5: set_expr("A", 'count(ifOperStatus{instance="$instance"} != 1 and ifAdminStatus{instance="$instance"} == 1)',
                         'count(ifOperStatus{instance="$instance"} != 1 and ifAdminStatus{instance="$instance"} == 1) or vector(0)'),
            8: set_expr("A", 'topk(5, irate(ifHCInOctets{instance="$instance"}[5m]) or irate(ifInOctets{instance="$instance"}[5m]) or irate(ifHCOutOctets{instance="$instance"}[5m]) or irate(ifOutOctets{instance="$instance"}[5m]))*8',
                         'topk(5, (irate(ifHCInOctets{instance="$instance"}[5m]) > irate(ifHCOutOctets{instance="$instance"}[5m])'
                         ' or irate(ifHCOutOctets{instance="$instance"}[5m])) * 8)'),
        },
    },
    "Network/snmp-interface-detail.json": {
        "gnet_id": 12492, "revision": 4, "uid": "snmp-interface-detail", "group": "snmp",
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
        "panel_patches": {
            # IN/OUT legends carry {{ifName}}, but $ifName is a single value: one series per query.
            **{pid: frame_colors for pid in (2, 3, 4, 5, 6, 7)},
            9: status_colors({"1": "green", "2": "orange", "3": "yellow"}),
            10: status_colors({"1": "green", "2": "red", "3": "yellow", "4": "orange", "5": "yellow",
                               "6": "orange", "7": "red"}),
            # RouterOS does not serve ifConnectorPresent / ifPromiscuousMode.
            11: chain(status_colors({"1": "green", "2": "orange"}), defaults(noValue="N/A on this device")),
            12: defaults(noValue="N/A on this device"),
        },
    },
    "Network/mikrotik-snmp.json": {
        "gnet_id": 14420, "revision": 9, "uid": "mikrotik-snmp", "group": "snmp",
        "picker": {"var": "instance", "metric": "mtxrBoardName", "label": "Device"},
        "drop_vars": ["Job"],  # hidden and unused by any panel
        "refresh": "1m",       # upstream refreshes every 10s; we scrape every 30s
        "replace": [
            # The system module exports sysName (the RouterOS identity), there is no sysIdentity.
            ("sysIdentity{instance='$instance'}", "sysName{instance='$instance'}"),
            # ifSpeed is a 32-bit gauge (4294967295 on 10G ports); ifHighSpeed is in Mb/s.
            ("ifSpeed{instance='$instance'}", "ifHighSpeed{instance='$instance'}*1000000"),
            # We scrape several modules per device: one series each; the stats want the total.
            *((f"{m}{{instance='$instance'}}", f"sum({m}{{instance='$instance'}})") for m in (
                "snmp_scrape_duration_seconds", "snmp_scrape_walk_duration_seconds", "snmp_scrape_pdus_returned")),
        ],
        "panel_patches": {
            1264: lambda p: p["targets"][0].update(legendFormat="{{sysName}}"),
            # These boards export the CPU temperature as mtxrHlProcessorTemperature (panel
            # "CPU Temp" already falls back like this).
            1262: set_expr("B", "mtxrHlTemperature{instance='$instance'}/10",
                           "mtxrHlProcessorTemperature{instance='$instance'}/10 or mtxrHlTemperature{instance='$instance'}/10"),
            1275: mikrotik_interfaces,
            1652: mikrotik_neighbors,
            # Upstream shows the sample's timestamp (fields /^Time$/), not the device's clock.
            1325: chain(set_expr("A", "time()-(hrSystemDate{instance='$instance'})", "hrSystemDate{instance='$instance'} * 1000"),
                        lambda p: p["options"]["reduceOptions"].update(fields="")),
            # Legacy graph panels (no plugin in Grafana 13).
            1659: graph_to_timeseries(),
            1671: graph_to_timeseries(),
            1270: graph_to_timeseries(right=("B",), no_value="No wireless"),  # B: noise floor, dBm
            1640: graph_to_timeseries(right=("B",), no_value="No modem"),     # B: EC/IO, dB
            # Features none of the switches here has (no PoE, radios, W60G, queues): say so.
            **{pid: defaults(noValue="No PoE") for pid in (1276, 1277, 1278, 1279)},
            **{pid: defaults(noValue="No wireless") for pid in (1261, 1613, 1643, 1647, 1648)},
            **{pid: defaults(noValue="No CAPsMAN") for pid in (1678, 1679, 1681)},
            **{pid: defaults(noValue="No W60G") for pid in range(1706, 1717)},
            **{pid: defaults(noValue="No queues") for pid in (1268, 1282, 1510, 1549)},
        },
    },
    # Works for job=node (hosts) and job=vyos-node (VyOS routers): pick the job, then the host.
    "Hosts/node-exporter-full.json": {
        "gnet_id": 1860, "revision": 46, "uid": "node-exporter-full",
        "picker": {"var": "node", "metric": 'node_uname_info{job="$job"}', "label": "Host"},
        "drop_vars": ["nodename"],  # only fed the old instance picker; the host picker replaces both
        "reset_vars": ["job"],      # no saved selection from the upstream author
        # The picked host's logs (logs.py; its host picker ignores case, Prometheus has leaf-11, Loki LEAF-11).
        "links": [{"type": "link", "title": "Logs of this host", "icon": "doc", "tags": [], "tooltip": "",
                   "url": "/d/logs-overview/logs-overview?var-host=${node:text}", "includeVars": False,
                   "keepTime": True, "asDropdown": False, "targetBlank": False}],
        # VyOS's / is an overlay, which node_exporter skips; the persistence mount under it
        # has the same size and usage.
        "replace": [('mountpoint="/", fstype!="rootfs"', 'mountpoint=~"/|/usr/lib/live/mount/persistence", fstype!="rootfs"'),
                    ('mountpoint="/",fstype!="rootfs"', 'mountpoint=~"/|/usr/lib/live/mount/persistence",fstype!="rootfs"')],
        # Hardware/kernel features that VMs (and some nodes) do not have: say so instead of "No data".
        # So do optional collectors (tcpstat, processes, interrupts on PVE/VyOS; systemd and
        # DirectMap on VyOS; zswap). Upstream's "0" on the TCP panels claimed no connections.
        "panel_patches": {
            **{pid: NOT_ON_THIS_HOST for pid in (158, 300, 325, 344, 302, 345, 321, 61, 320, 341, 340, 313, 314,
                                                 315, 259, 298, 331, 297, 332, 128, 342)},
            21: defaults(noValue="No swap"),  # used / SwapTotal of 0
        },
    },
    # Official Ceph dashboards (the ones the Ceph dashboard embeds). The headline "Ceph
    # cluster" and "Ceph OSD" dashboards are custom.py's; these add depth. rgw, nvmeof,
    # smb and hardware ones are left out (not deployed here); so are the host ones, which
    # join node_exporter on the instance label (ours is host; osd-device-details has the
    # same join in its physical device row and gets it rewritten below).
    "Storage/ceph-cluster-advanced.json": {
        **ceph_mixin("ceph-cluster-advanced", "ceph-cluster-advanced", "Ceph cluster advanced (mixin)"),
        # PGs State: metric names that Ceph 20.2 does not export.
        "replace": [("sum(ceph_pg_wait_backfill{", "sum(ceph_pg_backfill_wait{"),
                    ("sum(ceph_pg_backfill{", "sum(ceph_pg_backfilling{"),
                    ('sum(ceph_unclean_pgs{cluster=~"$cluster|", })',
                     'sum(ceph_pg_total{cluster=~"$cluster|", }) - sum(ceph_pg_clean{cluster=~"$cluster|", })')],
        "panel_patches": {
            18: defaults(unit="Bps"),  # upstream: bytes for a rate
            19: defaults(unit="ops"),  # upstream: bytes for op/s
            # OSD op latencies are in seconds, upstream labels them ms.
            33: ceph_heatmap_seconds,
            34: ceph_heatmap_seconds,
            35: chain(defaults(unit="s"), lambda p: p.update(title="OSD Read/Write Op Latency")),
            # Byte totals against the mixin's 0.025/0.1 steps: the sparkline was always red.
            **{pid: defaults(color={"mode": "fixed", "fixedColor": theme.ACCENT2}, thresholds=steps((theme.ACCENT2, None)))
               for pid in (5, 11)},
            8: lambda p: override_property(p, "All", "color", {"mode": "fixed", "fixedColor": theme.INFO}),
            26: lambda p: p.update(title="Total Objects"),  # it plots sum(ceph_pool_objects)
        },
    },
    "Storage/ceph-osds-overview.json": {
        **ceph_mixin("osds-overview", "ceph-osds-overview", "Ceph OSDs overview (mixin)"),
        "panel_patches": {
            9: pgs_per_osd_histogram,
            10: onode_hit_ratio,
            # Device classes (count by device_class): palette colors instead of Grafana's classic ones.
            6: lambda p: [add_override(p, cls, color={"mode": "fixed", "fixedColor": c})
                          for cls, c in (("hdd", theme.ACCENT2), ("ssd", theme.ACCENT), ("nvme", theme.OK))],
            # Size buckets are categories: no error red (SERIES[7]) for one of them.
            8: lambda p: frame_colors(p, [c for c in theme.SERIES if c != theme.ERROR]),
            13: set_expr("A", 'topk(10,\n  (ceph_daemon_health_metrics{type="SLOW_OPS", ceph_daemon=~"osd.*"})\n)\n',
                         'topk(10,\n  (ceph_daemon_health_metrics{type="SLOW_OPS", ceph_daemon=~"osd.*", cluster=~"$cluster|"})\n)\n'),
        },
    },
    "Storage/ceph-osd-device-details.json": {
        **ceph_mixin("osd-device-details", "ceph-osd-device-details", "Ceph OSD device details (mixin)"),
        # The physical device panels join node_exporter's instance (host:port cut at the
        # first ":" or ".", i.e. "10" for an IP) with ceph's host name. Take the host label
        # instead; ceph_disk_occupation_human has none, so its instance stays as it is.
        "replace": [('"instance", "$1", "instance", "([^:.]*).*"', '"instance", "$1", "host", "(.+)"')],
        "panel_patches": {5: defaults(unit="Bps")},  # a rate, upstream says bytes
    },
    "Storage/ceph-pools-overview.json": {
        **ceph_mixin("pool-overview", "ceph-pools-overview", "Ceph pools overview (mixin)"),
        # Writes added ceph_pool_metadata (always 1) instead of joining on it.
        "replace": [('rate(ceph_pool_wr{cluster=~"$cluster|", }[$__rate_interval]) +\n  on(pool_id)',
                     'rate(ceph_pool_wr{cluster=~"$cluster|", }[$__rate_interval]) *\n  on(pool_id)'),
                    # 0 rather than N/A when no pool compresses
                    ('count(ceph_pool_metadata{compression_mode!="none", cluster=~"$cluster|", })',
                     'count(ceph_pool_metadata{compression_mode!="none", cluster=~"$cluster|", }) or vector(0)')],
        "panel_patches": {
            10: pool_overview_colors,
            **{pid: defaults(noValue="no compressed pools") for pid in (8, 9)},
        },
    },
    "Storage/ceph-pool-details.json": {
        **ceph_mixin("pool-detail", "ceph-pool-details", "Ceph pool details (mixin)"),
        # Throughput added ceph_pool_metadata (always 1) instead of joining on it.
        "replace": [("[$__rate_interval]) +\n  on(pool_id)", "[$__rate_interval]) *\n  on(pool_id)")],
        "panel_patches": {3: time_till_full},
    },
    "Storage/ceph-rbd-overview.json": {
        **ceph_mixin("rbd-overview", "ceph-rbd-overview", "Ceph RBD overview (mixin)"),
        # Highest Latency divided by at least 1 op/s, understating images doing fewer.
        "replace": [("[$__rate_interval]), 1)", "[$__rate_interval]), 1e-9)")],
        "panel_patches": {pid: hide_time_columns("cluster", "instance", "job", "namespace") for pid in (5, 6, 7)},
    },
    "Storage/ceph-rbd-details.json": {
        **ceph_mixin("rbd-details", "ceph-rbd-details", "Ceph RBD details (mixin)"),
        # Templates (base-*) and cloud-init drives come first alphabetically and never do I/O.
        "var_patches": {"image": {"regex": r"/^vm-\d+-disk-\d+$/", "sort": 1}},
        "panel_patches": {2: frame_colors, 3: frame_colors,
                          4: chain(frame_colors, defaults(noValue="No I/O on this image"))},
    },
    "Storage/ceph-filesystem.json": {
        **ceph_mixin("cephfsdashboard", "ceph-filesystem", "Ceph filesystem (mixin)", reset_vars=("cluster", "name")),
        "replace": [
            # Usage mixed raw used (bytes_used, after replication) with net max_avail: use the
            # net stored figure; "Raw Used" named a metric that does not exist (bytes_used is raw).
            # (The "Data/Metadata used" stats stay raw, like ceph df's USED.)
            ("ceph_pool_bytes_used", "ceph_pool_stored", (13, 15, 42, 44, 48, 50)),
            ("ceph_pool_raw_bytes_used", "ceph_pool_bytes_used"),
            # Data pool "Total" added the metadata pool's max_avail.
            ('pool_id=~"^$datapool$"}) + sum(ceph_pool_max_avail{cluster=~"$cluster|",  pool_id=~"^$mdatapool$"})',
             'pool_id=~"^$datapool$"}) + sum(ceph_pool_max_avail{cluster=~"$cluster|",  pool_id=~"^$datapool$"})'),
            # Ceph 20.2: mem_rss is KiB, mem_heap bytes; the panel is kbytes.
            ('ceph_mds_mem_heap{cluster=~"$cluster|"}', 'ceph_mds_mem_heap{cluster=~"$cluster|"} / 1024'),
        ],
        # MDS row: CPU (ceph_mds_rank_perf_cpu_usage) and Open Requests
        # (ceph_mds_rank_perf_open_requests) are counters Ceph 20.2 does not have (not in the
        # MDS's perf dump, never exported), so the panels could only ever say No data.
        "drop_panels": [53, 54],
        "panel_patches": {
            # Reply latency is in seconds, upstream labels it ms.
            18: defaults(unit="s"), 27: defaults(unit="s"),
            # Memory takes the row on its own once CPU and Open Requests are gone.
            55: lambda p: p["gridPos"].update(x=0, w=24),
            # 0..1 ratios with the red step at 80: as panels 13/15, orange at 70 %, red at 80 %.
            **{pid: defaults(thresholds=steps(("green", None), ("orange", 0.7), ("red", 0.8))) for pid in (44, 50)},
        },
    },
    # PVE external metric server in InfluxDB 2 (Flux). The most used one; the newer ones on
    # grafana.com are forks of it. The custom Proxmox dashboards (pve.py) go further.
    "Proxmox/proxmox-cluster-flux.json": {
        "gnet_id": 15356, "revision": 14, "uid": "proxmox-cluster-flux", "group": "proxmox",
        "title": "Proxmox cluster [Flux] (community)",
        "bucket_var": "Bucket",  # upstream lists every bucket (buckets()); offer only the PVE ones
        # The LXC panels compared nodename with the (multi-value, regex formatted) server
        # variable, matching nothing unless exactly one server is picked.
        "replace": [('r["nodename"] == "${server}"', 'r["nodename"] =~ /^${server:regex}$/'),
                    # Disk counters restart with the guest (restart, migration): no negative rates.
                    ("|> derivative(unit: 1s)\n", "|> derivative(unit: 1s, nonNegative: true)\n", (30, 31))],
        "panel_patches": {
            # Guest CPU is a 0..1 fraction of the guest's CPUs.
            26: defaults(unit="percentunit", min=0),
            28: chain(defaults(unit="percentunit", min=0), defaults(noValue="No containers")),
            # Load average to the right axis: Flux fields carry labels, so byName "avg1" never matched.
            21: chain(defaults(displayName="${__field.labels.host} ${__field.name}"), load_avg_right_axis),
            24: defaults(displayName="${__field.labels.host} ${__field.name}"),
            27: defaults(displayName="${__field.labels.host} ${__field.labels.nodename}"),
            29: defaults(displayName="${__field.labels.host}", noValue="No containers"),
            16: chain(organize_rename(nodename="Node"), defaults(noValue="No running VMs")),
            19: chain(organize_rename(host="Container"), defaults(noValue="No containers")),
            **{pid: defaults(noValue="No containers") for pid in (32, 33)},
            # derivative(unit: 1s): rates, not byte counts.
            34: defaults(unit="Bps"), 35: defaults(unit="Bps"),
            **{pid: defaults(unit="Bps", noValue="No containers") for pid in (36, 37)},
        },
    },
}

NAV_LINK = {
    "type": "dashboards", "tags": ["lylat"], "asDropdown": True, "title": "Dashboards",
    "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
    "tooltip": "", "url": "",
}
SNMP_LINK = {
    "type": "dashboards", "tags": ["snmp"], "asDropdown": True, "title": "SNMP dashboards",
    "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
    "tooltip": "", "url": "",
}
CEPH_LINK = {
    "type": "dashboards", "tags": ["ceph"], "asDropdown": True, "title": "Ceph dashboards",
    "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
    "tooltip": "", "url": "",
}
PROXMOX_LINK = {
    "type": "dashboards", "tags": ["proxmox"], "asDropdown": True, "title": "Proxmox dashboards",
    "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
    "tooltip": "", "url": "",
}
GROUP_LINKS = {"snmp": SNMP_LINK, "ceph": CEPH_LINK, "proxmox": PROXMOX_LINK}

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
INFLUXDB = {"type": "influxdb", "uid": "influxdb"}  # Flux, org lylat
PVE_BUCKETS = "lylat cluster : pve_cluster,greatfox : pve_greatfox"
UPSTREAM_DS_UIDS = {"${DS_MAYA}", "${DS_PROMETHEUS}", "$DS_PROMETHEUS", "$source", "${source}", "PBFA97CFB590B2093",
                    "${ds_prometheus}", "$ds_prometheus", "$datasource", "${datasource}"}


def fix_datasources(node):
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and ds.get("type") == "influxdb":
            node["datasource"] = dict(INFLUXDB)
        elif isinstance(ds, dict) and (ds.get("type") == "prometheus" or ds.get("uid") in UPSTREAM_DS_UIDS):
            node["datasource"] = dict(PROMETHEUS)
        elif isinstance(ds, str) and ds in UPSTREAM_DS_UIDS:
            node["datasource"] = dict(PROMETHEUS)
        for value in node.values():
            fix_datasources(value)
    elif isinstance(node, list):
        for value in node:
            fix_datasources(value)


def all_panels(dash):
    for panel in dash.get("panels", []):
        yield panel
        yield from panel.get("panels", [])  # collapsed rows hold their panels


def replace_queries(dash, pairs, rel):
    for old, new, *only in pairs:
        hits = 0
        for panel in all_panels(dash):
            if only and panel.get("id") not in only[0]:
                continue
            for target in panel.get("targets", []):
                for key in ("expr", "query"):
                    if isinstance(target.get(key), str) and old in target[key]:
                        hits += target[key].count(old)
                        target[key] = target[key].replace(old, new)
        if not hits:
            raise SystemExit(f"{rel}: query replacement no longer matches: {old!r}")


def drop_panels(dash, ids, rel):
    missing = set(ids)
    for holder in [dash, *(p for p in dash.get("panels", []) if "panels" in p)]:
        kept = [p for p in holder["panels"] if p.get("id") not in missing]
        missing -= {p.get("id") for p in holder["panels"]} - {p.get("id") for p in kept}
        holder["panels"] = kept
    if missing:
        raise SystemExit(f"{rel}: drop_panels: no panel with id {sorted(missing)}")


def migrate_negative_y(dash):
    # The ceph-mixin ships "timeseries" panels that still carry the old graph panel's
    # seriesOverrides; Grafana converts those only when the panel was a "graph", so reads
    # are drawn above the axis that says "Read (-) / Write (+)".
    for panel in all_panels(dash):
        if panel.get("type") != "timeseries" or not panel.get("seriesOverrides"):
            continue
        keep = []
        for so in panel["seriesOverrides"]:
            if set(so) != {"alias", "transform"} or so["transform"] != "negative-Y":
                keep.append(so)
                continue
            alias = so["alias"]
            matcher = ({"id": "byRegexp", "options": alias[1:-1]} if len(alias) > 1 and alias[0] == alias[-1] == "/"
                       else {"id": "byName", "options": alias})
            panel.setdefault("fieldConfig", {}).setdefault("overrides", []).append(
                {"matcher": matcher, "properties": [{"id": "custom.transform", "value": "negative-Y"}]})
        if keep:
            panel["seriesOverrides"] = keep
        else:
            panel.pop("seriesOverrides")


def adapt(dash, spec, rel=""):
    for key in ("__inputs", "__elements", "__requires", "iteration"):
        dash.pop(key, None)
    dash["id"] = None
    dash["uid"] = spec["uid"]
    if "title" in spec:
        dash["title"] = spec["title"]
    if "refresh" in spec:
        dash["refresh"] = spec["refresh"]

    # Opt in only for Grafana 4 sources: modern dashboards can retain an empty
    # "rows" key alongside their real "panels". Never discard those panels.
    if spec.get("legacy_rows"):
        if dash.get("panels"):
            raise SystemExit(f"{rel}: legacy_rows would discard existing panels")
        dash["panels"] = [p for row in dash.pop("rows") for p in row["panels"]]
        dash["schemaVersion"] = 41
    variables = dash["templating"]["list"]
    variables[:] = [
        v for v in variables
        if v.get("type") != "datasource" and v["name"] not in spec.get("drop_vars", [])
    ]
    picker = spec.get("picker", {"var": None})
    for v in variables:
        if v["name"] == picker["var"]:
            query = f"query_result(count by (host, instance) ({picker['metric']}))"
            v.update({
                "definition": query,
                "query": {"query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
                # query_result lines look like {host="m326-1",instance="10.5.0.5"} 30 1700000000000
                "regex": '/host="(?<text>[^"]+)".*instance="(?<value>[^"]+)"/',
                "label": picker["label"],
                "sort": 1,
                "current": {},
            })
            v.pop("options", None)
        elif v["name"] in spec.get("reset_vars", []):
            v["current"] = {}
            v.pop("options", None)
        elif v["name"] == spec.get("bucket_var"):
            for key in ("datasource", "definition", "regex", "sort"):
                v.pop(key, None)
            v.update({"type": "custom", "query": PVE_BUCKETS, "label": "Cluster", "options": [],
                      "current": {"text": "lylat cluster", "value": "pve_cluster", "selected": True}})
    var_patches = dict(spec.get("var_patches", {}))
    for v in variables:
        if v["name"] in var_patches:
            v.update(var_patches.pop(v["name"]))
    if var_patches:
        raise SystemExit(f"{rel}: no variable {sorted(var_patches)}")
    fix_datasources(dash)
    replace_queries(dash, spec.get("replace", []), rel)
    migrate_negative_y(dash)
    migrate_singlestat(dash)
    drop_panels(dash, spec.get("drop_panels", []), rel)
    patches = dict(spec.get("panel_patches", {}))
    for panel in all_panels(dash):
        if panel.get("id") in patches:
            patches.pop(panel["id"])(panel)
    if patches:
        raise SystemExit(f"{rel}: no panel with id {sorted(patches)}")
    # Grafana 13 has neither plugin; a revision bump that brings one back should say so.
    legacy = [p["id"] for p in all_panels(dash) if p.get("type") in ("graph", "singlestat")]
    if legacy:
        raise SystemExit(f"{rel}: legacy graph/singlestat panels left: {legacy}")

    group = spec.get("group")
    dash["tags"] = sorted(set(dash.get("tags", [])) | {"lylat"} | ({group} if group else set()))
    links = [link for link in dash.get("links", []) if link.get("type") != "dashboards"]
    dash["links"] = ([dict(GROUP_LINKS[group])] if group else []) + [dict(NAV_LINK)] + spec.get("links", []) + links
    return dash


def main():
    for rel, spec in DASHBOARDS.items():
        if "url" in spec:
            url, source = spec["url"], spec["source"]
        else:
            url = f"https://grafana.com/api/dashboards/{spec['gnet_id']}/revisions/{spec['revision']}/download"
            source = f"grafana.com {spec['gnet_id']} rev {spec['revision']}"
        with urllib.request.urlopen(url, timeout=30) as resp:
            dash = json.loads(resp.read().decode(), strict=False)
        upstream_title = dash["title"]
        out = HERE / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(theme.apply_theme(adapt(dash, spec, rel)), indent=2, ensure_ascii=False) + "\n")
        print(f"{rel}: {upstream_title} ({source})")


if __name__ == "__main__":
    main()
