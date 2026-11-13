"""The wireless dashboards (folder Network): C9800 overview and one wireless client.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with
its helpers; see custom.py for the conventions. The data is the C9800 WLCs'
model-driven telemetry (gRPC dial-out to Telegraf on the backend VIP, roots/monitoring-config
README "C9800 telemetry"), read from Prometheus/Mimir (default datasource, uid "prometheus"):
Telegraf re-shapes every MDT message for Prometheus (modules/services/monitoring/telegraf/wlc.star)
and serves it on :9275, scraped by both replicas as job "wlc" every 30 s. The InfluxDB history
(bucket "wlc", from 2026-11-09) was backfilled into Mimir under the same names. Names and labels:

- metric = wlc_<short>_<field>: <short> from the map at the top of wlc.star (wlc_client_traffic,
  wlc_ap_radio, wlc_rrm_load, wlc_cpu, ...), <field> the YANG leaf path below the list entry with
  "/" -> "_" (phy_ht_cfg/cfg_data/curr_freq -> wlc_ap_radio_phy_ht_cfg_cfg_data_curr_freq);
- labels: host (the WLC, c9800-wlc-1/2: the same as the SNMP jobs' host label), plus the list
  keys, which are named differently per tree: a client is client_mac (common-oper-data),
  ms_mac_address (traffic-stats, dot11-oper-data) or mac_addr (sisf-db-mac); an AP radio is
  wtp_mac + radio_slot_id (radio-oper-data, rrm-measurement) or ap_mac + slot_id (radio-oper-stats).
  The queries rename them to one key (mac; wtp_mac + radio_slot_id) and aggregate by it, so the
  live series and the backfilled ones (other job/instance labels) give one series;
- string leaves are labels of wlc_<short>_info (value 1: AP and client names, SSIDs, states,
  IPs), joined in with `* on (...) group_left (...)`. Timestamp strings (*_time, *_ts, *timestamp)
  are <field>_seconds instead (Unix time, 0 = unset): AP boot/join time, the client's association
  time and the AP certificate's expiry become durations/dates with `time() - (x > 0)`. The client's
  current_rate string is
  numeric: wlc_client_traffic_current_rate_mcs / _ss (or _mbps for a legacy rate);
- counters (bytes, packets, retries) are plain series: rate()/increase().

Quirks the queries handle:

- Entries vanish instead of going to 0 (a client leaves, an AP drops): Telegraf drops a series
  150 s after its last push, so instant queries ("now" values) only see what's still reported.
- AP-reported counters only change every 90 s (client traffic, per-SSID stats) or 180 s
  (radio and AP uplink counters); the WLC re-sends the old value in between. Rate panels set a
  minimum interval (RATE_90 / RATE_180) so $__rate_interval spans at least 3 / 6 minutes, and
  the tables take rates over [3m] / [6m], so they don't read 0, 0, spike.
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
full-key xpath predicates; single-entry streams arrive complete under the same names, so slot 0's
radio-oper-data/-stats, rrm load, slot 0 x WLAN 4 and the lowest WLAN's client counts are back.
One difference: slot 0's radio-band-info arrives nested in radio-oper-data, so its tx power is
wlc_ap_radio_radio_band_info_phy_tx_pwr_* instead of wlc_ap_radio_band_phy_tx_pwr_*; TX_POWER and
TX_LEVEL take either. Still missing: 2.4 GHz rrm noise/foreign (the WLC rejects per-channel
predicates) and the lowest client MAC (changes with the clients). FIRST_ENTRY_GAP is the note the
affected panels carry; drop it once the WLC sends the whole list.
"""
from custom import (
    BLUE, MERGE, ORANGE_IF_ANY, PERCENT, UP_MAP, UP_STEPS, Board, bargauge, dashboard, fixed_color, mapping,
    organize, override, q, query_var, stat, state_timeline, steps, table, timeseries,
)
from theme import ACCENT, ACCENT2, SERIES


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
# Minimum panel intervals for counter rates: $__rate_interval is at least 4x the minimum interval, so 45s gives
# rate windows of 3 minutes or more (counters refreshed every 90 s), 90s 6 minutes or more (every 180 s).
RATE_90, RATE_180 = "45s", "90s"

# --- PromQL -----------------------------------------------------------------------------

WLC = 'host=~"${wlc:regex}"'


def m(name, *matchers):
    """A wlc_* selector on the WLC picker, plus extra matchers."""
    return name + "{" + ", ".join((WLC, *matchers)) + "}"


def relabel(expr, dst, src, regex="(.*)", repl="$1"):
    return f'label_replace({expr}, "{dst}", "{repl}", "{src}", "{regex}")'


def one(by, expr):
    """One series per `by` (an info series' labels change now and then; old and new overlap until the old expires)."""
    return f"topk by ({by}) (1, {expr})"


def rate(expr, window="$__rate_interval"):
    return f"rate({expr}[{window}])"


# AP name per (host, wtp_mac): label ap.
AP_NAMES = relabel(one("host, wtp_mac", f'max by (host, wtp_mac, wtp_name) ({m("wlc_ap_name_mac_info")})'),
                   "ap", "wtp_name")


def with_ap(expr):
    """Adds label ap (the AP's name, or its MAC when the name map doesn't have it) to series keyed by wtp_mac."""
    return f"(({expr}) * on (host, wtp_mac) group_left (ap) {AP_NAMES} or on (host, wtp_mac) {relabel(expr, 'ap', 'wtp_mac')})"


def band_name(expr, src="current_active_band"):
    """Label band = 2.4 GHz / 5 GHz / 6 GHz from the YANG band enum (dot11-5-ghz-band)."""
    return relabel(relabel(relabel(expr, "band", src), "band", src, "dot11-([0-9]+)-ghz-band", "$1 GHz"),
                   "band", src, "dot11-2-dot-4-ghz-band", "2.4 GHz")


