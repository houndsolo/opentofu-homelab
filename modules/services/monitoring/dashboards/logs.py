"""The log dashboards (folder Logs): overview, network devices, fw-wan, Proxmox & Ceph, services.

Built by custom.py (python3 -I modules/services/monitoring/dashboards/custom.py) with
its helpers; see custom.py for the conventions. They query the provisioned Loki
datasource (uid "loki", the VIP 10.13.11.101:3100), which holds:

- source="syslog": everything Alloy's syslog listeners on loki01-03 receive (VyOS
  leaves, fw-wan, dhcp01/02, PVE nodes, MikroTik, FS switches, C9800 WLCs; dns01/02 too
  until they moved to Alloy's journal source in 2026-11).
  Labels host, app (syslog tag; empty for the switches and WLCs, whose raw lines carry
  the Cisco-style %FAC-SEV-MNEMONIC instead), level (syslog severity: informational,
  warning, ...), facility. The Ceph cluster log is app="ceph-cluster", once per mon.
- source="journal": the journal of every Linux VM (Alloy): the monitoring stack's VMs and
  services-config's dns, netbox, proxy, valkey and triage VMs (rsyslog before 2026-11, as
  source="syslog"). Labels host, unit, app, level (journal priority: info, warning, ...) and
  container for Podman containers.

VyOS's rsyslog sends every non-kernel line twice (imjournal, and imuxsock with a leading
space); Alloy drops the imuxsock copy on receipt (templates/config.alloy.tftpl), so lines
from before that change are in Loki twice.

Two quirks the queries handle:

- Podman writes a container's stderr with priority "err", so most container lines
  (Loki, Prometheus, haproxy, ...) carry level="error" whatever they say. LEVEL
  rewrites `level` to one scale (error, warning, notice, info, debug): the line's own
  level (level=/lvl=/[NOTICE]) for container lines, the label otherwise.
- Host names are upper case for the VyOS leaves in Loki (LEAF-11) and lower case in
  Prometheus (leaf-11): host pickers match case-insensitively, so links from the
  Prometheus dashboards can pass their host label as is.

Pickers are used as plain $var, not ${var:regex}: the Loki datasource then regex-escapes the
picked values itself (with a doubled backslash, as LogQL wants inside "..."). Grafana's regex
format escapes with a single backslash, which Loki rejects ("invalid char escape") for values
like frrinit.sh or (sd-pam). The custom All values (.*, the host lists) pass through unescaped.

Line filters come right after the stream selector and the parsers after them, so Loki
only parses the lines a panel needs. Counts per bucket use $__auto (the step Grafana
picks for the panel width); totals use $__range.
"""
from custom import (
    BFD_MAP, BGP_MAP, BLUE, MERGE, ORANGE_IF_ANY, RED_IF_ANY, STACK_DASH, Board, bargauge, cell,
    dashboard, fixed_color, mapping, organize, override, panel, q, stat, state_timeline, steps, table,
    timeseries,
)

LOKI = {"type": "loki", "uid": "loki"}
MIXED = {"type": "datasource", "uid": "-- Mixed --"}
UIDS = {"overview": "logs-overview", "network": "logs-network", "fw": "logs-fw-wan", "pve": "logs-proxmox",
        "services": "logs-services"}
LOGS_LINK = {"type": "dashboards", "tags": ["logs"], "asDropdown": True, "title": "Logs dashboards",
             "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
             "tooltip": "", "url": ""}
TIME = "${__url_time_range}"

# Normalises `level` (see the module docstring). The regexp only feeds container lines;
# lvl_ is dropped again so it doesn't show up as a label. The last alternative is a leading
# RFC3339 timestamp: Telegraf ("2026-11-10T05:27:00Z I! Starting", one-letter
# I/W/E/D codes) and zap-style loggers ("<ts>\tinfo\t...", e.g. the retired influxd).
LEVEL = (r'| regexp `(?:\blevel="?|\blvl=|^\[|\] |^\d{4}-\d\d-\d\dT\S+Z\s+)(?P<lvl_>[A-Za-z]+)` '
         r'| label_format level=`{{ $l := lower (or (and .container .lvl_) .level) }}'
         # eq with several arguments: true if $l equals any of them (cheaper than regexReplaceAll,
         # which Loki compiles for every line).
         r'{{ if eq $l "error" "err" "eror" "e" "crit" "critical" "alert" "emerg" "emergency" "fatal" "panic" }}error'
         r'{{ else if eq $l "warning" "warn" "w" }}warning{{ else if eq $l "notice" }}notice'
         r'{{ else if eq $l "debug" "trace" "d" }}debug{{ else }}info{{ end }}` | drop lvl_')
LEVEL_COLORS = {"error": "red", "warning": "orange", "notice": "blue", "info": "green", "debug": "text"}

NET_HOSTS = "LEAF-[0-9]+|fw-wan|m3[0-9]+-[0-9]+|switch-[0-9]+|c9800-wlc-[0-9]+"
PVE_HOSTS = "fichina|macbeth|titania|zoness|fortuna|eldarad|venom|greatfox"
MON_CONTAINERS = ("grafana|prometheus|alertmanager|mimir|loki|alloy|haproxy|blackbox-exporter|node-exporter|"
                  "snmp-exporter|telegraf|postgres|postgres-exporter")


# --- building blocks -------------------------------------------------------------

def lq(expr, legend="", instant=False, max_lines=None):
    """A Loki target: a metric query (range, or instant for totals and tables) or a log query."""
    t = {"datasource": LOKI, "editorMode": "code", "expr": expr, "queryType": "instant" if instant else "range",
         "legendFormat": legend}
    if max_lines:
        t["maxLines"] = max_lines
    return t


def on_loki(p):
    p["datasource"] = dict(LOKI)
    for t in p["targets"]:
        t.setdefault("datasource", dict(LOKI))
    return p


def count(sel, window="$__auto"):
    return f"count_over_time({sel} [{window}])"


def total(sel):
    """Lines in the time range, 0 rather than "No data"."""
    return f"sum({count(sel, '$__range')}) or vector(0)"


def per_bucket(title, targets, *, desc="", stack=True, **kw):
    """Lines per $__auto bucket, as stacked bars."""
    kw.setdefault("no_value", "Nothing in range")
    return on_loki(timeseries(title, targets, desc=desc, draw="bars", fill=70, stack=stack, calcs=("sum", "max"),
                              decimals=0, **kw))


def by_total(p):
    """Sort a per_bucket legend by its Total (sum) column, largest first."""
    p["options"]["legend"].update(sortBy="Total", sortDesc=True)
    return p


def range_stat(title, sel, *, desc="", thresholds=None, **kw):
    """Lines in the time range matching sel."""
    return on_loki(stat(title, [lq(total(sel), title, instant=True)], desc=desc, decimals=0, color_mode="value",
                        thresholds=thresholds or BLUE, no_value="0", **kw))


def top(title, expr, legend, *, n=10, desc="", thresholds=None, links=None, **kw):
    """Top n series of a count over the time range, as horizontal bars, largest first.

    sort_desc: the bar gauge keeps the frame order, and topk's frames come sorted by label.
    """
    p = on_loki(bargauge(title, [lq(f"sort_desc(topk({n}, {expr}))", legend, instant=True)], desc=desc, decimals=0,
                         thresholds=thresholds or BLUE, mode="gradient", no_value="Nothing in range", **kw))
    if links:
        p["fieldConfig"]["defaults"]["links"] = [{"title": t, "url": u, "targetBlank": False} for t, u in links]
    return p


def logs(title, expr, *, desc="", max_lines=500, wrap=True):
    p = on_loki(panel("logs", title, [lq(expr, max_lines=max_lines)], desc=desc, options={
        "showTime": True, "showLabels": False, "showCommonLabels": False, "wrapLogMessage": wrap,
        "prettifyLogMessage": False, "enableLogDetails": True, "enableInfiniteScrolling": True,
        "dedupStrategy": "none", "sortOrder": "Descending"}))
    del p["fieldConfig"]  # the logs panel has no field config
    return p


