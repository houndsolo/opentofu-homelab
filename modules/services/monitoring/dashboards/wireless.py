"""The wireless dashboards (folder Network): C9800 overview and one wireless client.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with
its helpers; see custom.py for the conventions. The data is the C9800 WLCs'
model-driven telemetry (gRPC dial-out to Telegraf on mon01, roots/monitoring-config
README "C9800 telemetry") in the InfluxDB bucket "wlc", read through the provisioned
InfluxDB datasource (uid "influxdb", Flux). The measurement, tag and field names are
the ones Telegraf's cisco_telemetry_mdt input writes, as captured in
~/network_automation/wlc-telemetry/fields.md:

- measurement = the YANG encoding path (Cisco-IOS-XE-<module>:<container>/<list>), so
  the names are long; M below holds them;
- tags: source (the WLC's hostname, c9800-wlc-1/2: the same as the SNMP jobs' host
  label), plus the list keys, which are named differently per tree: a client is
  client_mac (common-oper-data), ms_mac_address (traffic-stats, dot11-oper-data) or
  mac_addr (sisf-db-mac); an AP radio is wtp_mac + radio_slot_id (radio-oper-data,
  rrm-measurement) or ap_mac + slot_id (radio-oper-stats);
- fields: the YANG leaf path below the list entry, "/"-separated (r["phy_ht_cfg/cfg_data/curr_freq"]).

Quirks the queries handle:

- Entries vanish instead of going to 0 (a client leaves, an AP drops): "now" values are
  the newest sample in the last 3 minutes of the time range (capwap-data and the RRM
  lists come every 60 s, the rest every 30 s).
- AP-reported counters only change every 90 s (client traffic, per-SSID stats) or 180 s
  (radio and AP uplink counters); the WLC re-sends the old value in between. Rates take
  the last value per window of at least 3 minutes (RATE) before the derivative, so they
  don't read 0, 0, spike.
- traffic-stats directions are the AP's: bytes_tx is sent to the client (download),
  bytes_rx received from it (upload).
- c9800-wlc-2 has no APs or clients: it only reports CPU, memory and the global counts.

Known gap (WLC side, not fixable here): IOS XE 26.01.1's kvGPB dial-out leaves the first
(lowest-key) entry of every multi-entry wireless oper list out of each periodic update; only
the first update after a (re)connect has it. That is radio slot 0 (2.4 GHz) in radio-oper-*,
wtp-slot-wlan-stats and rrm-measurement/*, the lowest WLAN id in wlan-client-stats, and the
lowest client MAC in the client-oper-data lists. Checked 2026-11-10: a packet capture of the
gRPC stream lacks those rows, a NETCONF yang-push subscription to the same xpaths has them,
and Telegraf keeps such rows (and zero-valued keys) when they arrive. Single-entry lists and
the platform lists (memory, per-core CPU, load average) are complete.
Workaround (2026-11-10, ~/network_automation/wlc-telemetry/wlc-config.md "Workaround subscriptions"):
extra subscriptions 601-603/606 (+608 on wlc-1, 609 on wlc-2) select the missing entries with
full-key xpath predicates; single-entry streams arrive complete under the same measurement names,
so slot 0's radio-oper-data/-stats, rrm load, slot 0 x WLAN 4 and the lowest WLAN's client counts
are back. Still missing: 2.4 GHz rrm noise/foreign (the WLC rejects per-channel predicates) and
the lowest client MAC (changes with the clients). FIRST_ENTRY_GAP is the note the affected panels
carry; drop it once the WLC sends the whole list.
"""
import textwrap

from custom import (
    BLUE, GREEN, ORANGE_IF_ANY, PERCENT, RED_IF_ANY, UP_MAP, UP_STEPS, Board, bargauge, cell, dashboard,
    fixed_color, gauge, hidden, mapping, organize, override, q, stat, state_timeline, steps, table, timeseries,
)
from theme import ACCENT, ACCENT2, SERIES
from pve import bars, field_links, joined, text_stat

INFLUX = {"type": "influxdb", "uid": "influxdb"}
BUCKET = "wlc"  # wlc_telemetry.bucket in roots/monitoring-config
UIDS = {"overview": "wireless-overview", "client": "wireless-client"}
WIFI_LINK = {"type": "dashboards", "tags": ["wireless"], "asDropdown": True, "title": "Wireless dashboards",
             "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
             "tooltip": "", "url": ""}
TIME_URL = "${__url_time_range}"
LOGS_NET = "/d/logs-network/logs-network"
SNMP_SUMMARY = "/d/snmp-device-summary/snmp-device-summary"
SNMP_DETAIL = "/d/snmp-interface-detail/snmp-interface-detail"
WLC_IPS = {"c9800-wlc-1": "10.5.1.1", "c9800-wlc-2": "10.5.1.2"}  # snmp_targets.wlc (SNMP instance = IP)
DOWN, UP = ACCENT2, ACCENT  # client download (bytes_tx) / upload (bytes_rx)
FIRST_ENTRY_GAP = (" Known gap: the WLC's telemetry drops the first entry of each list; extra per-entry subscriptions "
                   "restore the 2.4 GHz radio and the lowest WLAN, but the client with the lowest MAC and the 2.4 GHz "
                   "noise/interference scan stay missing; see wireless.py.")
# What the panels show instead of a bare "No data" when nothing matches (c9800-wlc-2 has no APs or clients).
NO_AP = "No APs joined to the selected WLCs"
NO_AP_RANGE = NO_AP + " in this time range"
NO_CLIENTS = "No clients on the selected WLCs"
NO_CLIENTS_RANGE = NO_CLIENTS + " in this time range"
NOT_SEEN = "Client not seen in this time range (pick a client / WLC)"

_AP = "Cisco-IOS-XE-wireless-access-point-oper:access-point-oper-data/"
_CL = "Cisco-IOS-XE-wireless-client-oper:client-oper-data/"
_RRM = "Cisco-IOS-XE-wireless-rrm-oper:rrm-oper-data/rrm-measurement/"
_CTRL = "Cisco-IOS-XE-platform-software-oper:cisco-platform-software/control-processes/control-process"
M = {
    # Controller (both WLCs).
    "cpu": "Cisco-IOS-XE-process-cpu-oper:cpu-usage/cpu-utilization",                       # IOSd CPU %
    "mem": "Cisco-IOS-XE-memory-oper:memory-statistics/memory-statistic",                   # IOSd pools (tag name), bytes
    "ctrl": _CTRL,                                                                          # Linux memory (KiB), HA state
    "core": _CTRL + "/per-core-stats/per-core-stat",                                        # Linux CPU per core (tag name)
    "load": _CTRL + "/load-avg-minutes/load-avg-minute",                                    # tag number 1/5/15
    "live": "Cisco-IOS-XE-wireless-client-global-oper:client-global-oper-data/client-live-stats",
    "wlan_clients": "Cisco-IOS-XE-wireless-ap-global-oper:ap-global-oper-data/wlan-client-stats",  # tag wlan_id
    "ap_stats": "Cisco-IOS-XE-wireless-ap-global-oper:ap-global-oper-data/ewlc-ap-stats",  # radios up/down/total
    # APs (tag wtp_mac unless noted).
    "capwap": _AP + "capwap-data",
    "names": _AP + "ap-name-mac-map",                     # tag wtp_name, field wtp_mac
    "radio": _AP + "radio-oper-data",                     # + radio_slot_id
    "band": _AP + "radio-oper-data/radio-band-info",      # + radio_slot_id, band_id: tx power
    "vap": _AP + "radio-oper-data/vap-oper-config",       # + radio_slot_id, ap_vap_id: SSIDs per radio
    "radio_stats": _AP + "radio-oper-stats",              # ap_mac + slot_id: counters, aid_user_list
    "slot_wlan": _AP + "wtp-slot-wlan-stats",             # + slot_id, wlan_id: per radio x SSID traffic
    "eth": _AP + "ethernet-if-stats",                     # + if_index: AP uplink
    "rrm_load": _RRM + "load",                            # + radio_slot_id: channel utilization
    "noise": _RRM + "noise/noise",                        # + radio_slot_id, noise_data/chan
    "foreign": _RRM + "foreign/foreign",                  # + radio_slot_id, foreign_data/chan
    # Clients.
    "common": _CL + "common-oper-data",                   # client_mac
    "traffic": _CL + "traffic-stats",                     # ms_mac_address
    "dot11": _CL + "dot11-oper-data",                     # ms_mac_address
    "sisf": _CL + "sisf-db-mac",                          # mac_addr: IP bindings
}