# Every radio (host, wtp_mac, radio_slot_id) with labels ap, band and radio = "lylat-AP-1 · 5 GHz (slot 1)".
RADIOS = relabel(
    f'label_join(label_join({with_ap(band_name(one("host, wtp_mac, radio_slot_id", "max by (host, wtp_mac, radio_slot_id, current_active_band) (" + m("wlc_ap_radio_info") + ")")))}, '
    '"radio", " · ", "ap", "band"), "radio", " (slot ", "radio", "radio_slot_id")', "radio", "radio", "(.*)", "$1)")
RADIO_KEY = "host, wtp_mac, radio_slot_id"


def radio_keys(expr):
    """radio-oper-stats calls the radio ap_mac + slot_id: renamed to wtp_mac + radio_slot_id."""
    return relabel(relabel(expr, "wtp_mac", "ap_mac"), "radio_slot_id", "slot_id")


def per_radio(expr):
    """Labels radio and band on series keyed by host, wtp_mac, radio_slot_id (fallback radio: "<mac> slot <n>")."""
    fallback = f'label_join({expr}, "radio", " slot ", "wtp_mac", "radio_slot_id")'
    return f"(({expr}) * on ({RADIO_KEY}) group_left (radio, band) {RADIOS} or on ({RADIO_KEY}) {fallback})"


def radio_gauge(name, stats=False):
    sel = m(name)
    return f"max by ({RADIO_KEY}) ({radio_keys(sel) if stats else sel})"


def radio_rate(name, window="$__rate_interval"):
    """Per-second rate of a radio-oper-stats counter, per radio."""
    return f"sum by ({RADIO_KEY}) ({radio_keys(rate(m(name), window))})"


# Slot 0's radio-band-info comes nested in radio-oper-data (see the docstring): either name.
TX_POWER = ("phy_tx_pwr_lvl_cfg_cfg_data_curr_tx_power_in_dbm", "dBm")
TX_LEVEL = ("phy_tx_pwr_cfg_cfg_data_current_tx_power_level", "level")


def tx_power(field):
    return (f"(max by ({RADIO_KEY}) ({m('wlc_ap_radio_band_' + field)}) or "
            f"max by ({RADIO_KEY}) ({m('wlc_ap_radio_radio_band_info_' + field)}))")


# Clients: one key, mac.
def by_mac(expr, src="ms_mac_address"):
    return relabel(expr, "mac", src)


def client_gauge(name, *matchers, scale=""):
    return f"max by (host, mac) ({by_mac(m(name, *matchers))}){scale}"


def client_rate(name, *matchers, window="$__rate_interval", scale=""):
    return f"sum by (host, mac) ({by_mac(rate(m(name, *matchers), window))}){scale}"


# IPv4 per client (SISF binding table): label ipsfx = " (10.4.0.54)", empty when there's none.
CLIENT_IPS = relabel(by_mac(one("host, mac_addr", f'max by (host, mac_addr, ipv4_binding_ip_key_ip_addr) ({m("wlc_client_ip_info")})'),
                            "mac_addr"), "ipsfx", "ipv4_binding_ip_key_ip_addr", "(.+)", " ($1)")


def per_client(expr):
    """Series keyed by host, mac, named "{{mac}}{{ipsfx}}" (MAC plus the IP when the SISF table has one)."""
    return f"(({expr}) * on (host, mac) group_left (ipsfx) {CLIENT_IPS} or on (host, mac) ({expr}))"


CLIENT_LEGEND = "{{mac}}{{ipsfx}}"


def client_kind(expr):
    """Label kind from ms_radio_type (client-dot11ax-5ghz-prot -> dot11ax 5ghz, as the InfluxDB panels showed it)."""
    return relabel(relabel(expr, "kind", "ms_radio_type"), "kind", "ms_radio_type",
                   "client-(dot11[a-z]+)-([0-9]+)-?ghz-prot", "$1 ${2}ghz")


def client_band(expr):
    """Labels band (2.4/5/6 GHz) and protocol (802.11ax) from ms_radio_type."""
    b = relabel(relabel(relabel(expr, "band", "ms_radio_type", ".*", "5 GHz"), "band", "ms_radio_type", ".*6-?ghz.*",
                        "6 GHz"), "band", "ms_radio_type", ".*24-?ghz.*", "2.4 GHz")
    return relabel(b, "protocol", "ms_radio_type", ".*dot11([a-z]+).*", "802.11$1")


def since(name):
    """Seconds since a per-AP timestamp (<field>_seconds, Unix time; 0 = unset, left out)."""
    return f"time() - (max by (host, wtp_mac) ({m(name)}) > 0)"


def iq(expr, legend="__auto"):
    return q(expr, legend, instant=True)


def tq(expr):
    return q(expr, table=True)


def interval(p, value):
    """Minimum interval for panels that rate AP counters (RATE_90 / RATE_180)."""
    p["interval"] = value
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