def log_table(title, expr, columns, *, desc="", rename=None, widths=None, overrides=(), max_lines=300,
              no_value="No matching lines in range"):
    """Log lines as a table: Time, the listed labels (stream or parsed) and the line.

    Grafana returns a log query as one frame with the labels as a JSON field; extractFields
    turns them into columns and filterFieldsByName keeps the ones listed.
    """
    rename = {"Line": "Message", **(rename or {})}
    keep = ["Time", *columns, "Line"]
    widths = {"Time": 165, **(widths or {})}
    return on_loki(table(title, [lq(expr, max_lines=max_lines)], desc=desc, no_value=no_value, transformations=[
        {"id": "extractFields", "options": {"source": "labels", "format": "auto", "replace": False, "keepTime": False}},
        {"id": "filterFieldsByName", "options": {"include": {"names": keep}}},
        organize(rename=rename, order=[rename.get(c, c) for c in keep]),
    ], overrides=[override(rename.get(k, k), {"custom.width": v}) for k, v in widths.items()] + list(overrides),
        sort="Time", desc_sort=True))


def history(title, targets, *, desc="", thresholds=None, no_value="", **kw):
    """A status-history grid: one row per series, a cell per bucket coloured by its count."""
    return on_loki(panel("status-history", title, targets, desc=desc, decimals=0,
                         thresholds=thresholds or steps(("green", None), ("orange", 1), ("red", 10)),
                         custom={"fillOpacity": 80, "lineWidth": 0}, options={
                             "showValue": "never", "rowHeight": 0.85, "colWidth": 0.9,
                             "legend": {"showLegend": False, "displayMode": "list", "placement": "bottom"},
                             "tooltip": {"mode": "single", "sort": "none"}}, no_value=no_value, **kw))


def level_colors():
    return [fixed_color(k, c) for k, c in LEVEL_COLORS.items()]


def custom_var(name, label, options, *, multi=True, include_all=True, all_value=".*", current=None):
    """options: [(text, value)]."""
    v = {"name": name, "label": label, "type": "custom", "multi": multi, "includeAll": include_all,
         "query": ",".join(f"{t} : {val}" if t != val else val for t, val in options), "hide": 0,
         "options": [], "skipUrlSync": False}
    if include_all:
        v["allValue"] = all_value
    if current:
        v["current"] = {"selected": True, "text": current[0], "value": current[1]}
    elif include_all:
        v["current"] = {"selected": True, "text": ["All"], "value": ["$__all"]}
    return v


def loki_var(name, label, stream, label_name, *, multi=True, include_all=True, all_value=".*", regex="",
             current=None):
    query = f"label_values({stream}, {label_name})"
    v = {"name": name, "label": label, "type": "query", "datasource": LOKI, "definition": query, "query": query,
         "refresh": 2, "multi": multi, "includeAll": include_all, "options": [], "sort": 1, "regex": regex, "hide": 0}
    if include_all:
        v["allValue"] = all_value
        v["current"] = {"selected": True, "text": ["All"], "value": ["$__all"]}
    else:
        v["current"] = current or {}
    return v


def text_var(name, label, desc=""):
    return {"name": name, "label": label, "type": "textbox", "query": "", "current": {"text": "", "value": ""},
            "hide": 0, "description": desc, "options": []}


SEARCH = text_var("search", "Search (regex)", "Case-insensitive RE2 regex on the line; empty matches everything.")
LEVEL_VAR = custom_var("level", "Level", [(k, k) for k in LEVEL_COLORS])


def search(var="search"):
    return f" |~ `(?i)${var}`"


def url_link(title, url):
    return {"type": "link", "title": title, "url": url, "icon": "dashboard", "includeVars": False, "keepTime": True,
            "asDropdown": False, "targetBlank": False, "tags": [], "tooltip": ""}


def logs_dashboard(key, title, description, b, *, tags=(), variables=(), extra_links=()):
    return dashboard(UIDS[key], title, description, b, tags=["logs", *tags], variables=variables,
                     time_from="now-6h", extra_links=[LOGS_LINK, *extra_links])


# --- Logs overview -------------------------------------------------------------------

def overview():
    # ${source}, not $source: tests/monitoring.tftest.hcl rejects "$source" (a datasource variable elsewhere).
    sel = '{source=~"${source}", host=~"(?i)$host", app=~"$app"}'
    lines = sel + search() + " " + LEVEL + ' | level=~"$level"'
    # Error and warning panels ignore the level picker.
    leveled = sel + search() + " " + LEVEL
    errors, warnings = leveled + ' | level="error"', leveled + ' | level="warning"'
    host_link = [("Only this host", f"/d/{UIDS['overview']}/{UIDS['overview']}?var-host=${{__field.labels.host}}&{TIME}")]

    b = Board()
    b.row("Summary")
    b.add(range_stat("Lines in range", lines, desc="Lines matching the pickers in the time range."), 4, 4)
    b.add(on_loki(stat("Lines / s", [lq(f"sum(rate({lines} [5m])) or vector(0)", "lines/s", instant=True)],
                       decimals=1, color_mode="value", thresholds=BLUE, desc="Over the last 5 minutes.")), 4, 4)
    b.add(range_stat("Errors in range", errors, thresholds=RED_IF_ANY,
                     desc="Lines at error or worse (emerg, alert, crit, err), after normalising container levels."), 4, 4)
    b.add(range_stat("Warnings in range", warnings, thresholds=ORANGE_IF_ANY), 4, 4)
    b.add(on_loki(stat("Hosts sending", [lq(f"count(sum by (host) ({count(sel, '5m')})) or vector(0)", "hosts",
                                            instant=True)],
                       decimals=0, color_mode="value", thresholds=BLUE,
                       desc="Hosts with at least one line in the last 5 minutes (source/host/app pickers).")), 4, 4)
    b.add(stat("Syslog parse errors", [
        q("sum(increase(loki_source_syslog_parsing_errors_total[$__range])) or vector(0)", "parse errors")],
        decimals=0, color_mode="value", thresholds=ORANGE_IF_ANY,
        desc="Syslog messages Alloy couldn't parse and dropped (Prometheus, job alloy). A sender in the wrong "
             "format shows up here, not in Loki.",
        links=[("Monitoring stack", STACK_DASH + "?" + TIME)]), 4, 4)

    b.row("Volume")
    b.add(per_bucket("Lines by source", [lq(f"sum by (source) ({count(lines)})", "{{source}}")],
                     overrides=[fixed_color("syslog", "blue"), fixed_color("journal", "purple")],
                     desc="syslog: devices and VMs sending syslog; journal: the monitoring and logging VMs' "
                          "journals (Alloy). The VyOS routers and DHCP VMs send every line twice; Alloy keeps one "
                          "copy, so their volume is doubled only before that change (2026-11)."), 8, 8)
    b.add(per_bucket("Lines by level", [lq(f"sum by (level) ({count(lines)})", "{{level}}")],
                     overrides=level_colors(), desc="Normalised level (see the dashboard description)."), 8, 8)
    # No topk: in a range query it keeps the top 10 of each bucket, and their union is nearly every host.
    b.add(by_total(per_bucket("Lines by host", [lq(f"sum by (host) ({count(lines)})", "{{host}}")],
                              desc="Every selected host, the legend sorted by total. The top hosts over the whole "
                                   "range: see Noisiest hosts.")), 8, 8)
    b.add(per_bucket("Errors by host", [lq(f"sum by (host) ({count(errors)})", "{{host}}")],
                     desc="Ignores the level picker."), 12, 8)
    b.add(per_bucket("Warnings by host", [lq(f"sum by (host) ({count(warnings)})", "{{host}}")],
                     desc="Ignores the level picker."), 12, 8)
    b.add(top("Noisiest hosts", f"sum by (host) ({count(lines, '$__range')})", "{{host}}", n=15,
              desc="Lines in the time range. Click a bar to show only that host.", links=host_link), 8, 10)
    b.add(top("Noisiest apps", f"sum by (app) ({count(lines, '$__range')})", "{{app}}", n=15,
              desc="Lines in the time range by syslog tag / journal identifier, over all selected hosts (per host "
                   "and app would exceed Loki's series limit). The switches and WLCs have no app."), 8, 10)
    b.add(top("Most errors", f"sum by (host, app) ({count(errors, '$__range')})", "{{host}} · {{app}}", n=15,
              thresholds=steps(("orange", None)), desc="Error lines in the time range by host and app.",
              links=host_link), 8, 10)

    b.row("Errors")
    b.add(log_table("Newest errors", errors, ["host", "app", "container"], max_lines=200,
                    desc="The newest 200 error lines (normalised level) matching the source/host/app/search pickers.",
                    rename={"host": "Host", "app": "App", "container": "Container"},
                    widths={"host": 120, "app": 150, "container": 110}), 24, 10)

    b.row("Logs")
    b.add(logs("Logs", lines, max_lines=1000,
               desc="All pickers apply. Click a line for its labels; the host label links to its Prometheus targets."),
          24, 22)

    source_var = custom_var("source", "Source", [("journal", "journal"), ("syslog", "syslog")], all_value=".+")
    host_var = loki_var("host", "Host", '{source=~"${source}"}', "host")
    # Hides Podman's random names of one-shot containers (admiring_haslett: config checks), which the
    # journal reports as the app; All still includes their lines.
    app_var = loki_var("app", "App", '{source=~"${source}", host=~"(?i)$host"}', "app",
                       regex="/^(?![a-z]+_[a-z]+$)(.+)$/")
    return logs_dashboard("overview", "Logs overview",
                          "Every log in Loki: volume by source, level and host, errors and warnings, the noisiest "
                          "hosts and apps, newest errors and a log browser with host/source/app/level/search pickers.",
                          b, variables=[source_var, host_var, app_var, LEVEL_VAR, SEARCH])