# --- Flux --------------------------------------------------------------------------
#
# Like pve.py: plain Flux with %(name)s placeholders, %(m_<key>)s for a measurement filter.
FRAGMENTS = {
    "src": f'from(bucket: "{BUCKET}")',
    "range": "range(start: v.timeRangeStart, stop: v.timeRangeStop)",
    "now": "range(start: date.sub(d: 3m, from: v.timeRangeStop), stop: v.timeRangeStop)",
    # Enough history for a rate at the end of the time range (counters change every 90-180 s).
    "now_rate": "range(start: date.sub(d: 10m, from: v.timeRangeStop), stop: v.timeRangeStop)",
    "wlc": "r.source =~ /^${wlc:regex}$/",
    # Counter -> per-second rate over windows of at least 3 minutes (see the docstring).
    "rate": "aggregateWindow(every: every, fn: last, createEmpty: false)\n"
            "  |> derivative(unit: 1s, nonNegative: true)",
    "rate3m": "aggregateWindow(every: 3m, fn: last, createEmpty: false)\n"
              "  |> derivative(unit: 1s, nonNegative: true)\n"
              "  |> last()",
    "mean": "aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)",
    "lastw": "aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)",
    "band_name": 'if r.band == "dot11-2-dot-4-ghz-band" then "2.4 GHz" else if r.band == "dot11-6-ghz-band" then "6 GHz" '
                 'else if r.band == "dot11-5-ghz-band" then "5 GHz" else r.band',
    **{f"m_{k}": f'r._measurement == "{v}"' for k, v in M.items()},
}
EVERY = "every = if int(v: v.windowPeriod) > int(v: 3m) then v.windowPeriod else 3m"

# Lookup tables (Flux statements) the queries join on.
LOOKUPS = {
    # source, wtp_mac -> ap (the AP's name).
    "ap_names": """
        ap_names = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_names)s and r._field == "wtp_mac" and %(wlc)s)
          |> last()
          |> group()
          |> map(fn: (r) => ({source: r.source, wtp_mac: r._value, ap: r.wtp_name}))""",
    # source, wtp_mac, radio_slot_id -> radio ("lylat-AP-1 · 5 GHz (slot 1)"), band.
    "radios": """
        radio_bands = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_radio)s and r._field == "current_active_band" and %(wlc)s)
          |> last()
          |> group()
          |> map(fn: (r) => ({source: r.source, wtp_mac: r.wtp_mac, radio_slot_id: r.radio_slot_id, band: r._value}))
        radios = join.left(left: radio_bands, right: ap_names,
            on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac,
            as: (l, r) => ({l with ap: if exists r.ap then r.ap else l.wtp_mac}))
          |> map(fn: (r) => ({r with band: %(band_name)s}))
          |> map(fn: (r) => ({r with radio: r.ap + " · " + r.band + " (slot " + r.radio_slot_id + ")"}))""",
    # source, mac -> ip (IPv4 from the SISF binding table).
    "client_ips": """
        client_ips = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_sisf)s and r._field == "ipv4_binding/ip_key/ip_addr" and %(wlc)s)
          |> last()
          |> group()
          |> map(fn: (r) => ({source: r.source, mac: r.mac_addr, ip: r._value}))""",
    # source, wlan_id -> ssid.
    "ssids": """
        ssids = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_slot_wlan)s and r._field == "ssid" and %(wlc)s)
          |> last()
          |> group()
          |> unique(column: "wlan_id")
          |> map(fn: (r) => ({source: r.source, wlan_id: r.wlan_id, ssid: r._value}))""",
}
LOOKUP_DEPS = {"radios": ["ap_names"]}


def flux(text, *lookups, **kw):
    """Fills the placeholders, adds the lookups (with what they need), the window and the imports."""
    needed = []
    for name in lookups:
        for dep in [*LOOKUP_DEPS.get(name, []), name]:
            if dep not in needed:
                needed.append(dep)
    parts = [textwrap.dedent(LOOKUPS[n]).strip() for n in needed] + [textwrap.dedent(text).strip()]
    body = "\n".join(parts) % {**FRAGMENTS, **kw}
    if "every: every" in body:
        body = EVERY + "\n" + body
    imports = [f'import "{m}"' for m in ("date", "join", "regexp", "strings") if f"{m}." in body]
    return "\n".join(imports + [body])


def fx(text, *lookups, **kw):
    return {"datasource": INFLUX, "query": flux(text, *lookups, **kw)}


def fields(*names):
    return "(" + " or ".join(f'r._field == "{n}"' for n in names) + ")"


def labelled(expr):
    """Names each series by a Flux string expression (Grafana shows the one label as the legend)."""
    return (f"map(fn: (r) => ({{r with series: {expr}}}))\n"
            '  |> group(columns: ["series"])\n'
            '  |> sort(columns: ["_time"])\n'
            '  |> keep(columns: ["_time", "_value", "series"])')


def on_influx(p):
    p["datasource"] = dict(INFLUX)
    for t in p["targets"]:
        t.setdefault("datasource", dict(INFLUX))
    return p


def empty(p, text):
    """Shows text instead of "No data" when the panel has nothing to show. The override takes it off the fields
    again (null unsets it), so missing table cells stay blank and tooltips skip series without a point."""
    p["fieldConfig"]["defaults"]["noValue"] = text
    p["fieldConfig"]["overrides"].append(override(".*", {"noValue": None}, regex=True))
    return p


def empty_notes(b, texts):
    """empty() for the panels of board b named in texts ({title: text})."""
    found = {p["title"]: p for top in b.panels for p in [top, *top.get("panels", [])] if p["type"] != "row"}
    for title, text in texts.items():
        empty(found[title], text)