def sort_by(field):
    return {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": field, "desc": False}]}}


def as_numbers(*fields):
    return {"id": "convertFieldType", "options": {"fields": {}, "conversions": [
        {"targetField": f, "destinationType": "number"} for f in fields]}}


def padded(expr, src, dst):
    """dst = src zero-padded to 3 digits (channel numbers sort as text)."""
    return relabel(relabel(relabel(expr, dst, src, "([0-9])", "00$1"), dst, src, "([0-9][0-9])", "0$1"),
                   dst, src, "([0-9]{3,})", "$1")


def wlc_var():
    return query_var("wlc", "WLC", "label_values(wlc_cpu_five_seconds, host)")


def client_var():
    """Clients seen in the time range, most recently seen first (sort 0 keeps that order), so the default is a
    client that is there now."""
    v = query_var("client", "Client (MAC)", "query_result(sort_desc(max by (client_mac) (max_over_time(timestamp("
                  + m("wlc_client_common_info") + ")[$__range:1m]))))", multi=False, include_all=False)
    v["regex"] = '/client_mac="([^"]+)"/'
    v["sort"] = 0
    return v


def client_cisco_var():
    """The selected client's MAC in Cisco dotted form (9445.607a.12a8), the way C9800 syslog writes it:
    the "WLC logs" link searches the logs for it. Hidden; the client MAC itself if it isn't aa:bb:cc:dd:ee:ff."""
    v = query_var("client_cisco", "", "query_result(" + relabel(relabel(
        'label_replace(vector(1), "m", "${client}", "", "")', "cisco", "m"), "cisco", "m",
        "([0-9a-f]{2}):([0-9a-f]{2}):([0-9a-f]{2}):([0-9a-f]{2}):([0-9a-f]{2}):([0-9a-f]{2})",
        "$1$2.$3$4.$5$6") + ")", multi=False, include_all=False)
    v.update(regex='/cisco="([^"]+)"/', refresh=1, sort=0, hide=2)
    return v


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

CPU_SAMPLE = m("wlc_cpu_five_seconds")
REGISTERED = 'ap_state_ap_operation_state="registered"'
LOAD_1M = 'number="1"'
THIS_CLIENT = 'client_mac="${client}"'


def overview():
    b = Board()

    b.row("Status")
    b.add(stat("Clients", [iq(f'sum(max by (host) ({m("wlc_client_live_run_state_clients")}))')],
               color_mode="value", thresholds=BLUE, decimals=0,
               desc="Clients in RUN state on the selected WLCs (client-live-stats)."), 3, 4)
    b.add(stat("APs joined", [iq(
        f'count(max by (host, wtp_mac) ({m("wlc_ap_capwap_info", REGISTERED)}))')],
        color_mode="value", thresholds=steps(("red", None), ("green", 1)), decimals=0,
        no_value="0", desc="APs whose CAPWAP state is registered (capwap-data, sent every 60 s). An AP that "
                           "leaves just stops reporting, so it drops out of the count."), 3, 4)
    b.add(stat("Radios up / total", [
        iq(f'sum(max by (host) ({m("wlc_ap_global_stats_80211_all_rad_radios_up")}))', "up"),
        iq(f'sum(max by (host) ({m("wlc_ap_global_stats_80211_all_rad_total_radios")}))', "total"),
    ], color_mode="value", thresholds=BLUE, decimals=0, text_mode="value_and_name",
        desc="All AP radios joined to the selected WLCs (ewlc-ap-stats)."), 4, 4)
    b.add(stat("Radios down", [iq(f'sum(max by (host) ({m("wlc_ap_global_stats_80211_all_rad_radios_down")}))')],
               thresholds=ORANGE_IF_ANY, decimals=0,
               desc="Radios that are joined but not up: admin down or, like the C9130's second 5 GHz (XOR) radio "
                    "here, not in use."), 3, 4)
    b.add(stat("WLANs with clients", [iq(
        f'count(max by (host, wlan_id) ({m("wlc_wlan_clients_client_curr_state_run")}) > 0)')],
        color_mode="value", thresholds=BLUE, decimals=0, no_value="0"), 3, 4)
    b.add(stat("Telemetry age", [iq(
        f"time() - max by (host) (timestamp({CPU_SAMPLE})) or "
        f"time() - max by (host) (max_over_time(timestamp({CPU_SAMPLE})[$__range:30s]))", "{{host}}")],
        unit="s", decimals=0, thresholds=AGE, text_mode="value_and_name",
        desc="Seconds since Prometheus last scraped each WLC's CPU sample (pushed every 30 s, scraped every 30 s, "
             "so normally under 30). Telegraf keeps serving a sample for 150 s after the last push, so a broken "
             "dial-out reads 150 s and more, then counts up (see the Monitoring stack dashboard, journalctl -u "
             "telegraf on the backend VIP holder, and the WlcTelemetryNotInPrometheus alert)."), 5, 4)
    b.add(stat("WLC SNMP", [q('up{job="snmp-wlc", host=~"${wlc:regex}"}', "{{host}}")], text_mode="value_and_name",
               mappings=UP_MAP, thresholds=UP_STEPS, desc="Prometheus' SNMP scrape of the WLCs (job snmp-wlc)."), 3, 4)

    # Controllers -------------------------------------------------------------------------
    b.row("Controllers")
    b.add(table("Controllers", [
        tq(one("host", f'max by (host, high_availability_state, memory_stats_memory_status) ({m("wlc_control_process_info")})')),
        tq(f'max by (host) ({m("wlc_control_process_memory_stats_used_percent")})'),
        tq(f'100 - avg by (host) ({m("wlc_cpu_core_idle")})'),
        tq(f'max by (host) ({m("wlc_cpu_one_minute")})'),
        tq(f'max by (host) ({m("wlc_load_avg_average", LOAD_1M)})'),
        tq(f'max by (host) ({m("wlc_client_live_run_state_clients")})'),
        tq(f'max by (host) ({m("wlc_ap_global_stats_80211_all_rad_radios_up")})'),
        tq(f'max by (host) ({m("wlc_ap_global_stats_80211_all_rad_total_radios")})'),
    ], desc="Per WLC, now. Linux CPU is the mean busy % over the control-plane cores; IOSd CPU the 1-minute "
            "figure of the IOS daemon alone (usually near 0 on a C9800-CL). Click a WLC for its log lines.",
        transformations=[MERGE, organize(exclude=["Time", "Value #A"], rename={
            "host": "WLC", "high_availability_state": "HA role", "Value #C": "Linux CPU", "Value #D": "IOSd CPU (1m)",
            "Value #E": "Load (1m)", "Value #B": "Memory used", "memory_stats_memory_status": "Memory status",
            "Value #F": "Clients", "Value #G": "Radios up", "Value #H": "Radios"},
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
        ], sort="WLC"), 24, 5)
    b.add(timeseries("Linux CPU busy per core", [q(
        f'100 - avg by (host, name) (avg_over_time({m("wlc_cpu_core_idle")}[$__interval]))', "{{host}} core {{name}}")],
        unit="percent", min_=0, fill=0, desc="100 - idle for each control-plane core (per-core-stat, a 5 s sample "
                                              "every 30 s)."), 8, 8)
    b.add(timeseries("Linux memory used", [q(
        f'max by (host) (avg_over_time({m("wlc_control_process_memory_stats_used_percent")}[$__interval]))', "{{host}}")],
        unit="percent", min_=0, max_=100, fill=10, thresholds=steps(("green", None), ("orange", 88), ("red", 93)),
        desc="Control-plane Linux memory (the WLC's warning and critical thresholds are 88 % and 93 %)."), 8, 8)
    b.add(timeseries("IOSd CPU and load", [
        q(f'max by (host) (avg_over_time({m("wlc_cpu_one_minute")}[$__interval]))', "{{host}} IOSd CPU %"),
        q(f'max by (host) (avg_over_time({m("wlc_load_avg_average", LOAD_1M)}[$__interval]))',
          "{{host}} load 1m"),
    ], fill=0, desc="IOS daemon CPU (1-minute %) and the Linux 1-minute load average."), 8, 8)

    # Access points -------------------------------------------------------------------------
    b.row("Access points")
    ap_labels = ("name, wtp_ip, device_detail_static_info_ap_models_model, "
                 "device_detail_static_info_board_data_wtp_serial_num, device_detail_wtp_version_sw_version, "
                 "ap_state_ap_operation_state, ap_mode_data_wtp_mode, tag_info_site_tag_site_tag_name, "
                 "tag_info_policy_tag_info_policy_tag_name, tag_info_rf_tag_rf_tag_name, "
                 "disconnect_detail_disconnect_reason")
    b.add(table("Access points", [
        tq(one("host, wtp_mac", f'max by (host, wtp_mac, {ap_labels}) ({m("wlc_ap_capwap_info")})')),
        tq("sum by (host, wtp_mac) (" + relabel(m("wlc_ap_radio_stats_aid_user_list"), "wtp_mac", "ap_mac") + ")"),
        tq(one("host, wtp_mac", f'max by (host, wtp_mac, oper_status) ({m("wlc_ap_ethernet_info")})')),
        tq(f'max by (host, wtp_mac) ({m("wlc_ap_ethernet_link_speed")}) * 1000000'),
        tq(since("wlc_ap_capwap_ap_time_info_boot_time_seconds")),
        tq(since("wlc_ap_capwap_ap_time_info_join_time_seconds")),
        tq(f'(max by (host, wtp_mac) ({m("wlc_ap_capwap_ap_security_data_ap_cert_expiry_time_seconds")}) > 0) * 1000'),
    ], desc="Every AP joined to the selected WLCs, now (capwap-data every 60 s). Clients = associated clients over "
            "the AP's radios. Last disconnect is the reason of the AP's previous CAPWAP drop. Click an AP for its "
            "join/leave lines in the network device logs. Uptime counts from the AP's boot, Joined for from its "
            "CAPWAP join; Certificate expiry is the AP's manufacturing (SUDI) certificate." + FIRST_ENTRY_GAP,
        transformations=[MERGE, organize(exclude=["Time", "wtp_mac", "Value #A", "Value #C"], rename={
            "name": "AP", "host": "WLC", "wtp_ip": "IP", "device_detail_static_info_ap_models_model": "Model",
            "device_detail_static_info_board_data_wtp_serial_num": "Serial",
            "device_detail_wtp_version_sw_version": "Software", "ap_state_ap_operation_state": "State",
            "ap_mode_data_wtp_mode": "Mode", "Value #B": "Clients", "oper_status": "Uplink", "Value #D": "Uplink speed",
            "Value #E": "Uptime", "Value #F": "Joined for", "Value #G": "Certificate expiry",
            "tag_info_site_tag_site_tag_name": "Site tag", "tag_info_policy_tag_info_policy_tag_name": "Policy tag",
            "tag_info_rf_tag_rf_tag_name": "RF tag", "disconnect_detail_disconnect_reason": "Last disconnect"},
            order=["AP", "WLC", "State", "Clients", "IP", "Model", "Serial", "Software", "Mode", "Uptime",
                   "Joined for", "Uplink", "Uplink speed", "Site tag", "Policy tag", "RF tag", "Last disconnect",
                   "Certificate expiry"])],
        overrides=[
            mapped("State", AP_STATE_MAP), mapped("Uplink", UPLINK_MAP),
            override("Mode", {"mappings": mapping(**{"mode-flex-connect": ("FlexConnect", "text"),
                                                     "mode-local": ("Local", "text")})}),
            override("Uptime", {"unit": "dtdurations"}), override("Joined for", {"unit": "dtdurations"}),
            override("Uplink speed", {"unit": "bps"}), override("Certificate expiry", {"unit": "dateTimeAsIso"}),
            override("AP", {"links": [{"title": "Join/leave lines of ${__value.text}", "targetBlank": False,
                                       "url": f"{LOGS_NET}?var-device=${{__data.fields.WLC}}"
                                              f"&var-search=${{__value.text}}&{TIME_URL}"}]}),
        ], sort="AP"), 24, 5)

    radio_labels = ("current_active_band, oper_state, admin_state, phy_ht_cfg_cfg_data_freq_string, "
                    "phy_ht_cfg_cfg_data_rrm_channel_change_reason")
    b.add(table("Radios", [
        tq(with_ap(one(RADIO_KEY, f'max by ({RADIO_KEY}, {radio_labels}) ({m("wlc_ap_radio_info")})'))),
        tq(radio_gauge("wlc_ap_radio_phy_ht_cfg_cfg_data_curr_freq")),
        tq(radio_gauge("wlc_ap_radio_phy_ht_cfg_cfg_data_chan_width")),
        tq(tx_power(TX_POWER[0])),
        tq(tx_power(TX_LEVEL[0])),
        tq(radio_gauge("wlc_ap_radio_stats_aid_user_list", stats=True)),
        tq(radio_gauge("wlc_rrm_load_cca_util_percentage")),
        tq(radio_gauge("wlc_rrm_load_tx_util_percentage")),
        tq(radio_gauge("wlc_rrm_load_rx_util_percentage")),
        tq(radio_gauge("wlc_rrm_load_non_wifi_inter")),
        tq(radio_rate("wlc_ap_radio_stats_cumulative_tx_bytes", "6m") + " * 8"),
        tq(radio_rate("wlc_ap_radio_stats_cumulative_rx_bytes", "6m") + " * 8"),
        tq(radio_gauge("wlc_ap_radio_bss_color_cfg_bss_color")),
    ], desc="Every AP radio, now. Channel is the primary channel (Channels: the bonded set). Tx power level 1 is the "
            "radio's maximum. Channel busy (CCA) is the share of time the radio heard the channel busy: its own "
            "transmit, receive from its clients and everything else; RRM measures it every 180 s. Tx/rx are the "
            "radio's own traffic over the last 6 minutes (the AP refreshes these counters every 180 s)."
            + FIRST_ENTRY_GAP,
        transformations=[MERGE, organize(exclude=["Time", "host", "wtp_mac", "Value #A"], rename={
            "ap": "AP", "radio_slot_id": "Slot", "current_active_band": "Band", "oper_state": "State",
            "admin_state": "Admin", "Value #B": "Channel", "phy_ht_cfg_cfg_data_freq_string": "Channels",
            "Value #C": "Width", "Value #D": "Tx power", "Value #E": "Power level", "Value #F": "Clients",
            "Value #G": "Channel busy", "Value #H": "Tx airtime", "Value #I": "Rx airtime", "Value #J": "Non-Wi-Fi",
            "Value #K": "Tx", "Value #L": "Rx", "phy_ht_cfg_cfg_data_rrm_channel_change_reason": "Last channel change",
            "Value #M": "BSS color"},
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
        ], sort="AP"), 24, 6)

    radio = "{{radio}}"
    b.add(timeseries("Channel busy (CCA) per radio", [
        q(per_radio(radio_gauge("wlc_rrm_load_cca_util_percentage")), radio)],
        unit="percent", min_=0, max_=100, fill=10, thresholds=CCA,
        desc="RRM's channel utilization per radio (updated every 180 s, so the line moves in steps)."), 8, 8)
    b.add(timeseries("Clients per radio", [
        q(per_radio(radio_gauge("wlc_ap_radio_stats_aid_user_list", stats=True)), radio)],
        decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Associated clients per radio (radio-oper-stats aid_user_list)."), 8, 8)
    b.add(interval(timeseries("Radio traffic", [
        q(per_radio(radio_rate("wlc_ap_radio_stats_cumulative_tx_bytes") + " * 8"), radio + " tx"),
        q(per_radio(radio_rate("wlc_ap_radio_stats_cumulative_rx_bytes") + " * -8"), radio + " rx"),
    ], unit="bps", fill=10, desc="Each radio's own traffic (tx up, rx down), from counters the AP refreshes every "
                                 "180 s, so rates are over windows of at least 6 minutes."), RATE_180), 8, 8)
    b.add(timeseries("Channel per radio", [
        q(per_radio(radio_gauge("wlc_ap_radio_phy_ht_cfg_cfg_data_curr_freq")), radio)],
        decimals=0, fill=0, step=True, desc="Primary channel; a step is an RRM (DCA) channel change."), 8, 7)
    b.add(timeseries("Tx power per radio", [q(per_radio(tx_power(TX_POWER[0])), radio)],
                     unit="dBm", decimals=0, fill=0, step=True, desc="Transmit power (TPC changes it in steps)."), 8, 7)
    b.add(interval(timeseries("Radio retries and failures", [
        q(per_radio(radio_rate("wlc_ap_radio_stats_retry_count")), radio + " retries"),
        q(per_radio(radio_rate("wlc_ap_radio_stats_failed_count")), radio + " failed"),
    ], unit="short", fill=0, desc="Frames per second the radio had to retry, and frames it gave up on."), RATE_180),
        8, 7)

    # RF environment ----------------------------------------------------------------------
    b.row("RF environment")
    b.add(timeseries("Airtime per radio", [
        q(per_radio(radio_gauge("wlc_rrm_load_" + f)), radio + " " + n)
        for f, n in (("tx_util_percentage", "tx"), ("rx_util_percentage", "rx"),
                     ("rx_noise_channel_utilization", "rx noise"), ("non_wifi_inter", "non-Wi-Fi"))],
        unit="percent", min_=0, fill=0, desc="What the channel time goes to (RRM load, every 180 s): the radio's "
                                             "own tx and rx, receiving noise/other networks, and non-Wi-Fi "
                                             "interference."), 12, 8)
    b.add(interval(timeseries("AP uplink", [
        q(with_ap(f'sum by (host, wtp_mac) ({rate(m("wlc_ap_ethernet_rx_total_bytes"))}) * 8'), "{{ap}} in"),
        q(with_ap(f'sum by (host, wtp_mac) ({rate(m("wlc_ap_ethernet_tx_total_bytes"))}) * -8'), "{{ap}} out"),
    ], unit="bps", fill=10, desc="Each AP's Ethernet uplink as the AP counts it (in = received from the switch, up; "
                                 "out = sent to it, down). FlexConnect APs switch client traffic locally, so this "
                                 "is the clients' traffic. Refreshed every 180 s."), RATE_180), 12, 8)

    chan_key = f"{RADIO_KEY}, chan"
    noise = per_radio(f'max by ({chan_key}) ({relabel(m("wlc_rrm_noise_noise_data_noise"), "chan", "noise_data_chan")})')

    def foreign(field):
        return f'max by ({chan_key}) ({relabel(m("wlc_rrm_foreign_foreign_data_" + field), "chan", "foreign_data_chan")})'

    b.add(table("Noise and other networks per channel", [
        tq(f'label_join({padded(noise, "chan", "chan3")}, "key", "/", "radio", "chan3")'),
        tq(foreign("power")),
        tq(foreign("chan_util")),
        tq(" + ".join(foreign(f) for f in ("rogue_20_count", "rogue_40_primary_count", "rogue_80_primary_count"))),
    ], desc="What each radio hears when it scans the band's channels (RRM, every 180 s or more): the noise floor, "
            "the strongest other Wi-Fi network (-128 dBm = none heard), how busy other networks keep the channel, "
            "and how many other access points it heard with that primary channel.",
        transformations=[MERGE, sort_by("key"), as_numbers("chan"), organize(
            exclude=["Time", "host", "wtp_mac", "radio_slot_id", "band", "chan3", "key"],
            rename={"radio": "Radio", "chan": "Channel", "Value #A": "Noise floor",
                    "Value #B": "Strongest other network", "Value #C": "Other networks' airtime",
                    "Value #D": "Other APs"},
            order=["Radio", "Channel", "Noise floor", "Strongest other network", "Other networks' airtime",
                   "Other APs"])],
        overrides=[color_cell("Noise floor", NOISE, "dBm"),
                   override("Strongest other network", {"unit": "dBm", "mappings": mapping(**{"-128": ("none", "text")}),
                                                        "thresholds": steps(("text", None), ("yellow", -80),
                                                                            ("orange", -70), ("red", -60)),
                                                        "custom.cellOptions": {"type": "color-text"}}),
                   override("Other networks' airtime", {"unit": "percent", "thresholds": CCA, "min": 0, "max": 100,
                                                        "custom.cellOptions": {"type": "gauge", "mode": "basic",
                                                                               "valueDisplayMode": "text"}})]), 12, 10)
    bars = f'label_join(label_join({padded(noise, "chan", "chan3")}, "channel", " ch ", "band", "chan"), "key", "/", "band", "chan3")'
    b.add(bargauge("Noise floor per channel", [tq(f"max by (channel, key) ({bars})")],
                   unit="dBm", min_=-100, max_=-50, thresholds=NOISE, mode="basic", bar_height=12,
                   transformations=[sort_by("key"), organize(exclude=["Time", "key"])],
                   desc="Noise floor per scanned channel, now; lower is better."), 12, 10)
    # One bar per row of the table, named by its channel column.
    p = b.target[-1]
    p["options"]["reduceOptions"] = {"values": True, "calcs": ["lastNotNull"], "fields": "/^Value$/", "limit": 100}

    # SSIDs ------------------------------------------------------------------------------
    b.row("SSIDs")
    b.add(table("WLANs", [
        tq(one("host, wlan_id", f'max by (host, wlan_id, wlan_profile_name) ({m("wlc_wlan_clients_info")})')),
        tq(f'max by (host, wlan_id) ({m("wlc_wlan_clients_client_curr_state_run")})'),
        tq(f'max by (host, wlan_id) ({m("wlc_wlan_clients_total_random_mac_clients")})'),
        tq(one("host, wlan_id", f'max by (host, wlan_id, ssid) ({m("wlc_ap_slot_wlan_info")})')),
        tq(f'sum by (host, wlan_id) ({rate(m("wlc_ap_slot_wlan_bytes_tx"), "3m")}) * 8'),
        tq(f'sum by (host, wlan_id) ({rate(m("wlc_ap_slot_wlan_bytes_rx"), "3m")}) * 8'),
    ], desc="Configured WLANs per WLC with clients in RUN state now, and the traffic over all radios in the last "
            "3 minutes (download = to the clients)." + FIRST_ENTRY_GAP,
        transformations=[MERGE, as_numbers("wlan_id"), organize(exclude=["Time", "Value #A", "Value #D"], rename={
            "host": "WLC", "wlan_id": "WLAN ID", "wlan_profile_name": "Profile", "ssid": "SSID", "Value #B": "Clients",
            "Value #C": "Random MAC clients", "Value #E": "Download", "Value #F": "Upload"},
            order=["WLC", "WLAN ID", "Profile", "SSID", "Clients", "Random MAC clients", "Download", "Upload"])],
        overrides=[override("Download", {"unit": "bps", "decimals": 1}),
                   override("Upload", {"unit": "bps", "decimals": 1})], sort="WLAN ID"), 10, 7)
    b.add(timeseries("Clients per WLAN", [q(
        f'max by (host, wlan_id) ({m("wlc_wlan_clients_client_curr_state_run")})', "{{host}} WLAN {{wlan_id}}")],
        decimals=0, min_=0, fill=20, stack=True, step=True, desc="Clients in RUN state per WLAN id "
                                                                 "(wlan-client-stats)."), 7, 7)
    ssids = one("host, wlan_id", f'max by (host, wlan_id, ssid) ({m("wlc_ap_slot_wlan_info")})')

    def per_ssid(expr):
        return (f"(({expr}) * on (host, wlan_id) group_left (ssid) {ssids} or on (host, wlan_id) "
                f"{relabel(expr, 'ssid', 'wlan_id', '(.*)', 'WLAN $1')})")

    b.add(interval(timeseries("Traffic per SSID", [
        q(per_ssid(f'sum by (host, wlan_id) ({rate(m("wlc_ap_slot_wlan_bytes_tx"))}) * 8'), "{{ssid}} download"),
        q(per_ssid(f'sum by (host, wlan_id) ({rate(m("wlc_ap_slot_wlan_bytes_rx"))}) * -8'), "{{ssid}} upload"),
    ], unit="bps", fill=10, desc="Per SSID over all radios (wtp-slot-wlan-stats): download (to the clients) up, "
                                 "upload down. The AP refreshes these every 90 s."), RATE_90), 7, 7)

    # Clients ------------------------------------------------------------------------------
    b.row("Clients")
    b.add(table("Clients", client_table_targets(), desc=(
        "Every client of the selected WLCs, now. Download/upload and retries are over the last 3 minutes (the AP "
        "refreshes client counters every 90 s). Rate is the current PHY rate, MCS the last data rate's HT/VHT/HE "
        "MCS index (empty for a legacy rate). Connected for counts from the association. Click a client for its "
        "history." + FIRST_ENTRY_GAP),
        transformations=CLIENT_TRANSFORMS, overrides=client_overrides(), sort="AP"), 24, 8)
    b.add(timeseries("Clients per WLC", [
        q(f'max by (host) ({m("wlc_client_live_run_state_clients")})', "{{host}}"),
    ], decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Clients in RUN state per WLC (client-live-stats)."), 6, 8)
    b.add(timeseries("Clients by band and protocol", [q(
        f'count by (kind) (max by (host, client_mac, kind) ({client_kind(m("wlc_client_common_info"))}))', "{{kind}}")],
        decimals=0, min_=0, fill=20, stack=True, step=True,
        desc="Clients per radio type (common-oper-data ms_radio_type, e.g. dot11ax 5ghz)."), 6, 8)
    b.add(timeseries("Client signal (RSSI)", [
        q(per_client(client_gauge("wlc_client_traffic_most_recent_rssi")), CLIENT_LEGEND)],
        unit="dBm", fill=0, thresholds=RSSI, desc="Received signal strength of each client at the AP."), 6, 8)
    b.add(interval(timeseries("Client throughput", [
        q(per_client(client_rate("wlc_client_traffic_bytes_tx", scale=" * 8")), CLIENT_LEGEND + " down"),
        q(per_client(client_rate("wlc_client_traffic_bytes_rx", scale=" * -8")), CLIENT_LEGEND + " up"),
    ], unit="bps", fill=10, desc="Download (to the client) up, upload down, per client."), RATE_90), 6, 8)

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
                     "The C9800 WLCs from model-driven telemetry (Prometheus job wlc, wlc_* series): controllers, "
                     "APs and radios, channel use and RF, SSIDs and clients.",
                     b, tags=["wireless", "network"], variables=[wlc_var()], time_from="now-3h",
                     extra_links=[WIFI_LINK, url_link("WLC logs", f"{LOGS_NET}?var-device=c9800-wlc-1"
                                                                  f"&var-device=c9800-wlc-2"),
                                  url_link("SNMP Device Summary", SNMP_SUMMARY), url_link("SNMP Interface Detail",
                                                                                          SNMP_DETAIL)])


# The clients table: one instant query per tree, every one keyed by host + mac, merged in Grafana.
def client_table_targets(one_client=False):
    """Queries for the clients table (one_client=True: only $client, for the client dashboard)."""
    def only(label):
        return (f'{label}="${{client}}"',) if one_client else ()

    def strings(name, label, labels, fn=lambda e: e):
        return tq(one("host, mac", f"max by (host, mac, {labels}) ({fn(by_mac(m(name, *only(label)), label))})"))

    def num(name, scale=""):
        return tq(client_gauge(name, *only("ms_mac_address"), scale=scale))

    def per_s(name, scale=""):
        return tq(client_rate(name, *only("ms_mac_address"), window="3m", scale=scale))

    security = lambda e: f'label_join({e}, "security", " ", "ms_wifi_wpa_version", "ms_wifi_auth_key_mgmt")'
    return [
        strings("wlc_client_common_info", "client_mac", "ap_name, co_state, band, protocol", client_band),  # A
        strings("wlc_client_dot11_info", "ms_mac_address", "vap_ssid, security", security),             # B
        num("wlc_client_dot11_current_channel"),                                                          # C
        num("wlc_client_traffic_most_recent_rssi"),                                                       # D
        num("wlc_client_traffic_most_recent_snr"),                                                        # E
        num("wlc_client_traffic_speed", " * 1000000"),                                                    # F
        num("wlc_client_traffic_current_rate_mcs"),                                                       # G
        num("wlc_client_traffic_spatial_stream"),                                                         # H
        per_s("wlc_client_traffic_bytes_tx", " * 8"),                                                     # I
        per_s("wlc_client_traffic_bytes_rx", " * 8"),                                                     # J
        per_s("wlc_client_traffic_data_retries"),                                                         # K
        strings("wlc_client_ip_info", "mac_addr", "ipv4_binding_ip_key_ip_addr"),                         # L
        tq(f'time() - ({client_gauge("wlc_client_dot11_ms_assoc_time_seconds", *only("ms_mac_address"))} > 0)'),  # M
    ]


CLIENT_COLUMNS = {
    "mac": "Client", "ipv4_binding_ip_key_ip_addr": "IP", "ap_name": "AP", "vap_ssid": "SSID", "band": "Band",
    "protocol": "Protocol", "Value #C": "Channel", "Value #D": "RSSI", "Value #E": "SNR", "Value #F": "Rate",
    "Value #G": "MCS", "Value #H": "Streams", "Value #I": "Download", "Value #J": "Upload", "Value #K": "Retries",
    "co_state": "State", "security": "Security", "Value #M": "Connected for", "host": "WLC",
}
CLIENT_TRANSFORMS = [MERGE, organize(exclude=["Time", "Value #A", "Value #B", "Value #L"], rename=CLIENT_COLUMNS,
                                     order=list(CLIENT_COLUMNS.values()))]


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
ERROR_FIELDS = ("data_retries", "tx_retries", "tx_excessive_retries", "tx_total_drops", "decrypt_failed",
                "mic_mismatch", "mic_missing", "duplicate_rcv", "policy_errs")


def client():
    b = Board()
    b.row("Now")
    b.add(table("Client", client_table_targets(one_client=True), desc=(
        "The selected client now (empty when it isn't associated). Download/upload over the last 3 minutes."),
        transformations=CLIENT_TRANSFORMS, overrides=client_overrides(link=False)), 24, 4)

    this = 'ms_mac_address="${client}"'

    def gauge_(name, scale=""):
        return f"max({m(name, this)}){scale}"

    def per_s(name, scale=""):
        return f"sum({rate(m(name, this))}){scale}"

    b.row("Signal and rate")
    b.add(timeseries("Signal", [
        q(gauge_("wlc_client_traffic_most_recent_rssi"), "RSSI (dBm)"),
        q(gauge_("wlc_client_traffic_most_recent_snr"), "SNR (dB)"),
    ], fill=0, desc="RSSI (dBm, at the AP) and SNR (dB). Below about -75 dBm / 20 dB, rates and retries suffer.",
        overrides=[fixed_color("RSSI (dBm)", "blue"), fixed_color("SNR (dB)", "green")]), 12, 8)
    b.add(timeseries("PHY rate and streams", [
        q(gauge_("wlc_client_traffic_speed", " * 1000000"), "PHY rate"),
        q(gauge_("wlc_client_traffic_spatial_stream"), "Spatial streams"),
    ], unit="bps", fill=0, step=True, desc="Current PHY data rate and spatial streams.",
        overrides=[fixed_color("PHY rate", SERIES[1]),
                   override("Spatial streams", {"unit": "none", "decimals": 0, "custom.axisPlacement": "right",
                                                "color": {"mode": "fixed", "fixedColor": SERIES[0]}})]),
        12, 8)

    b.row("Traffic")
    b.add(interval(timeseries("Throughput", [
        q(per_s("wlc_client_traffic_bytes_tx", " * 8"), "download"),
        q(per_s("wlc_client_traffic_bytes_rx", " * -8"), "upload"),
    ], unit="bps", fill=20, desc="Download (sent to the client) up, upload down. Counters refresh every 90 s.",
        overrides=[fixed_color("download", DOWN), fixed_color("upload", UP)]), RATE_90), 12, 8)
    b.add(interval(timeseries("Packets", [
        q(per_s("wlc_client_traffic_pkts_tx"), "download"),
        q(per_s("wlc_client_traffic_pkts_rx", " * -1"), "upload"),
    ], unit="pps", fill=10, overrides=[fixed_color("download", DOWN), fixed_color("upload", UP)]), RATE_90), 12, 8)
    b.add(interval(timeseries("Retries, drops and errors", [
        q(per_s("wlc_client_traffic_" + f), f) for f in ERROR_FIELDS
    ], unit="short", fill=0, desc="Per second. data_retries are frames the AP sent again; tx_total_drops frames it "
                                  "gave up on; decrypt_failed/mic_* point at key or security problems.",
        overrides=[fixed_color(n, c) for n, c in RETRY_COLORS.items()]), RATE_90), 24, 8)

    b.row("Where")
    p = state_timeline("AP, SSID and channel", [
        q(f'max by (ap_name) ({m("wlc_client_common_info", THIS_CLIENT)})',
          "AP: {{ap_name}}"),
        q(f'max by (vap_ssid) ({m("wlc_client_dot11_info", this)})', "SSID: {{vap_ssid}}"),
        q(gauge_("wlc_client_dot11_current_channel"), "Channel"),
    ], show_value="auto", color={"mode": "palette-classic"},
        overrides=[override("(AP|SSID): .*", {"mappings": mapping(**{"1": ("associated", "text")})}, regex=True),
                   override("Channel", {"unit": "prefix:ch "})],
        desc="Roams (AP), SSID and channel changes: a row per AP and SSID the client used (shaded while it was on "
             "it), and its channel; gaps are times the client wasn't associated.")
    b.add(p, 24, 6)

    empty_notes(b, {"Client": "Client not associated in the last 3 minutes",
                    **dict.fromkeys(["Signal", "PHY rate and streams", "Throughput", "Packets",
                                     "Retries, drops and errors", "AP, SSID and channel"], NOT_SEEN)})

    return dashboard(UIDS["client"], "Wireless client (C9800)",
                     "One wireless client (picker: MAC, from the WLCs' telemetry): where it is, signal, rates, "
                     "throughput, retries and errors over time.",
                     b, tags=["wireless", "network"], variables=[wlc_var(), client_var(), client_cisco_var()],
                     time_from="now-3h",
                     extra_links=[WIFI_LINK, url_link("WLC logs", f"{LOGS_NET}?var-device=c9800-wlc-1"
                                                                  f"&var-device=c9800-wlc-2"
                                                                  f"&var-search=${{client_cisco}}")])


DASHBOARDS = {
    "Network/wireless-overview.json": overview,
    "Network/wireless-client.json": client,
}