# --- Network device logs -----------------------------------------------------------

NET = '{source="syslog", host=~"$device"}'
WLC_HOSTS = "c9800-wlc-[0-9]+"
# (name, line regex, description). The regexes cover FRR/kernel/sshd on VyOS, RouterOS,
# FS (Cisco-like and Ruijie-like) and IOS-XE.
EVENTS = [
    ("BGP / BFD", r"\{l_addr: [^}]*\} [A-Za-z]+|(?i:state-change|bfd session|\bbgp\b.*\b(established|idle|notification|hold timer)\b)",
     "Log lines: RouterOS session state lines ('<session> {l_addr: .., r_addr: ..} Established/Idle') and "
     "'BFD session was not established'. FRR on VyOS logs %ADJCHANGE and BFD state changes at informational, "
     "but VyOS sets 'log syslog notifications', so its sessions come from frr_exporter (Prometheus) instead."),
    ("Interface up/down", r"(?i:\blink is (up|down)\b|\blink (up|down)\b|\bupdown\b|changed state to (up|down|administratively down)|carrier (lost|acquired))",
     "Kernel 'Link is Up/Down' (VyOS), RouterOS 'link up/down', Cisco/FS %LINK/%LINEPROTO UPDOWN "
     "(not systemd's 'ifupdown' units)."),
    ("STP", r"(?i:spantree|\bstp\b|mstp|rstp|topology change|topo(logy)?[ _-]?change|entered (blocking|forwarding|disabled|listening|learning) state)",
     "Spanning tree: topology changes, port role/state changes (also Linux bridge port states on VyOS)."),
    ("Auth failures", r"(?i:failed password|invalid user|authentication failure|login failure|auth fail|login_failed|authentication failed|failed publickey|maximum authentication attempts|bad password)",
     "Failed SSH/console logins: sshd, RouterOS 'login failure', FS 'auth fail', IOS-XE %SEC_LOGIN-4-LOGIN_FAILED."),
    ("Logins", r"(?i:accepted (publickey|password|keyboard-interactive)|logged in|login_success)",
     "Successful logins: sshd 'Accepted ...', RouterOS/FS 'logged in', IOS-XE %SEC_LOGIN-5-LOGIN_SUCCESS. "
     "The automation on a0-nix (10.20.250.255) logs in often."),
    ("Config changes", r"(?i:successful change to active configuration|config_i\b|%sys-\d-config|configured from|startup-config is wrote|\b(added|changed|removed|moved) by [a-z-]+:)",
     "VyOS commits, RouterOS '... changed by user', FS/IOS-XE 'Configured from' and saves."),
    ("AP join/leave", r"(?i:ap_join|disjoin|ap event|ap_air_state|\bap\b.*\b(joined|disassociated|reboot)\b|capwap.*\b(join|down)\b)",
     "C9800: access points joining or leaving the controller (%CAPWAPAC_SMGR_TRACE_MESSAGE-5-AP_JOIN_DISJOIN), "
     "AP reboots and AIR state."),
    ("Client failures", r"(?i:client_exclusion|exclusionlist|dot1x.*fail|mab.*fail|webauth.*fail|client.*(fail|reject|exclu|deauth|timeout))",
     "C9800: wireless clients excluded, failing 802.1X/MAB/web auth or being rejected (WLC lines only)."),
]
EVENT_RE = {name: regex for name, regex, _ in EVENTS}
ALL_EVENTS = "|".join(f"(?:{regex})" for _, regex, _ in EVENTS)
# The wireless categories only count the WLCs' lines: their regexes also match other devices (fw-wan's
# Telegraf "Client.Timeout exceeded" is no client failure). A label filter after NET keeps the device picker.
WLC_ONLY = ("AP join/leave", "Client failures")
NON_WLC_EVENTS = "|".join(f"(?:{regex})" for name, regex, _ in EVENTS if name not in WLC_ONLY)


def event_sel(sel, name):
    """sel's lines of one event category."""
    return f"{sel} |~ `{EVENT_RE[name]}`" + (f' | host=~"{WLC_HOSTS}"' if name in WLC_ONLY else "")


# RouterOS (spines, CRS317): overlay-leaf-20-1 {l_addr: fd69:255:240::1, r_addr: fd69:255:240::20} Established
ROS_BGP_CHANGE = r"\{l_addr: "
ROS_BGP_PARSE = r"| regexp `(?P<peer_name>\S+) \{l_addr: [^,]+, r_addr: (?P<peer>[^}]+)\} (?P<state>[A-Za-z]+(?: [a-z]+)*)`"
BGP_STATE_MAP = mapping(Established=("Established", "green"), Idle=("Idle", "red"), Active=("Active", "orange"),
                        Connect=("Connect", "orange"), OpenSent=("OpenSent", "orange"),
                        OpenConfirm=("OpenConfirm", "orange"))

# FRR sessions (VyOS leaves, fw-wan) from frr_exporter in Prometheus. Host labels are lower case
# there (leaf-11), so the Loki device picker matches case-insensitively.
FRR = 'host=~"(?i)$device"'
BGP_KEY = "host, vrf, peer, peer_hostname, afi, safi"
BFD_KEY = "host, local, peer"


def frr_flaps(state, uptime, key, at=""):
    """Per session: state changes the scrapes saw or uptime restarts, whichever is more.

    A flap shorter than the scrape interval (a bgpd restart) only shows as an uptime restart; a
    session that went down and stays down only as a state change. at="@ end()" counts over the
    dashboard range at its end (for filters in range queries).
    """
    return (f'max by ({key}) (changes({state}{{{FRR}}}[$__range] {at}) '
            f'or label_replace(resets({uptime}{{{FRR}}}[$__range] {at}), "via_", "uptime", "", ""))')


BGP_FLAPS = frr_flaps("frr_bgp_peer_state", "frr_bgp_peer_uptime_seconds", BGP_KEY)
BFD_FLAPS = frr_flaps("frr_bfd_peer_state", "frr_bfd_peer_uptime", BFD_KEY)


def changed(flaps, state, key, at=""):
    """Sessions that flapped in the range or aren't up now."""
    return f"(({flaps}) > 0 or max by ({key}) ({state}{{{FRR}}} {at}) != 1)"


def frr_session_table(title, state, uptime, flaps, key, rename, order, state_map, *, desc, no_value):
    sessions = changed(flaps, state, key)
    return table(title, [
        q(f"max by ({key}) (changes({state}{{{FRR}}}[$__range])) and on ({key}) {sessions}", table=True),
        q(f"max by ({key}) (resets({uptime}{{{FRR}}}[$__range])) and on ({key}) {sessions}", table=True),
        q(f"max by ({key}) ({state}{{{FRR}}}) and on ({key}) {sessions}", table=True),
        q(f"max by ({key}) ({uptime}{{{FRR}}}) and on ({key}) {sessions}", table=True),
    ], desc=desc, no_value=no_value, sort="Restarts", desc_sort=True, transformations=[
        MERGE, organize(exclude=["Time"], rename={**rename, "Value #A": "State changes", "Value #B": "Restarts",
                                                  "Value #C": "State now", "Value #D": "Uptime"},
                        order=[*order, "State changes", "Restarts", "State now", "Uptime"])],
        overrides=[cell("State now", "color-background"), override("State now", {"mappings": state_map}),
                   override("Uptime", {"unit": "dtdurations"}),
                   override("State changes|Restarts", {"thresholds": ORANGE_IF_ANY,
                                                       "custom.cellOptions": {"type": "color-text"}}, regex=True)])