def url_link(title, url, icon="dashboard"):
    return {"type": "link", "title": title, "url": url, "icon": icon, "includeVars": False, "keepTime": True,
            "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}


def wlc_var():
    query = flux('''
        import "influxdata/influxdb/schema"
        schema.tagValues(bucket: "%(bucket)s", tag: "source",
          predicate: (r) => %(m_cpu)s, start: v.timeRangeStart, stop: v.timeRangeStop)''', bucket=BUCKET)
    return {"name": "wlc", "label": "WLC", "type": "query", "datasource": INFLUX, "query": query,
            "definition": query, "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*",
            "current": {"selected": True, "text": ["All"], "value": ["$__all"]}, "options": [], "sort": 1,
            "regex": "", "hide": 0}


def client_var():
    """Clients seen in the time range, most recently seen first (sort 0 keeps that order), so the default is a
    client that is there now. schema.tagValues reads the series index, which isn't exact about time: it listed
    clients gone for hours, and the first of them (ascending) became the default."""
    query = flux('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_common)s and r._field == "ap_name" and %(wlc)s)
          |> last()
          |> group()
          |> sort(columns: ["_time"], desc: true)
          |> unique(column: "client_mac")
          |> keep(columns: ["client_mac"])
          |> rename(columns: {client_mac: "_value"})''')
    return {"name": "client", "label": "Client (MAC)", "type": "query", "datasource": INFLUX, "query": query,
            "definition": query, "refresh": 2, "multi": False, "includeAll": False, "current": {}, "options": [],
            "sort": 0, "regex": "", "hide": 0}


def client_cisco_var():
    """The selected client's MAC in Cisco dotted form (9445.607a.12a8), the way C9800 syslog writes it:
    the "WLC logs" link searches the logs for it. Hidden; the client MAC itself if it isn't 12 hex digits."""
    query = flux('''
        import "array"
        m = strings.replaceAll(v: "${client}", t: ":", u: "")
        cisco = if strings.strlen(v: m) == 12 then strings.substring(v: m, start: 0, end: 4) + "."
          + strings.substring(v: m, start: 4, end: 8) + "." + strings.substring(v: m, start: 8, end: 12)
          else "${client}"
        array.from(rows: [{_value: cisco}])''')
    return {"name": "client_cisco", "type": "query", "datasource": INFLUX, "query": query, "definition": query,
            "refresh": 1, "multi": False, "includeAll": False, "current": {}, "options": [], "sort": 0,
            "regex": "", "hide": 2}


# Value mappings for the enum strings.
RADIO_STATE_MAP = mapping(**{"radio-up": ("up", "green"), "radio-down": ("down", "red")})
AP_STATE_MAP = mapping(registered=("registered", "green"))
UPLINK_MAP = mapping(**{"oper-state-up": ("up", "green"), "oper-state-down": ("down", "red")})
CLIENT_STATE_MAP = mapping(**{"client-status-run": ("run", "green"), "client-status-authenticating": ("auth", "orange"),
                              "client-status-ip-learn": ("IP learn", "orange"),
                              "client-status-webauth-pending": ("webauth", "orange")})
HA_MAP = mapping(**{"ha-role-active": ("active", "green"), "ha-role-standby": ("standby", "blue")})
HEALTH_MAP = mapping(Healthy=("Healthy", "green"))
RSSI = steps(("red", None), ("orange", -80), ("yellow", -70), ("green", -60))
SNR = steps(("red", None), ("orange", 15), ("yellow", 25), ("green", 35))
CCA = steps(("green", None), ("yellow", 40), ("orange", 60), ("red", 80))
NOISE = steps(("green", None), ("yellow", -85), ("orange", -80), ("red", -75))
AGE = steps(("green", None), ("orange", 120), ("red", 300))


def color_cell(name, thresholds, unit=None):
    props = {"thresholds": thresholds, "custom.cellOptions": {"type": "color-text"}}
    if unit:
        props["unit"] = unit
    return override(name, props)


def mapped(name, mappings):
    return override(name, {"mappings": mappings, "custom.cellOptions": {"type": "color-text"}})


# --- shared queries ---------------------------------------------------------------------

def per_radio(measurement, field, *, mac="wtp_mac", slot="radio_slot_id", fn="lastw", scale="", suffix=""):
    """One series per AP radio, named by the radios lookup. fn: lastw/mean for gauges, rate for counters."""
    rename = "" if mac == "wtp_mac" else (
        f'\n  |> map(fn: (r) => ({{r with wtp_mac: r.{mac}, radio_slot_id: r.{slot}}}))')
    return flux(f"""
        data = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_{measurement})s and r._field == "{field}" and %(wlc)s)
          |> %({fn})s{scale}{rename}
          |> group()
        join.left(left: data, right: radios,
            on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac and l.radio_slot_id == r.radio_slot_id,
            as: (l, r) => ({{l with radio: if exists r.radio then r.radio else l.wtp_mac + " slot " + l.radio_slot_id}}))
          |> {labelled("r.radio" + (f' + " {suffix}"' if suffix else ""))}""", "radios")


def per_client(measurement_key, field, *, fn="lastw", scale="", mac="ms_mac_address", suffix=""):
    """One series per client, named "MAC (IP)" (IP from the SISF table when known)."""
    end = f' + " {suffix}"' if suffix else ""
    return flux(f"""
        data = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_{measurement_key})s and r._field == "{field}" and %(wlc)s)
          |> %({fn})s{scale}
          |> map(fn: (r) => ({{r with mac: r.{mac}}}))
          |> group()
        join.left(left: data, right: client_ips,
            on: (l, r) => l.source == r.source and l.mac == r.mac,
            as: (l, r) => ({{l with ip: if exists r.ip then r.ip else ""}}))
          |> {labelled(f'(if r.ip == "" then r.mac else r.mac + " (" + r.ip + ")"){end}')}""", "client_ips")


BITS = "\n  |> map(fn: (r) => ({r with _value: r._value * 8.0}))"
NEG = "\n  |> map(fn: (r) => ({r with _value: -r._value}))"  # drawn below the axis


def snmp_wlc_traffic():
    """The WLCs' own interfaces from SNMP (Prometheus job snmp-wlc): the data plane next to the telemetry."""
    sel = 'job="snmp-wlc", host=~"${wlc:regex}", ifName=~"Gi.*"'
    return timeseries("WLC interfaces (SNMP)", [
        q(f"rate(ifHCInOctets{{{sel}}}[$__rate_interval]) * 8", "{{host}} {{ifName}} in"),
        q(f"-rate(ifHCOutOctets{{{sel}}}[$__rate_interval]) * 8", "{{host}} {{ifName}} out"),
    ], unit="bps", fill=10, desc="The C9800s' GigabitEthernet ports from SNMP (job snmp-wlc), in up, out down. "
                                 "Click through for the SNMP interface dashboards.",
        links=[(f"SNMP Device Summary ({h})", f"{SNMP_SUMMARY}?var-instance={ip}&{TIME_URL}")
               for h, ip in WLC_IPS.items()])


# --- Wireless (C9800) overview -------------------------------------------------------

def overview():
    b = Board()

    b.row("Status")
    b.add(on_influx(stat("Clients", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_live)s and r._field == "run_state_clients" and %(wlc)s)
          |> last()
          |> group()
          |> sum()''')], color_mode="value", thresholds=BLUE, decimals=0,
        desc="Clients in RUN state on the selected WLCs (client-live-stats).")), 3, 4)
    b.add(on_influx(stat("APs joined", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_capwap)s and r._field == "ap_state/ap_operation_state" and %(wlc)s)
          |> last()
          |> filter(fn: (r) => r._value == "registered")
          |> group()
          |> count()''')], color_mode="value", thresholds=steps(("red", None), ("green", 1)), decimals=0,
        no_value="0", desc="APs whose CAPWAP state is registered (capwap-data, sent every 60 s). An AP that "
                           "leaves just stops reporting, so it drops out of the count.")), 3, 4)
    b.add(on_influx(stat("Radios up / total", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_ap_stats)s and %(f)s and %(wlc)s)
          |> last()
          |> group(columns: ["_field"])
          |> sum()
          |> map(fn: (r) => ({_value: r._value, series: if r._field == "stats_80211_all_rad/radios_up" then "up" else "total"}))
          |> group(columns: ["series"])''',
        f=fields("stats_80211_all_rad/radios_up", "stats_80211_all_rad/total_radios"))],
        color_mode="value", thresholds=BLUE, decimals=0, text_mode="value_and_name",
        desc="All AP radios joined to the selected WLCs (ewlc-ap-stats).")), 4, 4)
    b.add(on_influx(stat("Radios down", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_ap_stats)s and r._field == "stats_80211_all_rad/radios_down" and %(wlc)s)
          |> last()
          |> group()
          |> sum()''')], thresholds=ORANGE_IF_ANY, decimals=0,
        desc="Radios that are joined but not up: admin down or, like the C9130's second 5 GHz (XOR) radio "
             "here, not in use.")), 3, 4)
    b.add(on_influx(stat("WLANs with clients", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_wlan_clients)s and r._field == "client_curr_state_run" and %(wlc)s)
          |> last()
          |> filter(fn: (r) => r._value > 0)
          |> group()
          |> count()''')], color_mode="value", thresholds=BLUE, decimals=0, no_value="0")), 3, 4)
    b.add(on_influx(stat("Telemetry age", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_cpu)s and r._field == "five_seconds" and %(wlc)s)
          |> last()
          |> map(fn: (r) => ({source: r.source, _value: float(v: uint(v: now()) - uint(v: r._time)) / 1000000000.0}))
          |> group(columns: ["source"])''')], unit="s", decimals=0, thresholds=AGE, text_mode="value_and_name",
        desc="Seconds since each WLC's last CPU sample (every 30 s). Over 2 minutes: the dial-out to Telegraf on "
             "mon01 is broken (see the Monitoring stack dashboard and journalctl -u telegraf).")), 5, 4)
    b.add(stat("WLC SNMP", [q('up{job="snmp-wlc", host=~"${wlc:regex}"}', "{{host}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS, desc="Prometheus' SNMP scrape of the WLCs (job snmp-wlc)."), 3, 4)

    # Controllers -------------------------------------------------------------------------
    b.row("Controllers")
    b.add(on_influx(table("Controllers", [
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_ctrl)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({source: r.source, ha: r.high_availability_state,
                  mem_pct: r["memory_stats/used_percent"], mem_status: r["memory_stats/memory_status"]}))''',
           f=fields("high_availability_state", "memory_stats/used_percent", "memory_stats/memory_status")),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_core)s and r._field == "idle" and %(wlc)s)
              |> last()
              |> group(columns: ["source"])
              |> mean()
              |> group()
              |> map(fn: (r) => ({source: r.source, cpu: 100.0 - float(v: r._value)}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_cpu)s and r._field == "one_minute" and %(wlc)s)
              |> last()
              |> group()
              |> map(fn: (r) => ({source: r.source, iosd: r._value}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_load)s and r.number == "1" and r._field == "average" and %(wlc)s)
              |> last()
              |> group()
              |> map(fn: (r) => ({source: r.source, load1: r._value}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_live)s and r._field == "run_state_clients" and %(wlc)s)
              |> last()
              |> group()
              |> map(fn: (r) => ({source: r.source, clients: r._value}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_ap_stats)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({source: r.source, radios_up: r["stats_80211_all_rad/radios_up"],
                  radios: r["stats_80211_all_rad/total_radios"]}))''',
           f=fields("stats_80211_all_rad/radios_up", "stats_80211_all_rad/total_radios")),
    ], desc="Per WLC, now. Linux CPU is the mean busy % over the control-plane cores; IOSd CPU the 1-minute "
            "figure of the IOS daemon alone (usually near 0 on a C9800-CL). Click a WLC for its log lines.",
        transformations=[joined("source"), organize(rename={
            "source": "WLC", "ha": "HA role", "cpu": "Linux CPU", "iosd": "IOSd CPU (1m)", "load1": "Load (1m)",
            "mem_pct": "Memory used", "mem_status": "Memory status", "clients": "Clients",
            "radios_up": "Radios up", "radios": "Radios"},
            order=["WLC", "HA role", "Clients", "Radios up", "Radios", "Linux CPU", "IOSd CPU (1m)", "Load (1m)",
                   "Memory used", "Memory status"])],
        overrides=[
            mapped("HA role", HA_MAP), mapped("Memory status", HEALTH_MAP),
            override("Linux CPU", {"unit": "percent", "decimals": 1, "thresholds": PERCENT,
                                   "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"},
                                   "min": 0, "max": 100}),
            override("Memory used", {"unit": "percent", "decimals": 0, "thresholds": PERCENT,
                                     "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"},
                                     "min": 0, "max": 100}),
            override("IOSd CPU (1m)", {"unit": "percent"}), override("Load (1m)", {"decimals": 2}),
            override("WLC", {"links": [{"title": "Log lines of ${__value.text}", "targetBlank": False,
                                        "url": f"{LOGS_NET}?var-device=${{__value.text}}&{TIME_URL}"}]}),
        ], sort="WLC")), 24, 5)
    b.add(on_influx(timeseries("Linux CPU busy per core", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_core)s and r._field == "idle" and %(wlc)s)
          |> map(fn: (r) => ({r with _value: 100.0 - float(v: r._value)}))
          |> %(mean)s
          |> %(series)s''', series=labelled('r.source + " core " + r.name'))],
        unit="percent", min_=0, fill=0, desc="100 - idle for each control-plane core (per-core-stat, a 5 s sample "
                                              "every 30 s).")), 8, 8)
    b.add(on_influx(timeseries("Linux memory used", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_ctrl)s and r._field == "memory_stats/used_percent" and %(wlc)s)
          |> %(mean)s
          |> %(series)s''', series=labelled("r.source"))],
        unit="percent", min_=0, max_=100, fill=10, thresholds=steps(("green", None), ("orange", 88), ("red", 93)),
        desc="Control-plane Linux memory (the WLC's warning and critical thresholds are 88 % and 93 %).")), 8, 8)
    b.add(on_influx(timeseries("IOSd CPU and load", [
        fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_cpu)s and r._field == "one_minute" and %(wlc)s)
              |> map(fn: (r) => ({r with _value: float(v: r._value)}))
              |> %(mean)s
              |> %(series)s''', series=labelled('r.source + " IOSd CPU %"')),
        fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_load)s and r.number == "1" and r._field == "average" and %(wlc)s)
              |> %(mean)s
              |> %(series)s''', series=labelled('r.source + " load 1m"')),
    ], fill=0, desc="IOS daemon CPU (1-minute %) and the Linux 1-minute load average.")), 8, 8)

    # Access points -------------------------------------------------------------------------
    b.row("Access points")
    b.add(on_influx(table("Access points", [
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_capwap)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wtp_mac"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({
                  wtp_mac: r.wtp_mac, ap: r.name, source: r.source, ip: r.wtp_ip,
                  model: r["device_detail/static_info/ap_models/model"],
                  serial: r["device_detail/static_info/board_data/wtp_serial_num"],
                  version: r["device_detail/wtp_version/sw_version"],
                  state: r["ap_state/ap_operation_state"], mode: r["ap_mode_data/wtp_mode"],
                  uptime: float(v: uint(v: v.timeRangeStop) - uint(v: time(v: r["ap_time_info/boot_time"]))) / 1000000000.0,
                  joined: float(v: uint(v: v.timeRangeStop) - uint(v: time(v: r["ap_time_info/join_time"]))) / 1000000000.0,
                  site: r["tag_info/site_tag/site_tag_name"], policy: r["tag_info/policy_tag_info/policy_tag_name"],
                  rf: r["tag_info/rf_tag/rf_tag_name"], last_disconnect: r["disconnect_detail/disconnect_reason"]}))''',
           f=fields("name", "wtp_ip", "device_detail/static_info/ap_models/model",
                    "device_detail/static_info/board_data/wtp_serial_num", "device_detail/wtp_version/sw_version",
                    "ap_state/ap_operation_state", "ap_mode_data/wtp_mode", "ap_time_info/boot_time",
                    "ap_time_info/join_time", "tag_info/site_tag/site_tag_name",
                    "tag_info/policy_tag_info/policy_tag_name", "tag_info/rf_tag/rf_tag_name",
                    "disconnect_detail/disconnect_reason")),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_radio_stats)s and r._field == "aid_user_list" and %(wlc)s)
              |> last()
              |> group(columns: ["ap_mac"])
              |> sum()
              |> group()
              |> map(fn: (r) => ({wtp_mac: r.ap_mac, clients: r._value}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_eth)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["wtp_mac", "if_index"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({wtp_mac: r.wtp_mac, uplink: r.oper_status, speed: r.link_speed * 1000000}))''',
           f=fields("oper_status", "link_speed")),
    ], desc="Every AP joined to the selected WLCs, now (capwap-data every 60 s). Clients = associated clients over "
            "the AP's radios. Last disconnect is the reason of the AP's previous CAPWAP drop. Click an AP for its "
            "join/leave lines in the network device logs." + FIRST_ENTRY_GAP,
        transformations=[joined("wtp_mac"), organize(exclude=["wtp_mac"], rename={
            "ap": "AP", "source": "WLC", "ip": "IP", "model": "Model", "serial": "Serial", "version": "Software",
            "state": "State", "mode": "Mode", "uptime": "Uptime", "joined": "Joined for", "clients": "Clients",
            "uplink": "Uplink", "speed": "Uplink speed", "site": "Site tag", "policy": "Policy tag",
            "rf": "RF tag", "last_disconnect": "Last disconnect"},
            order=["AP", "WLC", "State", "Clients", "IP", "Model", "Serial", "Software", "Mode", "Uptime",
                   "Joined for", "Uplink", "Uplink speed", "Site tag", "Policy tag", "RF tag", "Last disconnect"])],
        overrides=[
            mapped("State", AP_STATE_MAP), mapped("Uplink", UPLINK_MAP),
            override("Mode", {"mappings": mapping(**{"mode-flex-connect": ("FlexConnect", "text"),
                                                     "mode-local": ("Local", "text")})}),
            override("Uptime", {"unit": "dtdurations"}), override("Joined for", {"unit": "dtdurations"}),
            override("Uplink speed", {"unit": "bps"}),
            override("AP", {"links": [{"title": "Join/leave lines of ${__value.text}", "targetBlank": False,
                                       "url": f"{LOGS_NET}?var-device=${{__data.fields.WLC}}"
                                              f"&var-search=${{__value.text}}&{TIME_URL}"}]}),
        ], sort="AP")), 24, 5)

    b.add(on_influx(table("Radios", [
        fx('''
            data = %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_radio)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wtp_mac", "radio_slot_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
            join.left(left: data, right: ap_names,
                on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac,
                as: (l, r) => ({l with ap: if exists r.ap then r.ap else l.wtp_mac}))
              |> map(fn: (r) => ({
                  key: r.wtp_mac + "/" + r.radio_slot_id, ap: r.ap, slot: r.radio_slot_id,
                  band: r.current_active_band, state: r.oper_state, admin: r.admin_state,
                  channel: r["phy_ht_cfg/cfg_data/curr_freq"], channels: r["phy_ht_cfg/cfg_data/freq_string"],
                  width: r["phy_ht_cfg/cfg_data/chan_width"], change: r["phy_ht_cfg/cfg_data/rrm_channel_change_reason"],
                  bss_color: r["bss_color_cfg/bss_color"]}))''', "ap_names",
           f=fields("current_active_band", "oper_state", "admin_state", "phy_ht_cfg/cfg_data/curr_freq",
                    "phy_ht_cfg/cfg_data/freq_string", "phy_ht_cfg/cfg_data/chan_width",
                    "phy_ht_cfg/cfg_data/rrm_channel_change_reason", "bss_color_cfg/bss_color")),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_band)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wtp_mac", "radio_slot_id", "band_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({key: r.wtp_mac + "/" + r.radio_slot_id,
                  power: r["phy_tx_pwr_lvl_cfg/cfg_data/curr_tx_power_in_dbm"],
                  level: r["phy_tx_pwr_cfg/cfg_data/current_tx_power_level"]}))''',
           f=fields("phy_tx_pwr_lvl_cfg/cfg_data/curr_tx_power_in_dbm", "phy_tx_pwr_cfg/cfg_data/current_tx_power_level")),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_radio_stats)s and r._field == "aid_user_list" and %(wlc)s)
              |> last()
              |> group()
              |> map(fn: (r) => ({key: r.ap_mac + "/" + r.slot_id, clients: r._value}))'''),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_rrm_load)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wtp_mac", "radio_slot_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({key: r.wtp_mac + "/" + r.radio_slot_id, cca: r.cca_util_percentage,
                  tx: r.tx_util_percentage, rx: r.rx_util_percentage, non_wifi: r.non_wifi_inter}))''',
           f=fields("cca_util_percentage", "tx_util_percentage", "rx_util_percentage", "non_wifi_inter")),
        fx('''
            %(src)s
              |> %(now_rate)s
              |> filter(fn: (r) => %(m_radio_stats)s and %(f)s and %(wlc)s)
              |> %(rate3m)s
              |> pivot(rowKey: ["ap_mac", "slot_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({key: r.ap_mac + "/" + r.slot_id, tx_bps: r.cumulative_tx_bytes * 8.0,
                  rx_bps: r.cumulative_rx_bytes * 8.0}))''', f=fields("cumulative_tx_bytes", "cumulative_rx_bytes")),
    ], desc="Every AP radio, now. Channel is the primary channel (Channels: the bonded set). Tx power level 1 is the "
            "radio's maximum. Channel busy (CCA) is the share of time the radio heard the channel busy: its own "
            "transmit, receive from its clients and everything else; RRM measures it every 180 s. Tx/rx are the "
            "radio's own traffic over the last 3 minutes." + FIRST_ENTRY_GAP,
        transformations=[joined("key"), organize(exclude=["key"], rename={
            "ap": "AP", "slot": "Slot", "band": "Band", "state": "State", "admin": "Admin", "channel": "Channel",
            "channels": "Channels", "width": "Width", "power": "Tx power", "level": "Power level",
            "clients": "Clients", "cca": "Channel busy", "tx": "Tx airtime", "rx": "Rx airtime",
            "non_wifi": "Non-Wi-Fi", "tx_bps": "Tx", "rx_bps": "Rx", "change": "Last channel change",
            "bss_color": "BSS color"},
            order=["AP", "Slot", "Band", "State", "Admin", "Channel", "Channels", "Width", "Tx power", "Power level",
                   "Clients", "Channel busy", "Tx airtime", "Rx airtime", "Non-Wi-Fi", "Tx", "Rx",
                   "Last channel change", "BSS color"])],
        overrides=[
            mapped("State", RADIO_STATE_MAP),
            override("Band", {"mappings": mapping(**{"dot11-2-dot-4-ghz-band": ("2.4 GHz", "text"),
                                                     "dot11-5-ghz-band": ("5 GHz", "text"),
                                                     "dot11-6-ghz-band": ("6 GHz", "text")})}),
            override("Width", {"unit": "suffix: MHz"}), override("Tx power", {"unit": "dBm"}),
            override("Channel busy", {"unit": "percent", "thresholds": CCA, "min": 0, "max": 100,
                                      "custom.cellOptions": {"type": "gauge", "mode": "basic",
                                                             "valueDisplayMode": "text"}}),
            *[override(n, {"unit": "percent"}) for n in ("Tx airtime", "Rx airtime", "Non-Wi-Fi")],
            *[override(n, {"unit": "bps", "decimals": 1}) for n in ("Tx", "Rx")],
        ], sort="AP")), 24, 6)

    b.add(on_influx(timeseries("Channel busy (CCA) per radio", [
        {"datasource": INFLUX, "query": per_radio("rrm_load", "cca_util_percentage", fn="lastw")}],
        unit="percent", min_=0, max_=100, fill=10, thresholds=CCA,
        desc="RRM's channel utilization per radio (updated every 180 s, so the line moves in steps).")), 8, 8)
    b.add(on_influx(timeseries("Clients per radio", [
        {"datasource": INFLUX, "query": per_radio("radio_stats", "aid_user_list", mac="ap_mac", slot="slot_id")}],
        decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Associated clients per radio (radio-oper-stats aid_user_list).")), 8, 8)
    b.add(on_influx(timeseries("Radio traffic", [
        {"datasource": INFLUX, "query": per_radio("radio_stats", "cumulative_tx_bytes", mac="ap_mac", slot="slot_id",
                                                  fn="rate", scale=BITS, suffix="tx")},
        {"datasource": INFLUX, "query": per_radio("radio_stats", "cumulative_rx_bytes", mac="ap_mac", slot="slot_id",
                                                  fn="rate", scale=BITS + NEG, suffix="rx")},
    ], unit="bps", fill=10, desc="Each radio's own traffic (tx up, rx down), from counters the AP refreshes every "
                                 "180 s, so rates are over windows of at least 3 minutes.")), 8, 8)
    b.add(on_influx(timeseries("Channel per radio", [
        {"datasource": INFLUX, "query": per_radio("radio", "phy_ht_cfg/cfg_data/curr_freq")}],
        decimals=0, fill=0, step=True, desc="Primary channel; a step is an RRM (DCA) channel change.")), 8, 7)
    b.add(on_influx(timeseries("Tx power per radio", [
        {"datasource": INFLUX, "query": per_radio("band", "phy_tx_pwr_lvl_cfg/cfg_data/curr_tx_power_in_dbm")}],
        unit="dBm", decimals=0, fill=0, step=True, desc="Transmit power (TPC changes it in steps).")), 8, 7)
    b.add(on_influx(timeseries("Radio retries and failures", [
        {"datasource": INFLUX, "query": per_radio("radio_stats", "retry_count", mac="ap_mac", slot="slot_id",
                                                  fn="rate", suffix="retries")},
        {"datasource": INFLUX, "query": per_radio("radio_stats", "failed_count", mac="ap_mac", slot="slot_id",
                                                  fn="rate", suffix="failed")},
    ], unit="short", fill=0, desc="Frames per second the radio had to retry, and frames it gave up on.")), 8, 7)

    # RF environment ----------------------------------------------------------------------
    b.row("RF environment")
    b.add(on_influx(timeseries("Airtime per radio", [
        {"datasource": INFLUX, "query": per_radio("rrm_load", f, suffix=n)}
        for f, n in (("tx_util_percentage", "tx"), ("rx_util_percentage", "rx"),
                     ("rx_noise_channel_utilization", "rx noise"), ("non_wifi_inter", "non-Wi-Fi"))],
        unit="percent", min_=0, fill=0, desc="What the channel time goes to (RRM load, every 180 s): the radio's "
                                             "own tx and rx, receiving noise/other networks, and non-Wi-Fi "
                                             "interference.")), 12, 8)
    b.add(on_influx(timeseries("AP uplink", [
        fx('''
            data = %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_eth)s and %(f)s and %(wlc)s)
              |> %(rate)s
              |> map(fn: (r) => ({r with _value: (if r._field == "tx_total_bytes" then -8.0 else 8.0) * r._value}))
              |> group()
            join.left(left: data, right: ap_names, on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac,
                as: (l, r) => ({l with ap: if exists r.ap then r.ap else l.wtp_mac}))
              |> %(series)s''', "ap_names",
           f=fields("rx_total_bytes", "tx_total_bytes"),
           series=labelled('r.ap + (if r._field == "rx_total_bytes" then " in" else " out")')),
    ], unit="bps", fill=10, desc="Each AP's Ethernet uplink as the AP counts it (in = received from the switch, up; "
                                 "out = sent to it, down). FlexConnect APs switch client traffic locally, so this "
                                 "is the clients' traffic. Refreshed every 180 s.")), 12, 8)
    b.add(on_influx(table("Noise and other networks per channel", [
        fx('''
            noise = %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_noise)s and r._field == "noise_data/noise" and %(wlc)s)
              |> last()
              |> group()
              |> map(fn: (r) => ({source: r.source, wtp_mac: r.wtp_mac, radio_slot_id: r.radio_slot_id,
                  chan: int(v: r["noise_data/chan"]), noise: r._value}))
            foreign = %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_foreign)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wtp_mac", "radio_slot_id", "foreign_data/chan"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({source: r.source, wtp_mac: r.wtp_mac, radio_slot_id: r.radio_slot_id,
                  chan: int(v: r["foreign_data/chan"]),
                  power: r["foreign_data/power"],
                  util: r["foreign_data/chan_util"],
                  rogues: r["foreign_data/rogue_20_count"] + r["foreign_data/rogue_40_primary_count"] + r["foreign_data/rogue_80_primary_count"]}))
            both = join.left(left: noise, right: foreign,
                on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac and l.radio_slot_id == r.radio_slot_id and l.chan == r.chan,
                as: (l, r) => ({l with power: r.power, util: r.util, rogues: r.rogues}))
            join.left(left: both, right: radios,
                on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac and l.radio_slot_id == r.radio_slot_id,
                as: (l, r) => ({radio: if exists r.radio then r.radio else l.wtp_mac + " slot " + l.radio_slot_id,
                    chan: l.chan, noise: l.noise, power: l.power, util: l.util, rogues: l.rogues}))
              |> sort(columns: ["radio", "chan"])''', "radios",
           f=fields("foreign_data/power", "foreign_data/chan_util", "foreign_data/rogue_20_count",
                    "foreign_data/rogue_40_primary_count", "foreign_data/rogue_80_primary_count")),
    ], desc="What each radio hears when it scans the band's channels (RRM, every 180 s or more): the noise floor, "
            "the strongest other Wi-Fi network (-128 dBm = none heard), how busy other networks keep the channel, "
            "and how many other access points it heard with that primary channel.",
        transformations=[organize(rename={"radio": "Radio", "chan": "Channel", "noise": "Noise floor",
                                          "power": "Strongest other network", "util": "Other networks' airtime",
                                          "rogues": "Other APs"},
                                  order=["Radio", "Channel", "Noise floor", "Strongest other network",
                                         "Other networks' airtime", "Other APs"])],
        overrides=[color_cell("Noise floor", NOISE, "dBm"),
                   override("Strongest other network", {"unit": "dBm", "mappings": mapping(**{"-128": ("none", "text")}),
                                                        "thresholds": steps(("text", None), ("yellow", -80),
                                                                            ("orange", -70), ("red", -60)),
                                                        "custom.cellOptions": {"type": "color-text"}}),
                   override("Other networks' airtime", {"unit": "percent", "thresholds": CCA, "min": 0, "max": 100,
                                                        "custom.cellOptions": {"type": "gauge", "mode": "basic",
                                                                               "valueDisplayMode": "text"}})])), 12, 10)
    b.add(on_influx(bargauge("Noise floor per channel", [fx('''
        data = %(src)s
          |> %(now)s
          |> filter(fn: (r) => %(m_noise)s and r._field == "noise_data/noise" and %(wlc)s)
          |> last()
          |> group()
        join.left(left: data, right: radios,
            on: (l, r) => l.source == r.source and l.wtp_mac == r.wtp_mac and l.radio_slot_id == r.radio_slot_id,
            as: (l, r) => ({l with band: if exists r.band then r.band else "slot " + l.radio_slot_id}))
          |> map(fn: (r) => ({chan: int(v: r["noise_data/chan"]), band: r.band, _value: r._value}))
          |> sort(columns: ["band", "chan"])
          |> map(fn: (r) => ({channel: r.band + " ch " + string(v: r.chan), _value: r._value}))''', "radios")],
        unit="dBm", min_=-100, max_=-50, thresholds=NOISE, mode="basic", bar_height=12,
        desc="Noise floor per scanned channel, now; lower is better.")), 12, 10)
    # The bar gauge needs one value per row of the single table.
    p = b.target[-1]
    p["options"]["reduceOptions"] = {"values": True, "calcs": ["lastNotNull"], "fields": "/^_value$/", "limit": 100}

    # SSIDs ------------------------------------------------------------------------------
    b.row("SSIDs")
    b.add(on_influx(table("WLANs", [
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_wlan_clients)s and %(f)s and %(wlc)s)
              |> last()
              |> pivot(rowKey: ["source", "wlan_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({key: r.source + "/" + r.wlan_id, source: r.source, wlan_id: int(v: r.wlan_id),
                  profile: r.wlan_profile_name, clients: r.client_curr_state_run,
                  random: r.total_random_mac_clients}))''',
           f=fields("wlan_profile_name", "client_curr_state_run", "total_random_mac_clients")),
        fx('''
            data = %(src)s
              |> %(now_rate)s
              |> filter(fn: (r) => %(m_slot_wlan)s and %(f)s and %(wlc)s)
              |> %(rate3m)s
              |> group(columns: ["source", "wlan_id", "_field"])
              |> sum()
              |> pivot(rowKey: ["source", "wlan_id"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
            join.left(left: data, right: ssids, on: (l, r) => l.source == r.source and l.wlan_id == r.wlan_id,
                as: (l, r) => ({key: l.source + "/" + l.wlan_id, ssid: if exists r.ssid then r.ssid else "",
                    down: l.bytes_tx * 8.0, up: l.bytes_rx * 8.0}))''', "ssids",
           f=fields("bytes_tx", "bytes_rx")),
    ], desc="Configured WLANs per WLC with clients in RUN state now, and the traffic over all radios in the last "
            "3 minutes (download = to the clients)." + FIRST_ENTRY_GAP,
        transformations=[joined("key"), organize(exclude=["key"], rename={
            "source": "WLC", "wlan_id": "WLAN ID", "profile": "Profile", "ssid": "SSID", "clients": "Clients",
            "random": "Random MAC clients", "down": "Download", "up": "Upload"},
            order=["WLC", "WLAN ID", "Profile", "SSID", "Clients", "Random MAC clients", "Download", "Upload"])],
        overrides=[override("Download", {"unit": "bps", "decimals": 1}),
                   override("Upload", {"unit": "bps", "decimals": 1})], sort="WLAN ID")), 10, 7)
    b.add(on_influx(timeseries("Clients per WLAN", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_wlan_clients)s and r._field == "client_curr_state_run" and %(wlc)s)
          |> %(lastw)s
          |> %(series)s''', series=labelled('r.source + " WLAN " + r.wlan_id'))],
        decimals=0, min_=0, fill=20, stack=True, step=True, desc="Clients in RUN state per WLAN id "
                                                                 "(wlan-client-stats).")), 7, 7)
    b.add(on_influx(timeseries("Traffic per SSID", [fx('''
        data = %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_slot_wlan)s and %(f)s and %(wlc)s)
          |> %(rate)s
          |> group(columns: ["source", "wlan_id", "_field", "_time"])
          |> sum()
          |> group()
        join.left(left: data, right: ssids, on: (l, r) => l.source == r.source and l.wlan_id == r.wlan_id,
            as: (l, r) => ({l with ssid: if exists r.ssid then r.ssid else "WLAN " + l.wlan_id}))
          |> map(fn: (r) => ({r with _value: (if r._field == "bytes_tx" then 8.0 else -8.0) * r._value}))
          |> %(series)s''', "ssids", f=fields("bytes_tx", "bytes_rx"),
        series=labelled('r.ssid + (if r._field == "bytes_tx" then " download" else " upload")'))],
        unit="bps", fill=10, desc="Per SSID over all radios (wtp-slot-wlan-stats): download (to the clients) up, "
                                  "upload down. The AP refreshes these every 90 s.")), 7, 7)

    # Clients ------------------------------------------------------------------------------
    b.row("Clients")
    b.add(on_influx(table("Clients", client_table_targets(), desc=(
        "Every client of the selected WLCs, now. Download/upload and retries are over the last 3 minutes (the AP "
        "refreshes client counters every 90 s). Rate is the current PHY rate, MCS the last data rate index "
        "(m = HT/VHT/HE MCS, a number = a legacy rate in Mbps). Click a client for its history." + FIRST_ENTRY_GAP),
        transformations=[joined("mac"), organize(rename=CLIENT_COLUMNS, order=list(CLIENT_COLUMNS.values()))],
        overrides=client_overrides(), sort="AP")), 24, 8)
    b.add(on_influx(timeseries("Clients per WLC", [
        fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_live)s and r._field == "run_state_clients" and %(wlc)s)
              |> %(lastw)s
              |> %(series)s''', series=labelled("r.source")),
    ], decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Clients in RUN state per WLC (client-live-stats).")), 6, 8)
    b.add(on_influx(timeseries("Clients by band and protocol", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => %(m_common)s and r._field == "ms_radio_type" and %(wlc)s)
          |> %(lastw)s
          |> map(fn: (r) => ({_time: r._time, kind: r._value, _value: 1}))
          |> group(columns: ["kind", "_time"])
          |> sum()
          |> %(series)s''', series=labelled(
        'strings.replaceAll(v: strings.replaceAll(v: strings.trimPrefix(v: strings.trimSuffix(v: r.kind, '
        'suffix: "-prot"), prefix: "client-"), t: "24-ghz", u: "24ghz"), t: "-", u: " ")'))],
        decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Clients per radio type (common-oper-data ms_radio_type, e.g. dot11ax 5ghz).")), 6, 8)
    b.add(on_influx(timeseries("Client signal (RSSI)", [
        {"datasource": INFLUX, "query": per_client("traffic", "most_recent_rssi")}],
        unit="dBm", fill=0, thresholds=RSSI, desc="Received signal strength of each client at the AP.")), 6, 8)
    b.add(on_influx(timeseries("Client throughput", [
        {"datasource": INFLUX, "query": per_client("traffic", "bytes_tx", fn="rate", scale=BITS, suffix="down")},
        {"datasource": INFLUX, "query": per_client("traffic", "bytes_rx", fn="rate", scale=BITS + NEG, suffix="up")},
    ], unit="bps", fill=10, desc="Download (to the client) up, upload down, per client.")), 6, 8)

    # Infrastructure ------------------------------------------------------------------------
    b.row("WLC interfaces", collapsed=True)
    b.add(snmp_wlc_traffic(), 24, 8)

    empty_notes(b, {
        **dict.fromkeys(["Access points", "Radios", "Noise and other networks per channel",
                         "Noise floor per channel"], NO_AP),
        **dict.fromkeys(["Channel busy (CCA) per radio", "Clients per radio", "Radio traffic", "Channel per radio",
                         "Tx power per radio", "Radio retries and failures", "Airtime per radio", "AP uplink",
                         "Traffic per SSID"], NO_AP_RANGE),
        "Clients": NO_CLIENTS,
        **dict.fromkeys(["Clients by band and protocol", "Client signal (RSSI)", "Client throughput"],
                        NO_CLIENTS_RANGE),
    })

    return dashboard(UIDS["overview"], "Wireless (C9800)",
                     "The C9800 WLCs from model-driven telemetry (InfluxDB bucket wlc): controllers, APs and radios, "
                     "channel use and RF, SSIDs and clients.",
                     b, tags=["wireless", "network"], variables=[wlc_var()], time_from="now-3h",
                     extra_links=[WIFI_LINK, url_link("WLC logs", f"{LOGS_NET}?var-device=c9800-wlc-1"
                                                                  f"&var-device=c9800-wlc-2"),
                                  url_link("SNMP Device Summary", SNMP_SUMMARY), url_link("SNMP Interface Detail",
                                                                                          SNMP_DETAIL)])


# The clients table: one query per tree, joined on the client MAC ("mac") in Grafana.
CLIENT_COLUMNS = {
    "mac": "Client", "ip": "IP", "ap": "AP", "ssid": "SSID", "band": "Band", "protocol": "Protocol",
    "channel": "Channel", "rssi": "RSSI", "snr": "SNR", "speed": "Rate", "mcs": "MCS", "nss": "Streams",
    "down": "Download", "up": "Upload", "retries": "Retries", "state": "State", "security": "Security",
    "connected": "Connected for", "source": "WLC",
}


def client_table_targets(one=False):
    """Queries for the clients table (one=True: only $client, for the client dashboard)."""
    def only(tag):
        return f' and r.{tag} == "${{client}}"' if one else ""
    return [
        fx(f'''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_common)s and %(f)s and %(wlc)s{only("client_mac")})
              |> last()
              |> pivot(rowKey: ["source", "client_mac"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({{mac: r.client_mac, ap: r.ap_name, state: r.co_state, source: r.source,
                  band: if strings.containsStr(v: r.ms_radio_type, substr: "24-ghz") or strings.containsStr(v: r.ms_radio_type, substr: "24ghz") then "2.4 GHz"
                        else if strings.containsStr(v: r.ms_radio_type, substr: "6ghz") or strings.containsStr(v: r.ms_radio_type, substr: "6-ghz") then "6 GHz"
                        else "5 GHz",
                  protocol: strings.replaceAll(v: regexp.findString(r: /dot11[a-z]+/, v: r.ms_radio_type), t: "dot11", u: "802.11")}}))''',
           f=fields("ap_name", "co_state", "ms_radio_type")),
        fx(f'''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_dot11)s and %(f)s and %(wlc)s{only("ms_mac_address")})
              |> last()
              |> pivot(rowKey: ["source", "ms_mac_address"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({{mac: r.ms_mac_address, ssid: r.vap_ssid, channel: r.current_channel,
                  security: r["ms_wifi/wpa_version"] + " " + r["ms_wifi/auth_key_mgmt"],
                  connected: float(v: uint(v: v.timeRangeStop) - uint(v: time(v: r.ms_assoc_time))) / 1000000000.0}}))''',
           f=fields("vap_ssid", "current_channel", "ms_wifi/wpa_version", "ms_wifi/auth_key_mgmt", "ms_assoc_time")),
        fx(f'''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s{only("ms_mac_address")})
              |> last()
              |> pivot(rowKey: ["source", "ms_mac_address"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({{mac: r.ms_mac_address, rssi: r.most_recent_rssi, snr: r.most_recent_snr,
                  speed: r.speed * 1000000, mcs: r.current_rate, nss: r.spatial_stream}}))''',
           f=fields("most_recent_rssi", "most_recent_snr", "speed", "current_rate", "spatial_stream")),
        fx(f'''
            %(src)s
              |> %(now_rate)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s{only("ms_mac_address")})
              |> %(rate3m)s
              |> pivot(rowKey: ["source", "ms_mac_address"], columnKey: ["_field"], valueColumn: "_value")
              |> group()
              |> map(fn: (r) => ({{mac: r.ms_mac_address, down: r.bytes_tx * 8.0, up: r.bytes_rx * 8.0,
                  retries: r.data_retries}}))''', f=fields("bytes_tx", "bytes_rx", "data_retries")),
        fx(f'''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => %(m_sisf)s and r._field == "ipv4_binding/ip_key/ip_addr" and %(wlc)s{only("mac_addr")})
              |> last()
              |> group()
              |> map(fn: (r) => ({{mac: r.mac_addr, ip: r._value}}))'''),
    ]


def client_overrides(link=True):
    o = [
        color_cell("RSSI", RSSI, "dBm"), color_cell("SNR", SNR, "dB"), mapped("State", CLIENT_STATE_MAP),
        override("Rate", {"unit": "bps"}), override("Connected for", {"unit": "dtdurations"}),
        *[override(n, {"unit": "bps", "decimals": 1}) for n in ("Download", "Upload")],
        override("Retries", {"unit": "short", "decimals": 1, "displayName": "Retries/s"}),
    ]
    if link:
        o.append(override("Client", {"links": [{
            "title": "History of ${__value.text}", "targetBlank": False,
            "url": f"/d/{UIDS['client']}/{UIDS['client']}?var-wlc=${{__data.fields.WLC}}"
                   f"&var-client=${{__value.text}}&{TIME_URL}"}]}))
    return o


# --- Wireless client ------------------------------------------------------------------

# Retries, drops and errors: retries in blues, drops in the warning color, security errors in red/pinks.
RETRY_COLORS = {"data_retries": SERIES[1], "tx_retries": SERIES[4], "tx_excessive_retries": SERIES[8],
                "tx_total_drops": SERIES[5], "duplicate_rcv": SERIES[2], "policy_errs": SERIES[3],
                "decrypt_failed": SERIES[7], "mic_mismatch": SERIES[0], "mic_missing": SERIES[6]}

def client():
    b = Board()
    b.row("Now")
    b.add(on_influx(table("Client", client_table_targets(one=True), desc=(
        "The selected client now (empty when it isn't associated). Download/upload over the last 3 minutes."),
        transformations=[joined("mac"), organize(rename=CLIENT_COLUMNS, order=list(CLIENT_COLUMNS.values()))],
        overrides=client_overrides(link=False))), 24, 4)

    one = 'r.ms_mac_address == "${client}"'
    b.row("Signal and rate")
    b.add(on_influx(timeseries("Signal", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s and {one})
              |> %(lastw)s
              |> %(series)s''', f=fields("most_recent_rssi", "most_recent_snr"),
           series=labelled('if r._field == "most_recent_rssi" then "RSSI (dBm)" else "SNR (dB)"')),
    ], fill=0, desc="RSSI (dBm, at the AP) and SNR (dB). Below about -75 dBm / 20 dB, rates and retries suffer.",
        overrides=[fixed_color("RSSI (dBm)", "blue"), fixed_color("SNR (dB)", "green")])), 12, 8)
    b.add(on_influx(timeseries("PHY rate and streams", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and r._field == "speed" and %(wlc)s and {one})
              |> map(fn: (r) => ({{r with _value: float(v: r._value) * 1000000.0}}))
              |> %(lastw)s
              |> %(series)s''', series=labelled('"PHY rate"')),
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and r._field == "spatial_stream" and %(wlc)s and {one})
              |> %(lastw)s
              |> %(series)s''', series=labelled('"Spatial streams"')),
    ], unit="bps", fill=0, step=True, desc="Current PHY data rate and spatial streams.",
        overrides=[fixed_color("PHY rate", SERIES[1]),
                   override("Spatial streams", {"unit": "none", "decimals": 0, "custom.axisPlacement": "right",
                                                "color": {"mode": "fixed", "fixedColor": SERIES[0]}})])),
        12, 8)

    b.row("Traffic")
    b.add(on_influx(timeseries("Throughput", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s and {one})
              |> %(rate)s
              |> map(fn: (r) => ({{r with _value: (if r._field == "bytes_tx" then 8.0 else -8.0) * r._value}}))
              |> %(series)s''', f=fields("bytes_tx", "bytes_rx"),
           series=labelled('if r._field == "bytes_tx" then "download" else "upload"')),
    ], unit="bps", fill=20, desc="Download (sent to the client) up, upload down. Counters refresh every 90 s.",
        overrides=[fixed_color("download", DOWN), fixed_color("upload", UP)])), 12, 8)
    b.add(on_influx(timeseries("Packets", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s and {one})
              |> %(rate)s
              |> map(fn: (r) => ({{r with _value: if r._field == "pkts_tx" then r._value else -r._value}}))
              |> %(series)s''', f=fields("pkts_tx", "pkts_rx"),
           series=labelled('if r._field == "pkts_tx" then "download" else "upload"')),
    ], unit="pps", fill=10, overrides=[fixed_color("download", DOWN), fixed_color("upload", UP)])), 12, 8)
    b.add(on_influx(timeseries("Retries, drops and errors", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_traffic)s and %(f)s and %(wlc)s and {one})
              |> %(rate)s
              |> %(series)s''', f=fields("data_retries", "tx_retries", "tx_excessive_retries", "tx_total_drops",
                                         "decrypt_failed", "mic_mismatch", "mic_missing", "duplicate_rcv",
                                         "policy_errs"),
           series=labelled("r._field")),
    ], unit="short", fill=0, desc="Per second. data_retries are frames the AP sent again; tx_total_drops frames it "
                                  "gave up on; decrypt_failed/mic_* point at key or security problems.",
        overrides=[fixed_color(n, c) for n, c in RETRY_COLORS.items()])), 24, 8)

    b.row("Where")
    b.add(on_influx(state_timeline("AP, SSID and channel", [
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_common)s and r._field == "ap_name" and %(wlc)s and r.client_mac == "${{client}}")
              |> %(lastw)s
              |> %(series)s''', series=labelled('"AP"')),
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_dot11)s and r._field == "vap_ssid" and %(wlc)s and {one})
              |> %(lastw)s
              |> %(series)s''', series=labelled('"SSID"')),
        fx(f'''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => %(m_dot11)s and r._field == "current_channel" and %(wlc)s and {one})
              |> %(lastw)s
              |> map(fn: (r) => ({{r with _value: "ch " + string(v: r._value)}}))
              |> %(series)s''', series=labelled('"Channel"')),
    ], show_value="auto", color={"mode": "palette-classic"},
        desc="Roams (AP), SSID and channel changes; gaps are times the client wasn't associated.")), 24, 6)

    empty_notes(b, {"Client": "Client not associated in the last 3 minutes",
                    **dict.fromkeys(["Signal", "PHY rate and streams", "Throughput", "Packets",
                                     "Retries, drops and errors", "AP, SSID and channel"], NOT_SEEN)})

    return dashboard(UIDS["client"], "Wireless client (C9800)",
                     "One wireless client (picker: MAC, from the WLCs' telemetry): where it is, signal, rates, "
                     "throughput, retries and errors over time.",
                     b, tags=["wireless", "network"], variables=[wlc_var(), client_var(), client_cisco_var()], time_from="now-3h",
                     extra_links=[WIFI_LINK, url_link("WLC logs", f"{LOGS_NET}?var-device=c9800-wlc-1"
                                                                  f"&var-device=c9800-wlc-2"
                                                                  f"&var-search=${{client_cisco}}")])


DASHBOARDS = {
    "Network/wireless-overview.json": overview,
    "Network/wireless-client.json": client,
}