# AP Event: AP Name: lylat-AP-1 Mac: 588b.1c93.07e0 Session-IP: 10.3.11.100[5264] 10.3.1.1[5246] Disjoined Heart beat timer expiry
AP_PARSE = (r"| regexp `AP Name: (?P<ap>\S+) .*?\b(?P<event>Joined|Disjoined)\b\s*(?P<reason>[^\n]*)`")


def network():
    sel = NET + search()
    b = Board()
    b.row("Events in range")
    for name, regex, desc in EVENTS:
        if name == "BGP / BFD":
            # Log lines (RouterOS, BFD failures) plus the FRR sessions' flaps from Prometheus.
            p = stat(name, [lq(total(event_sel(sel, name)), "logs", instant=True),
                            q(f"(sum({BGP_FLAPS}) or vector(0)) + (sum({BFD_FLAPS}) or vector(0))", "FRR",
                              instant=True)],
                     desc=desc + " FRR: BGP and BFD session flaps in range (state changes or uptime restarts, see "
                                 "the Routing row).", decimals=0, color_mode="value", text_mode="value_and_name",
                     thresholds=ORANGE_IF_ANY, no_value="0")
            p["datasource"] = dict(MIXED)
            b.add(p, 3, 4)
            continue
        thresholds = ORANGE_IF_ANY if name in ("Auth failures", "Client failures") else BLUE
        b.add(range_stat(name, event_sel(sel, name), desc=desc, thresholds=thresholds), 3, 4)

    b.row("Timelines")
    # The WLCs count every category, the other devices all but the wireless ones (disjoint hosts, so `or` adds up).
    per_device = (f"sum by (host) ({count(f'{sel} |~ `{NON_WLC_EVENTS}` | host!~`{WLC_HOSTS}`')}) or "
                  f"sum by (host) ({count(f'{sel} |~ `{ALL_EVENTS}` | host=~`{WLC_HOSTS}`')})")
    b.add(history("Events per device", [lq(per_device, "{{host}}")],
                  desc="Every event of the categories above, per device and time bucket (darker = more). "
                       "Only devices with events show up."), 24, 9)
    b.add(per_bucket("Events by category", [
        lq(f"sum({count(event_sel(sel, name))})", name) for name, _, _ in EVENTS],
        desc="One line can count in two categories (a 'login failure' line is also a login line on some "
             "devices)."), 12, 8)
    b.add(per_bucket("Lines per device", [lq(f"sum by (host) ({count(sel)})", "{{host}}")],
                     desc="All syslog lines of the selected devices (VyOS lines once: Alloy drops the duplicate "
                          "copy, see Logs overview)."),
          12, 8)

    b.row("Routing: BGP and BFD")
    frr_note = ("FRR on the VyOS leaves and fw-wan (frr_exporter, Prometheus; the device picker applies). "
                "VyOS doesn't send FRR's %ADJCHANGE to syslog (it sets 'log syslog notifications'). ")
    b.add(frr_session_table(
        "BGP session changes", "frr_bgp_peer_state", "frr_bgp_peer_uptime_seconds", BGP_FLAPS, BGP_KEY,
        {"host": "Router", "vrf": "VRF", "peer": "Peer", "peer_hostname": "Peer hostname", "afi": "AFI",
         "safi": "SAFI"}, ["Router", "VRF", "Peer", "Peer hostname", "AFI", "SAFI"], BGP_MAP,
        desc=frr_note + "Sessions that changed state at a scrape, restarted (uptime went back: also flaps shorter "
                        "than the scrape interval, like a bgpd restart) or aren't established now. State changes "
                        "count both directions (down and up again = 2).",
        no_value="No BGP session changed in range"), 12, 10)
    bgp_changed = changed(frr_flaps("frr_bgp_peer_state", "frr_bgp_peer_uptime_seconds", BGP_KEY, "@ end()"),
                          "frr_bgp_peer_state", BGP_KEY, "@ end()")
    b.add(state_timeline("BGP session state", [
        q(f"max by ({BGP_KEY}) (frr_bgp_peer_state{{{FRR}}}) and on ({BGP_KEY}) {bgp_changed}",
          "{{host}} {{vrf}} {{peer}} {{peer_hostname}} {{afi}}")],
        mappings=BGP_MAP, thresholds=steps(("red", None), ("green", 1), ("orange", 2)), no_value="No BGP session changed in range",
        desc=frr_note + "The sessions of the table on the left over time, at scrape resolution: a restart shorter "
                        "than the scrape interval doesn't show here. Gaps: the exporter wasn't scraped or bgpd was "
                        "restarting."), 12, 10)
    b.add(frr_session_table(
        "BFD session changes", "frr_bfd_peer_state", "frr_bfd_peer_uptime", BFD_FLAPS, BFD_KEY,
        {"host": "Router", "local": "Local", "peer": "Peer"}, ["Router", "Local", "Peer"], BFD_MAP,
        desc=frr_note + "BFD sessions that changed state, restarted or aren't up now.",
        no_value="No BFD session changed in range"), 8, 10)
    b.add(log_table("RouterOS BGP session changes", sel + f" |~ `{ROS_BGP_CHANGE}` {ROS_BGP_PARSE}",
                    ["host", "peer_name", "peer", "state"],
                    rename={"host": "Router", "peer": "Remote address", "peer_name": "Session", "state": "State"},
                    widths={"host": 90, "peer": 200, "peer_name": 150, "state": 100},
                    overrides=[override("State", {"mappings": BGP_STATE_MAP,
                                                  "custom.cellOptions": {"type": "color-text"}})],
                    desc="RouterOS session state lines (spines, CRS317: session name, remote address, state)."), 8, 10)
    b.add(logs("BGP / BFD log", f"{sel} |~ `{EVENT_RE['BGP / BFD']}`", desc=EVENTS[0][2]), 8, 10)

    b.row("Interfaces and spanning tree")
    ifsel = f"{sel} |~ `{EVENT_RE['Interface up/down']}`"
    b.add(per_bucket("Interface events per device",
                     [lq(f'sum by (host, state) ({count(ifsel + " | regexp `(?i)\\b(?P<state>up|down)\\b` "
                                                         "| label_format state=`{{ lower .state }}`")})',
                         "{{host}} {{state}}")],
                     desc="Link up/down lines by device and the first 'up'/'down' in the line."), 8, 9)
    b.add(logs("Interface up/down", ifsel, desc=EVENTS[1][2]), 8, 9)
    b.add(logs("Spanning tree", f"{sel} |~ `{EVENT_RE['STP']}`", desc=EVENTS[2][2]), 8, 9)

    b.row("Access and configuration")
    b.add(logs("Auth failures", f"{sel} |~ `{EVENT_RE['Auth failures']}`", desc=EVENTS[3][2]), 8, 10)
    b.add(logs("Logins", f"{sel} |~ `{EVENT_RE['Logins']}`", desc=EVENTS[4][2]), 8, 10)
    b.add(logs("Config changes", f"{sel} |~ `{EVENT_RE['Config changes']}`", desc=EVENTS[5][2]), 8, 10)

    b.row("Wireless (C9800) and Cisco-style messages")
    # NET plus a host filter (event_sel), like the stats: a non-WLC device shows the no-value text.
    b.add(log_table("AP join/leave", f"{event_sel(sel, 'AP join/leave')} {AP_PARSE}",
                    ["host", "ap", "event", "reason"],
                    rename={"host": "WLC", "ap": "AP", "event": "Event", "reason": "Reason / details"},
                    widths={"host": 100, "ap": 100, "event": 90},
                    overrides=[override("Event", {"mappings": mapping(Joined=("Joined", "green"),
                                                                      Disjoined=("Disjoined", "red")),
                                                  "custom.cellOptions": {"type": "color-text"}})],
                    desc=EVENTS[6][2]), 8, 10)
    b.add(logs("Client failures", event_sel(sel, "Client failures"), desc=EVENTS[7][2]), 8, 10)
    b.add(top("Message types (range)",
              f'sum by (host, mnemonic) (count_over_time({sel} |= "%" '
              '| regexp `%(?P<mnemonic>[A-Z0-9_]+-[0-7]-[A-Z0-9_]+)` | mnemonic!="" [$__range]))',
              "{{host}} {{mnemonic}}", n=20,
              desc="IOS-XE and FS messages by %FACILITY-SEVERITY-MNEMONIC in the time range."), 8, 10)

    b.row("All device logs")
    b.add(logs("Device logs", sel, max_lines=1000, desc="Everything the selected devices sent, newest first."), 24, 20)

    device_var = loki_var("device", "Device", f'{{source="syslog", host=~"{NET_HOSTS}"}}', "host", all_value=NET_HOSTS)
    return logs_dashboard("network", "Network device logs",
                          "Syslog of the VyOS leaves, fw-wan, MikroTik spines and CRS317s, FS switches and C9800 WLCs: "
                          "BGP/BFD, interface, STP, login and config events, AP and client events, per-device timelines.",
                          b, tags=["network"], variables=[device_var, SEARCH],
                          extra_links=[url_link("FRR / EVPN fabric", "/d/frr-evpn-fabric/frr-evpn-fabric")])


# --- fw-wan firewall & VPN logs --------------------------------------------------------

FW = '{source="syslog", host="fw-wan"}'
FW_PREFIX = r"^\s*\[ipv[46]-"
# [ipv4-NAM-deny_data-22-D]IN=guest_vrf OUT=eth5 MAC=... SRC=10.4.0.57 DST=... PROTO=TCP SPT=59081 DPT=7680 ...
FW_PARSE = (r"| regexp `^\s*\[(?P<family>ipv[46])-(?P<hook>[A-Z]+)-(?P<chain>.+)-(?P<rule>[^-\]]+)-(?P<act>[ADR])\]"
            r"\s*IN=(?P<in>\S*) OUT=(?P<out>\S*)` "
            # Not `logfmt src="SRC", ...`: Loki drops renamed logfmt labels in metric queries (sum by
            # (src) came back as one {} series), so extract the keys and rename them with label_format.
            r'| logfmt SRC, DST, PROTO, SPT, DPT | label_format src=SRC, dst=DST, proto=PROTO, spt=SPT, dpt=DPT '
            r'| label_format action=`{{ if eq .act "A" }}accept{{ else if eq .act "D" }}drop{{ else }}reject{{ end }}` '
            r"| drop act, __error__, __error_details__")
FW_ACTION_MAP = mapping(accept=("accept", "green"), drop=("drop", "red"), reject=("reject", "orange"))
CHARON = '{source="syslog", host="fw-wan", app=~"charon.*"}'
CHARON_NOISE = "sending packet|received packet|parsed \\S+ (request|response)|generating \\S+ (request|response)"
IKE_EVENTS = [
    ("initiating", "initiating (IKE|CHILD)_SA|establishing CHILD_SA"),
    ("established", "(IKE|CHILD)_SA \\S+ established"),
    ("retransmits", "retransmit \\d+ of"),
    ("failures", "(?i:giving up|failed|no proposal chosen|authentication_failed|peer not responding|timed out|unable to|no IKE config)"),
    ("deleted", "deleting (IKE|CHILD)_SA|closing CHILD_SA|IKE_SA \\S+ (deleted|rekeyed)"),
]


def fw_wan():
    fwlog = f"{FW} |~ `{FW_PREFIX}` |= `$addr` {FW_PARSE}"
    picked = fwlog + ' | action=~"${action:regex}"'
    denied = fwlog + ' | action=~"drop|reject"'
    b = Board()
    b.row("Firewall log")
    b.add(range_stat("Logged packets", picked, desc="Firewall rules with `log` enabled, in the time range "
                                                    "(action and address pickers apply)."), 4, 4)
    b.add(range_stat("Dropped", fwlog + ' | action="drop"', thresholds=steps(("red", None)),
                     desc="Logged drops (address picker applies)."), 4, 4)
    b.add(range_stat("Rejected", fwlog + ' | action="reject"', thresholds=steps(("orange", None))), 4, 4)
    b.add(range_stat("Accepted (logged)", fwlog + ' | action="accept"', thresholds=steps(("green", None))), 4, 4)
    b.add(on_loki(stat("Distinct sources", [lq(f"count(sum by (src) ({count(picked, '$__range')})) or vector(0)",
                                               "sources", instant=True)],
                       decimals=0, color_mode="value", thresholds=BLUE, desc="Source addresses in the logged packets.")),
          4, 4)
    b.add(on_loki(stat("Distinct destination ports", [
        lq(f"count(sum by (proto, dpt) ({count(picked, '$__range')})) or vector(0)", "ports", instant=True)],
        decimals=0, color_mode="value", thresholds=BLUE)), 4, 4)
    b.add(per_bucket("Logged packets by rule", [lq(f"sum by (chain, rule, action) ({count(picked)})",
                                                   "{{chain}} #{{rule}} {{action}}")],
                     desc="Per chain and rule; the action is the rule's (accept/drop/reject)."), 12, 9)
    b.add(per_bucket("By action", [lq(f"sum by (action) ({count(picked)})", "{{action}}")],
                     overrides=[fixed_color("accept", "green"), fixed_color("drop", "red"),
                                fixed_color("reject", "orange")]), 6, 9)
    b.add(per_bucket("By inbound interface", [lq(f"sum by (in) ({count(picked)})", "{{in}}")],
                     desc="IN= of the logged packet (a VRF device for routed traffic)."), 6, 9)
    tops = (("Top sources (dropped/rejected)", "src", "{{src}}"),
            ("Top destinations (dropped/rejected)", "dst", "{{dst}}"),
            ("Top destination ports (dropped/rejected)", "proto, dpt", "{{proto}} {{dpt}}"),
            ("Top rules (dropped/rejected)", "chain, rule", "{{chain}} #{{rule}}"))
    for title, by, legend in tops:
        b.add(top(title, f"sum by ({by}) ({count(denied, '$__range')})", legend,
                  thresholds=steps(("red", None)), desc="Logged drops and rejects in the time range "
                                                         "(the action picker doesn't apply)."), 6, 9)
    b.add(log_table("Firewall log", picked, ["chain", "rule", "action", "in", "out", "proto", "src", "spt", "dst", "dpt"],
                    rename={"chain": "Chain", "rule": "Rule", "action": "Action", "in": "In", "out": "Out",
                            "proto": "Proto", "src": "Source", "spt": "Sport", "dst": "Destination", "dpt": "Dport"},
                    widths={"chain": 120, "rule": 70, "action": 70, "in": 100, "out": 80, "proto": 60, "src": 230,
                            "spt": 70, "dst": 230, "dpt": 70},
                    overrides=[override("Action", {"mappings": FW_ACTION_MAP,
                                                   "custom.cellOptions": {"type": "color-text"}})],
                    max_lines=500, desc="The newest 500 logged packets. The Message column has the full line."), 24, 12)

    b.row("IPsec (strongSwan)")
    for name, regex in IKE_EVENTS:
        thresholds = ORANGE_IF_ANY if name in ("failures", "retransmits") else BLUE
        b.add(range_stat(f"IKE {name}", f"{CHARON} |~ `{regex}`", thresholds=thresholds,
                         desc=f"charon lines matching `{regex}` in the time range."), 4, 4)
    b.add(on_loki(stat("Lines (range)", [lq(total(CHARON), "lines", instant=True)], decimals=0, color_mode="value",
                       thresholds=BLUE, desc="All charon lines, packet traces included.")), 4, 4)
    b.add(per_bucket("IKE events", [lq(f"sum({count(CHARON + f' |~ `{regex}`')})", name) for name, regex in IKE_EVENTS],
                     overrides=[fixed_color("established", "green"), fixed_color("failures", "red"),
                                fixed_color("retransmits", "orange"), fixed_color("initiating", "blue"),
                                fixed_color("deleted", "purple")]), 12, 9)
    b.add(per_bucket("Initiations by connection", [lq(
        f'sum by (sa) ({count(CHARON + " |~ `initiating IKE_SA|establishing CHILD_SA` "
                                       "| regexp `(?:IKE|CHILD)_SA (?P<sa>[A-Za-z0-9][\\w.-]*)[\\[{]`")})', "{{sa}}")],
        desc="A connection that keeps initiating without 'established' is stuck CONNECTING (a peer that "
             "doesn't answer, like VPS-lylat-space)."), 12, 9)
    b.add(logs("strongSwan (without packet traces)", f"{CHARON} !~ `{CHARON_NOISE}`",
               desc="charon's log minus 'sending/received packet' and message parse/generate lines."), 16, 12)
    b.add(logs("WireGuard", f"{FW} |~ `(?i)wireguard|\\bwg[0-9]+\\b`",
               desc="The kernel's WireGuard module only logs with dynamic debug, so this is usually empty; "
                    "handshakes and traffic are on the fw-wan VPNs dashboard (metrics)."), 8, 12)

    b.row("Router log")
    b.add(logs("Config commits", '{source="syslog", host="fw-wan", app="commit"}',
               desc="VyOS 'Successful change to active configuration'."), 8, 10)
    b.add(logs("Everything else", f'{{source="syslog", host="fw-wan", app!~"charon.*|commit"}} !~ `{FW_PREFIX}`'
               + search(), desc="fw-wan's log without firewall, strongSwan and commit lines (search picker applies)."),
          16, 10)

    action_var = custom_var("action", "Action", [("drop", "drop"), ("reject", "reject"), ("accept", "accept")])
    addr_var = text_var("addr", "Address", "Only firewall lines containing this text (an address, port, interface).")
    return logs_dashboard("fw", "fw-wan firewall & VPN logs",
                          "fw-wan's syslog in Loki: the firewall log parsed (chain, rule, action, interfaces, "
                          "addresses, ports), top dropped sources/destinations/ports/rules, strongSwan IKE events "
                          "and the rest of the router log.",
                          b, tags=["fw-wan"], variables=[action_var, addr_var, SEARCH],
                          extra_links=[url_link("fw-wan firewall (metrics)", "/d/fw-wan-firewall/fw-wan-firewall"),
                                       url_link("fw-wan VPNs (metrics)", "/d/fw-wan-vpn/fw-wan-vpn")])


# --- Proxmox & Ceph logs -------------------------------------------------------------

PVE = '{source="syslog", host=~"$node"}'
CEPH = '{app="ceph-cluster", host="${cephmon}"}'
TASK_RE = (r"<(?P<user>[^>]+)> (?P<what>starting|end) task UPID:(?P<tnode>[^:]+):[^:]+:[^:]+:[^:]+:(?P<task>[^:]+):"
           r"(?P<vmid>[^:]*):[^:]+:\s*(?P<status>[^\n]*)")
# Only corosync's and pmxcfs's lines: pve-ha-lrm's "startup => wait_for_quorum" is no corosync event.
COROSYNC = '{source="syslog", host=~"$node", app=~"corosync|pmxcfs"}' + search()
COROSYNC_RE = (r"(?i:host: \d+ link: \d+ is (up|down)|new membership|members\[|quorum|token has not been "
               r"received|retransmit list|failed to receive)")
OSD_RE = r"(?i:osd\.\d+ (\[[^\]]*\] )?boot|osd\.\d+ (marked|failed|reported)|marked osd\.\d+|marking osd\.\d+|osd\.\d+ out\b)"
SLOW_RE = r"(?i:slow (ops|requests|operation)|slow_op)"
HEALTH_RE = r"Health check (failed|cleared|update)|HEALTH_ERR"
CEPH_SEV_COLORS = {"ERR": "red", "WRN": "orange", "SEC": "purple", "INF": "blue"}


def proxmox():
    sel = PVE + search()
    b = Board()
    b.row("Proxmox nodes: summary")
    b.add(range_stat("Errors", f"{sel} {LEVEL} | level=\"error\"", thresholds=RED_IF_ANY,
                     desc="Lines at error or worse from the selected nodes."), 3, 4)
    b.add(range_stat("Warnings", f"{sel} {LEVEL} | level=\"warning\"", thresholds=ORANGE_IF_ANY), 3, 4)
    b.add(range_stat("Failed tasks", f'{sel} |= "end task UPID" !~ `: OK\\s*$`', thresholds=ORANGE_IF_ANY,
                     desc="PVE tasks that ended with something other than OK."), 3, 4)
    b.add(range_stat("Tasks started", f'{sel} |= "starting task UPID"'), 3, 4)
    b.add(range_stat("Corosync events", f"{COROSYNC} |~ `{COROSYNC_RE}`", thresholds=ORANGE_IF_ANY,
                     desc="corosync/pmxcfs: link up/down, membership and quorum changes, token loss."), 3, 4)
    b.add(range_stat("HA events", '{source="syslog", host=~"$node", app=~"pve-ha-.*"}' + search(),
                     desc="pve-ha-crm/lrm lines (service starts, migrations, fencing)."), 3, 4)
    b.add(range_stat("Auth failures", f'{sel} |~ `(?i)authentication failure|auth fail|failed password|invalid user`',
                     thresholds=ORANGE_IF_ANY, desc="PVE web/API (pveproxy, pvedaemon) and SSH login failures."), 3, 4)
    b.add(range_stat("Lines", sel), 3, 4)

    b.row("Proxmox nodes: volume")
    b.add(per_bucket("Lines by node", [lq(f"sum by (host) ({count(sel)})", "{{host}}")]), 8, 8)
    b.add(by_total(per_bucket("Lines by app (top 10 per bucket)", [lq(f"topk(10, sum by (app) ({count(sel)}))",
                                                                        "{{app}}")],
                              desc="The 10 busiest apps of each bucket, so more than 10 over the range; the legend "
                                   "is sorted by total.")), 8, 8)
    b.add(per_bucket("Errors and warnings by node", [
        lq(f'sum by (host, level) ({count(sel + " " + LEVEL + " | level=~`error|warning`")})', "{{host}} {{level}}")],
        desc="Syslog severity err or worse, and warning."), 8, 8)

    b.row("Cluster: corosync, pmxcfs, HA")
    b.add(per_bucket("Corosync events by node", [lq(f"sum by (host) ({count(f'{COROSYNC} |~ `{COROSYNC_RE}`')})",
                                                    "{{host}}")],
                     no_value="No corosync events in range",
                     desc="corosync/pmxcfs: link up/down, membership and quorum changes, token loss."), 8, 10)
    b.add(logs("corosync / pmxcfs", COROSYNC,
               desc="Cluster communication and the cluster filesystem (/etc/pve)."), 8, 10)
    b.add(logs("HA manager", '{source="syslog", host=~"$node", app=~"pve-ha-.*"}' + search(),
               desc="pve-ha-crm (cluster resource manager) and pve-ha-lrm (local resource manager)."), 8, 10)

    b.row("Tasks and guests")
    tasks = f'{sel} |= " task UPID:" | regexp `{TASK_RE}`'
    b.add(top("Tasks by type (range)", f'sum by (task) ({count(tasks + " | what=`starting`", "$__range")})', "{{task}}",
              n=15, desc="PVE tasks started in the time range (qmstart, vzdump, vncproxy, ...)."), 6, 10)
    # vmid, not id: Loki's log frames already have an "id" field (the row id).
    b.add(log_table("Tasks", tasks, ["host", "user", "what", "task", "vmid", "status"],
                    rename={"host": "Node", "user": "User", "what": "Event", "task": "Task", "vmid": "Guest / ID",
                            "status": "Status"},
                    widths={"host": 90, "user": 110, "what": 70, "task": 110, "vmid": 90, "status": 160},
                    # Anything but OK (a failed task's error text) in red; starting rows have no status.
                    overrides=[override("Status", {"mappings": mapping(OK=("OK", "green")) + [
                        {"type": "regex", "options": {"pattern": "/^(?!OK$).+$/", "result": {"color": "red", "index": 1}}}],
                                                   "custom.cellOptions": {"type": "color-text"}})],
                    desc="Task starts and ends (pvedaemon, pveproxy, pvescheduler, ...)."), 18, 10)
    b.add(logs("Guest lifecycle", '{source="syslog", host=~"$node", app=~"qmeventd|qm|pct|lxc.*|pvescheduler"}'
               + search(), desc="qmeventd (VM start/stop/cleanup), qm/pct and scheduled jobs."), 12, 10)
    b.add(logs("pvestatd / pveproxy / pvedaemon",
               '{source="syslog", host=~"$node", app=~"pvestatd|pveproxy|pvedaemon|pvescheduler|pve-firewall"}'
               + search() + ' !~ `status update time`', desc="PVE daemons, without pvestatd's 'status update time' "
                                                              "lines."), 12, 10)
    b.add(logs("Kernel errors and warnings", '{source="syslog", host=~"$node", app="kernel"}' + search()
               + ' | level=~"emergency|alert|critical|error|warning"', desc="Kernel lines at warning or worse."), 24, 9)

    b.row("Ceph cluster log")
    ceph = CEPH + search()
    b.add(range_stat("Health checks raised", f'{ceph} |~ "Health check (failed|update)"', thresholds=ORANGE_IF_ANY,
                     desc="'Health check failed' and 'Health check update' lines from the cluster log (one mon's "
                          "copy, the Ceph mon picker), as in the panels below."),
          4, 4)
    b.add(range_stat("Health checks cleared", f'{ceph} |= "Health check cleared"', thresholds=steps(("green", None))),
          4, 4)
    b.add(range_stat("HEALTH_ERR lines", f'{ceph} |= "HEALTH_ERR"', thresholds=RED_IF_ANY), 4, 4)
    b.add(range_stat("OSD events", f"{ceph} |~ `{OSD_RE}`", thresholds=ORANGE_IF_ANY,
                     desc="OSDs marked down/out/in, failed, booting."), 4, 4)
    b.add(range_stat("Slow ops lines", f"{ceph} |~ `{SLOW_RE}`", thresholds=ORANGE_IF_ANY,
                     desc="Slow ops/requests and BlueStore slow operation warnings (BLUESTORE_SLOW_OP_ALERT is "
                          "pre-existing on osd.0)."), 4, 4)
    b.add(range_stat("Cluster log lines", ceph + ' != "[DBG]"', desc="Without [DBG] (pgmap) lines."), 4, 4)
    b.add(per_bucket("Cluster log by severity", [
        lq(f'sum by (sev) ({count(ceph + " != `[DBG]` | regexp `cluster \\[(?P<sev>[A-Z]+)\\]`")})', "{{sev}}")],
        overrides=[fixed_color(k, c) for k, c in CEPH_SEV_COLORS.items()],
        desc="[INF], [WRN], [ERR] lines of the cluster log; [DBG] (pgmap every few seconds) is left out."), 8, 9)
    b.add(history("Health checks raised", [lq(
        f'sum by (check) ({count(ceph + " |~ `Health check (failed|update)` | regexp `\\((?P<check>[A-Z0-9_]+)\\)\\s*$`")})',
        "{{check}}")], desc="Health checks raised or updated per bucket, by check code.",
        no_value="No health checks raised in range"), 8, 9)
    b.add(top("Health checks raised (range)",
              f'sum by (check) ({count(ceph + " |~ `Health check (failed|update)` | regexp `\\((?P<check>[A-Z0-9_]+)\\)\\s*$`", "$__range")})',
              "{{check}}", thresholds=steps(("orange", None)), desc="How often each health check was raised."), 8, 9)
    b.add(logs("Health changes", f"{ceph} |~ `{HEALTH_RE}`", desc="Health checks raised, updated and cleared."), 12, 10)
    b.add(logs("OSD events and slow ops", f"{ceph} |~ `{OSD_RE}|{SLOW_RE}` !~ `overall HEALTH_`",
               desc="OSD state changes and slow ops, without the periodic 'overall HEALTH_...' summary."), 12, 10)
    b.add(logs("Cluster log (without DBG)", ceph + ' != "[DBG]"', desc="The cluster log minus [DBG] (pgmap) lines."),
          12, 12)
    b.add(logs("Ceph daemons and kernel client",
               '{source="syslog", host=~"$node", app=~"ceph-(osd|mon|mgr|mds|crash|volume).*|kernel"} '
               '|~ `(?i)ceph|osd|libceph|rbd`' + search(),
               desc="Ceph daemons' journal lines and the kernel's libceph/rbd messages on the selected nodes."), 12, 12)

    node_var = loki_var("node", "Node", f'{{source="syslog", host=~"{PVE_HOSTS}"}}', "host", all_value=PVE_HOSTS)
    mon_var = loki_var("cephmon", "Ceph mon", '{app="ceph-cluster"}', "host", multi=False, include_all=False,
                       current={"selected": True, "text": "macbeth", "value": "macbeth"})
    mon_var["description"] = "Every mon sends the same cluster log: read one copy."
    return logs_dashboard("pve", "Proxmox & Ceph logs",
                          "Syslog of the PVE nodes (pvestatd, pveproxy, pvedaemon, HA, corosync, qmeventd, tasks, "
                          "kernel) and the Ceph cluster log (health changes, OSD events, slow ops).",
                          # Not tagged "proxmox": that dropdown carries the variables (node=All would land on the
                          # Proxmox node dashboard). The Proxmox node dashboard links here instead.
                          b, tags=["ceph"], variables=[node_var, mon_var, SEARCH],
                          extra_links=[url_link("Proxmox overview", "/d/proxmox-overview/proxmox-overview"),
                                       url_link("Ceph cluster", "/d/ceph-cluster/ceph-cluster")])


# --- Services logs ---------------------------------------------------------------------

# No source label: dns01/02 sent BIND as syslog (rsyslog) until 2026-11 and as journal (Alloy) since,
# with the same host/app labels, so one selector covers both.
DNS = '{host=~"dns0[0-9]", app="bind9"}'
# Kea runs in two unrelated places: the cluster HA pair dhcp01/02 (kea-dhcp4) and fw-wan, which
# serves the guest VRF on eth3.4 alone (kea-vrf-helper, no HA). Each gets its own panels.
KEA_HA = '{source="syslog", host=~"dhcp0[12]", app=~"kea-dhcp4|kea-vrf-helper"}'
KEA_FW = '{source="syslog", host="fw-wan", app=~"kea-dhcp4|kea-vrf-helper"}'
KEA_HA_TITLE = "DHCP: cluster HA pair (dhcp01/02)"
KEA_FW_TITLE = "DHCP: fw-wan (guest)"
VRRP = '{app="Keepalived_vrrp"}'
BIND_EVENTS = [
    ("zone transfers", "Transfer completed"),
    ("notifies", "notify from|sending notifies"),
    ("DNSSEC validation", "no valid signature|broken trust chain|insecurity proof failed|verify failed|no valid RRSIG"),
    # "deadlock found resolving '<name>/DS/IN': <ip>#53" is a resolver failure too.
    ("resolution errors", "(?i:servfail|timed out|unreachable|lame server|formerr|connection refused|unexpected RCODE|"
                          "deadlock found)"),
]
# No query count: query logging (querylog / a "queries" logging category) is off on purpose, so
# BIND never logs " query: " lines.
KEA_EVENTS = [
    ("leases allocated", "DHCP4_LEASE_ALLOC", BLUE),
    ("NAKs", "DHCP4_PACKET_NAK|DHCPNAK", ORANGE_IF_ANY),
    ("allocation failures", "ALLOC_FAIL|DHCP4_.*_FAIL|no address available", RED_IF_ANY),
    ("HA state changes", "HA_STATE_TRANSITION", ORANGE_IF_ANY),
    ("HA comms problems", "HA_COMMUNICATION_INTERRUPTED|HA_HEARTBEAT_FAILED|HA_.*_FAILED|partner .* unavailable",
     RED_IF_ANY),
]
VRRP_MAP = mapping(MASTER=("MASTER", "green"), BACKUP=("BACKUP", "blue"), FAULT=("FAULT", "red"))


def services():
    b = Board()
    b.row("DNS (BIND)")
    for name, regex in BIND_EVENTS:
        thresholds = ORANGE_IF_ANY if name in ("DNSSEC validation", "resolution errors") else BLUE
        b.add(range_stat(name[0].upper() + name[1:], f"{DNS} |~ `{regex}`", thresholds=thresholds,
                         desc=f"BIND lines matching `{regex}` (dns01 + dns02). BIND logs everything at the same "
                              "level (stderr), so the line decides."),
              5, 4)
    b.add(on_loki(stat("Lines", [lq(total(DNS), "lines", instant=True)], decimals=0, color_mode="value",
                       thresholds=BLUE, desc="All BIND lines. Query logging is off on purpose, so queries are "
                                             "not counted anywhere here.")), 4, 4)
    b.add(per_bucket("BIND messages by kind", [lq(f"sum({count(DNS + f' |~ `{regex}`')})", name)
                                               for name, regex in BIND_EVENTS]
                     + [lq(f"sum({count(DNS + ' !~ `' + '|'.join(r for _, r in BIND_EVENTS) + '`')})", "other")],
                     desc="Most validation failures are upstream domains with broken DNSSEC, not our zones. "
                          "No query series: query logging is off on purpose."), 8, 9)
    b.add(log_table("Zone transfers", DNS + ' |= "Transfer completed" | regexp `transfer of \'(?P<zone>[^\']+)\' '
                                            'from (?P<primary>\\S+): Transfer completed: (?P<msgs>\\d+) messages, '
                                            '(?P<records>\\d+) records.*serial (?P<serial>\\d+)`',
                    ["host", "zone", "primary", "records", "serial"],
                    rename={"host": "Server", "zone": "Zone", "primary": "From", "records": "Records", "serial": "Serial"},
                    widths={"host": 80, "zone": 140, "primary": 130, "records": 80, "serial": 80},
                    desc="Completed inbound zone transfers (secondaries)."), 16, 9)
    b.add(logs("BIND (without DNSSEC validation noise)", f"{DNS}{search()} !~ `no valid signature`",
               desc="dns01 and dns02, minus 'no valid signature' validation lines."), 24, 10)

    b.row("DHCP (Kea)")
    # Cluster pair on the left half, fw-wan on the right; fw-wan has no HA, so no HA panels there.
    no_hb = " != `'ha-heartbeat'`"
    kea_code = r" | regexp `^\s*(?P<sev>[A-Z]+)\s+(?P<code>[A-Z0-9_]+)`"
    lease_re = (' |= "DHCP4_LEASE_ALLOC" | regexp `\\[hwtype=\\d+ (?P<mac>[0-9a-f:]+)\\]'
                '.*lease (?P<address>\\S+) has been allocated for (?P<seconds>\\d+) seconds`')
    lease_names = {"host": "Server", "address": "Address", "mac": "MAC", "seconds": "Lease (s)"}
    lease_widths = {"host": 80, "address": 110, "mac": 140, "seconds": 80}

    def kea_stats(sel, who, events, prefix):
        return [range_stat(f"{prefix}: {name}", f"{sel} |~ `{regex}`", thresholds=thresholds,
                           desc=f"Kea lines matching `{regex}` ({who}).") for name, regex, thresholds in events] \
            + [range_stat(f"{prefix}: lines", sel + no_hb, desc=f"All Kea lines ({who}), HA heartbeats left out.")]

    b.grid(12, 4, kea_stats(KEA_HA, "dhcp01 + dhcp02", KEA_EVENTS, "dhcp01/02"), 3)
    b.grid(12, 4, kea_stats(KEA_FW, "fw-wan's guest DHCP", [e for e in KEA_EVENTS if not e[1].startswith("HA_")],
                            "fw-wan"), 2)
    for sel, title, who in ((KEA_HA, KEA_HA_TITLE, "dhcp01 + dhcp02"), (KEA_FW, KEA_FW_TITLE, "fw-wan")):
        b.add(per_bucket(f"Kea messages by code (top 10): {title.removeprefix('DHCP: ')}",
                         [lq(f"topk(10, sum by (code) ({count(sel + no_hb + kea_code)}))", "{{code}}")],
                         desc=f"Kea's message IDs on {who} (DHCP4_LEASE_ALLOC, HA_STATE_TRANSITION, ...), "
                              "heartbeats left out."), 12, 10)
    b.add(log_table(f"Leases allocated: {KEA_HA_TITLE.removeprefix('DHCP: ')}", KEA_HA + lease_re,
                    ["host", "address", "mac", "seconds"], rename=lease_names, widths=lease_widths), 12, 10)
    b.add(log_table(f"Leases allocated: {KEA_FW_TITLE.removeprefix('DHCP: ')}", KEA_FW + lease_re,
                    ["address", "mac", "seconds"], rename=lease_names, widths=lease_widths), 12, 10)
    b.col(12,
          (log_table("HA state transitions (dhcp01/02)",
                     KEA_HA + ' |= "HA_STATE_TRANSITION" | regexp `HA_STATE_TRANSITION (?P<server>\\S+): server '
                              'transitions from (?P<from>\\S+) to (?P<to>\\S+) state, partner state is (?P<partner>\\S+)`',
                     ["server", "from", "to", "partner"],
                     rename={"server": "Server", "from": "From", "to": "To", "partner": "Partner state"},
                     widths={"server": 80, "from": 120, "to": 120}), 8),
          (logs(KEA_HA_TITLE, KEA_HA + search() + no_hb + " !~ `HA_HEARTBEAT|COMMAND_RECEIVED`",
                desc="Kea on dhcp01 and dhcp02, minus the HA heartbeat commands."), 12))
    b.add(logs(KEA_FW_TITLE, KEA_FW + search(),
               desc="Kea on fw-wan (the guest VRF's DHCP on eth3.4, kea-vrf-helper; no HA)."), 12, 20)

    b.row("keepalived (VIP moves)")
    states = VRRP + ' |~ `Entering (MASTER|BACKUP|FAULT) STATE` | regexp `\\((?P<instance>[^)]+)\\) Entering (?P<state>[A-Z]+) STATE`'
    b.add(top("Became MASTER (range)", f'sum by (instance, host) ({count(states + " | state=`MASTER`", "$__range")})',
              "{{instance}} → {{host}}", n=20,
              desc="How often each VM took each VRRP instance's VIPs: dns (DNS VIP), grafana (10.2.11.100), "
                   "logging (Loki/syslog VIP .101), monitoring (.102), mimir (.103), postgres (.104)."), 6, 12)
    b.add(history("VRRP transitions", [lq(f"sum by (instance, host, state) ({count(states)})",
                                          "{{instance}} {{host}} {{state}}")],
                  thresholds=steps(("blue", None)), desc="Every state change per instance, VM and new state."), 9, 12)
    b.add(log_table("VRRP state changes", states, ["instance", "host", "state"],
                    rename={"instance": "Instance", "host": "VM", "state": "State"},
                    widths={"instance": 90, "host": 80, "state": 90},
                    overrides=[override("State", {"mappings": VRRP_MAP, "custom.cellOptions": {"type": "color-text"}})],
                    desc="keepalived's VRRP state changes on dns01/02, graf01/02, loki01-03, mon01/02, mim01-03 "
                         "and pg01-03."), 9, 12)

    b.row("Monitoring and logging stack")
    mon = '{source="journal", container=~"$container"}' + search() + " " + LEVEL
    b.add(per_bucket("Errors and warnings by container", [
        lq(f'sum by (host, container, level) ({count(mon + " | level=~`error|warning`")})',
           "{{host}} {{container}} {{level}}")],
        desc="The line's own level (Podman logs stderr as 'err' whatever the line says)."), 12, 9)
    b.add(top("Errors by container (range)", f'sum by (host, container) ({count(mon + " | level=`error`", "$__range")})',
              "{{host}} {{container}}", n=15, thresholds=steps(("orange", None))), 12, 9)
    b.add(logs("Errors and warnings", mon + ' | level=~"error|warning"',
               desc="Warnings and errors of the selected containers."), 24, 10)
    b.add(logs("haproxy (S3 to the RGWs)", '{source="journal", container="haproxy"}' + search(),
               desc="Backend state changes ('Server rgw/rgw1 is DOWN') on loki01-03, mim01-03 and pg01-03."), 8, 9)
    b.add(logs("Loki and Alloy (warnings, errors)",
               '{source="journal", container=~"loki|alloy"}' + search() + " " + LEVEL + ' | level=~"error|warning"',
               desc="Loki and Alloy on all VMs, warning or worse."), 8, 9)
    b.add(logs("Prometheus and Alertmanager", '{source="journal", container=~"prometheus|alertmanager"}' + search(),
               desc="Config reloads, compactions, rule and notification errors."), 8, 9)
    b.add(logs("Grafana (warnings, errors)",
               '{source="journal", container="grafana"}' + search() + " " + LEVEL + ' | level=~"error|warning"',
               desc="graf01 and graf02."), 24, 9)

    container_var = loki_var("container", "Container", '{source="journal"}', "container",
                             all_value=MON_CONTAINERS, regex=f"/^({MON_CONTAINERS})$/")
    return logs_dashboard("services", "Services logs",
                          "BIND (transfers, validation and resolution errors), Kea DHCP (leases, HA state), keepalived "
                          "VIP moves, and the monitoring stack's containers (Grafana, Prometheus, Mimir, Loki, Alloy, "
                          "haproxy, Telegraf, Postgres).",
                          b, variables=[container_var, SEARCH],
                          extra_links=[url_link("Monitoring stack", STACK_DASH)])


DASHBOARDS = {
    "Logs/logs-overview.json": overview,
    "Logs/network-device-logs.json": network,
    "Logs/fw-wan-logs.json": fw_wan,
    "Logs/proxmox-ceph-logs.json": proxmox,
    "Logs/services-logs.json": services,
}
