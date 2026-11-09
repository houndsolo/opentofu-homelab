"""Proxmox dashboards, built from the PVE external metric server data in InfluxDB.

Run custom.py, not this file: it imports these builders and writes the JSON with
the others. Every dashboard here:

- queries the provisioned InfluxDB datasource (uid "influxdb", Flux) and picks the
  bucket with a "Cluster" variable: pve_cluster (the 7-node cluster lylat) or
  pve_greatfox (the standalone greatfox);
- carries the "lylat" and "proxmox" tags, the Dashboards dropdown and a
  "Proxmox dashboards" dropdown that keeps the selected bucket, node and guest.

What pvestatd writes (every ~10 s; PVE 9 field names):

  measurement  object            tags                          fields
  system       nodes             host                          uptime
  cpustat      nodes             host                          cpu, wait (fractions), avg1/5/15, cpus
  memory       nodes             host                          memtotal/used/free/available, swap*, arc*
  blockstat    nodes             host                          root filesystem: per (% used), used, blocks, ...
  nics         nodes             host, instance (NIC)          receive, transmit (byte counters), type
  system       qemu, lxc         host (= guest name), vmid,    status, cpu (fraction of its vCPUs), cpus,
                                 nodename                      mem, memhost (qemu), maxmem, disk (lxc),
                                                               maxdisk, diskread/write, netin/out
                                                               (byte counters), uptime, pressure*, tags,
                                                               template (only on templates)
  blockstat    qemu              vmid, instance (disk)         rd/wr bytes, operations, total_time_ns, ...
  nics         qemu              vmid, instance (tap NIC)      netin, netout
  ballooninfo  qemu              vmid                          actual, max_mem, free_mem, total_mem, ...
  system       storages          host (= storage), nodename    total, used, avail, shared, active, type, content

String fields (status, tags, type, content) can't be pivoted together with numbers,
so the tables query them separately and Grafana joins the results.
"""
import textwrap

from custom import (BLUE, CEPH_DASH, FILL, NODE_DASH, READ, RED_IF_ANY, UP_MAP, UP_STEPS, WRITE, Board, bargauge,
                    cell, dashboard, fixed_color, gauge, hidden, mapping, organize, override, q, stat, steps, table,
                    timeseries)

INFLUX = {"type": "influxdb", "uid": "influxdb"}
OVERVIEW_DASH = "/d/proxmox-overview/proxmox-overview"
PVE_NODE_DASH = "/d/proxmox-node/proxmox-node"
GUEST_DASH = "/d/proxmox-guest/proxmox-guest"
STORAGE_DASH = "/d/proxmox-storage/proxmox-storage"
BUCKETS = (("lylat cluster", "pve_cluster"), ("greatfox", "pve_greatfox"))

# Every dashboard tagged "proxmox" (these and the community one from update.py) gets a
# "Proxmox dashboards" dropdown; it carries the variables, so bucket/node/guest stick.
PVE_LINK = {"type": "dashboards", "tags": ["proxmox"], "asDropdown": True, "title": "Proxmox dashboards",
            "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
            "tooltip": "", "url": ""}

CPU, MEM, SWAP, WAIT = "blue", "purple", "orange", "orange"
NET_IN, NET_OUT = "green", "yellow"
FRACTION = steps(("green", None), ("orange", 0.75), ("red", 0.9))
LOAD = steps(("green", None), ("orange", 0.8), ("red", 1.5))
STATUS_MAP = mapping(running=("running", "green"), stopped=("stopped", "text"), paused=("paused", "orange"),
                     prelaunch=("prelaunch", "blue"), suspended=("suspended", "orange"))
TYPE_MAP = mapping(qemu=("VM", "blue"), lxc=("CT", "purple"))
SHARED_MAP = mapping(**{"0": ("local", "text"), "1": ("shared", "blue")})
TIME_URL = "${__url_time_range}"


# --- Flux --------------------------------------------------------------------------
#
# Queries are written as plain Flux with %(name)s placeholders (Flux itself uses braces).
# Grafana replaces v.timeRangeStart/Stop and v.windowPeriod and the ${...} variables.

FRAGMENTS = {
    "src": 'from(bucket: "${bucket}")',
    "range": "range(start: v.timeRangeStart, stop: v.timeRangeStop)",
    # The newest sample at the end of the time range (pvestatd pushes every ~10 s), like a
    # Prometheus instant query: deleted or migrated guests don't linger.
    "now": "range(start: date.sub(d: 2m, from: v.timeRangeStop), stop: v.timeRangeStop)",
    # Enough samples for a rate at the end of the time range.
    "now_rate": "range(start: date.sub(d: 3m, from: v.timeRangeStop), stop: v.timeRangeStop)",
    "mean": "aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)",
    # Counter -> per-second rate: the last value per window, then the slope between windows.
    "rate": "aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)\n"
            "  |> derivative(unit: 1s, nonNegative: true)",
    "guests": '(r.object == "qemu" or r.object == "lxc")',
    "on_node": 'r.nodename =~ /^${node:regex}$/',   # guests and storages
    "guest": 'r.vmid == "${guest}"',
    "storage": 'r.host =~ /^${storage:regex}$/',
    "phys": 'r.instance =~ /^(eth|en|wl)/',          # physical NICs (pvestatd type "physical")
}


def flux(text, **kw):
    """Fills the %(name)s placeholders and adds the imports the query uses."""
    text = textwrap.dedent(text).strip() % {**FRAGMENTS, **kw}
    imports = [f'import "{m}"' for m in ("date", "strings") if f"{m}." in text]
    return "\n".join(imports + [text])


def fx(text, **kw):
    return {"datasource": INFLUX, "query": flux(text, **kw)}


def fields(*names):
    return "(" + " or ".join(f'r._field == "{n}"' for n in names) + ")"


def series(expr):
    """Names each series by a Flux string expression (Grafana shows the one label as the legend)."""
    return (f"map(fn: (r) => ({{r with series: {expr}}}))\n"
            '  |> group(columns: ["series"])\n'
            '  |> sort(columns: ["_time"])\n'
            '  |> keep(columns: ["_time", "_value", "series"])')


def bars(title, targets, **kw):
    """A bar per row of one table (sorted in Flux); the row's string column names the bar."""
    p = bargauge(title, targets, **kw)
    p["options"]["reduceOptions"] = {"values": True, "calcs": ["lastNotNull"], "fields": "", "limit": 50}
    return p


def text_stat(title, targets, **kw):
    """A stat that shows string fields (status, tags, versions)."""
    kw.setdefault("color_mode", "value")
    p = stat(title, targets, **kw)
    p["options"]["reduceOptions"] = {"values": False, "calcs": ["lastNotNull"], "fields": "/.*/"}
    return p


def field_links(p, *links):
    """Data links on the values (they can use ${__field.labels.x} / ${__data.fields.x})."""
    p["fieldConfig"]["defaults"]["links"] = [{"title": t, "url": u, "targetBlank": False} for t, u in links]
    return p


def joined(by):
    return {"id": "joinByField", "options": {"byField": by, "mode": "outer"}}


def gauge_cell(*names, unit="percentunit", thresholds=FRACTION):
    return [override(n, {"unit": unit, "min": 0, "max": 1 if unit == "percentunit" else 100, "decimals": 1,
                         "thresholds": thresholds,
                         "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}})
            for n in names]


def net_overrides(rx="in", tx="out"):
    """Inbound above the axis, outbound mirrored below it."""
    return [override(f"(?i).*\\b{rx}$", {"color": {"mode": "fixed", "fixedColor": NET_IN}}, regex=True),
            override(f"(?i).*\\b{tx}$", {"color": {"mode": "fixed", "fixedColor": NET_OUT},
                                          "custom.transform": "negative-Y"}, regex=True)]


def rw_overrides():
    return [override("(?i).*\\bread$", {"color": {"mode": "fixed", "fixedColor": READ}}, regex=True),
            override("(?i).*\\bwrite$", {"color": {"mode": "fixed", "fixedColor": WRITE},
                                          "custom.transform": "negative-Y"}, regex=True)]


def node_link(field="host"):
    return {"title": "Proxmox node",
            "url": PVE_NODE_DASH + "?var-bucket=${bucket}&var-node=${__data.fields." + field + "}&" + TIME_URL}


def guest_link():
    return {"title": "Proxmox guest",
            "url": GUEST_DASH + "?var-bucket=${bucket}&var-guest=${__data.fields.vmid}&" + TIME_URL}


# --- Variables -----------------------------------------------------------------------

def bucket_var():
    options = [{"text": t, "value": v, "selected": i == 0} for i, (t, v) in enumerate(BUCKETS)]
    return {"name": "bucket", "label": "Cluster", "type": "custom", "hide": 0,
            "query": ",".join(f"{t} : {v}" for t, v in BUCKETS),
            "description": "InfluxDB bucket: pve_cluster (the lylat cluster) or pve_greatfox (the standalone greatfox).",
            "multi": False, "includeAll": False, "options": options,
            "current": {"text": BUCKETS[0][0], "value": BUCKETS[0][1], "selected": True}}


def flux_var(name, label, query, *, multi=False, include_all=False, regex=""):
    v = {"name": name, "label": label, "type": "query", "datasource": INFLUX, "query": query,
         "definition": query, "refresh": 2, "multi": multi, "includeAll": include_all, "options": [],
         "sort": 1, "regex": regex, "hide": 0}
    v["current"] = {"selected": True, "text": ["All"], "value": ["$__all"]} if include_all else {}
    return v


def node_var(multi=False):
    return flux_var("node", "Node", flux('''
        import "influxdata/influxdb/schema"
        schema.tagValues(bucket: "${bucket}", tag: "host",
          predicate: (r) => r._measurement == "cpustat", start: v.timeRangeStart, stop: v.timeRangeStop)'''),
                    multi=multi, include_all=multi)


def guest_var():
    # "5301|dns01 (5301)": the regex shows the name and keeps the vmid as the value
    # (names aren't unique: greatfox has two arch-6800xt-nvme).
    return flux_var("guest", "Guest", flux('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and r._field == "uptime" and %(on_node)s)
          |> last()
          |> group()
          |> map(fn: (r) => ({_value: r.vmid + "|" + r.host + " (" + r.vmid + ")"}))
          |> distinct()'''), regex="/^(?<value>[^|]+)\\|(?<text>.*)$/")


def storage_var():
    return flux_var("storage", "Storage", flux('''
        import "influxdata/influxdb/schema"
        schema.tagValues(bucket: "${bucket}", tag: "host",
          predicate: (r) => r._measurement == "system" and r.object == "storages",
          start: v.timeRangeStart, stop: v.timeRangeStop)'''), multi=True, include_all=True)


# --- Shared queries ------------------------------------------------------------------

def node_table_query(src=FRAGMENTS["src"], sel="true"):
    """One row per node: last values in the time range; up = reported in the last minute of it."""
    return fx('''
        data = %(src)s
          |> %(range)s
          |> filter(fn: (r) => r.object == "nodes" and %(sel)s and (
               (r._measurement == "cpustat" and (r._field == "cpu" or r._field == "cpus" or r._field == "wait" or r._field == "avg5")) or
               (r._measurement == "memory" and (r._field == "memused" or r._field == "memtotal" or r._field == "swapused" or r._field == "swaptotal")) or
               (r._measurement == "blockstat" and r._field == "per") or
               (r._measurement == "system" and r._field == "uptime")))
          |> last()
          |> map(fn: (r) => ({host: r.host, _field: r._field, _value: float(v: r._value), _time: r._time}))
        age = data
          |> filter(fn: (r) => r._field == "uptime")
          |> map(fn: (r) => ({host: r.host, _field: "age", _value: float(v: int(v: v.timeRangeStop) - int(v: r._time)) / 1000000000.0, _time: r._time}))
        union(tables: [data, age])
          |> group()
          |> pivot(rowKey: ["host"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({host: r.host, up: if r.age < 60.0 then 1 else 0, uptime: r.uptime, cpu: r.cpu,
               cores: r.cpus, load: r.avg5 / r.cpus, iowait: r.wait, mem: r.memused / r.memtotal, memtotal: r.memtotal,
               swap: if r.swaptotal > 0.0 then r.swapused / r.swaptotal else 0.0, rootfs: r.per / 100.0}))''',
              src=src, sel=sel)


def guests_per_node_query():
    return fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and r._field == "status")
          |> last()
          |> group(columns: ["nodename"])
          |> reduce(identity: {running: 0, guests: 0}, fn: (r, accumulator) => ({
               running: accumulator.running + (if r._value == "running" then 1 else 0), guests: accumulator.guests + 1}))
          |> group()
          |> rename(columns: {nodename: "host"})''')


def node_net_query():
    """Current rx/tx per node over the physical NICs, in bits/s."""
    return fx('''
        %(src)s
          |> %(now_rate)s
          |> filter(fn: (r) => r._measurement == "nics" and r.object == "nodes" and %(phys)s and %(fields)s)
          |> derivative(unit: 1s, nonNegative: true)
          |> last()
          |> group(columns: ["host", "_field"])
          |> sum()
          |> map(fn: (r) => ({r with _value: r._value * 8.0}))
          |> group()
          |> pivot(rowKey: ["host"], columnKey: ["_field"], valueColumn: "_value")''', fields=fields("receive", "transmit"))


def guest_counts_query(src=FRAGMENTS["src"], sel="true"):
    """Running VMs and CTs, stopped guests (templates left out) and templates."""
    return fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(sel)s and (r._field == "status" or r._field == "template"))
          |> last()
          |> map(fn: (r) => ({vmid: r.vmid, nodename: r.nodename, object: r.object, _field: r._field, _value: string(v: r._value)}))
          |> group()
          |> pivot(rowKey: ["vmid", "nodename", "object"], columnKey: ["_field"], valueColumn: "_value")
          |> reduce(identity: {vms: 0, cts: 0, stopped: 0, templates: 0}, fn: (r, accumulator) => ({
               vms: accumulator.vms + (if r.status == "running" and r.object == "qemu" then 1 else 0),
               cts: accumulator.cts + (if r.status == "running" and r.object == "lxc" then 1 else 0),
               stopped: accumulator.stopped + (if r.status != "running" and not exists r.template then 1 else 0),
               templates: accumulator.templates + (if exists r.template then 1 else 0)}))''', src=src, sel=sel)


GUEST_COUNT_OVERRIDES = [
    override("vms", {"displayName": "VMs running", "color": {"mode": "fixed", "fixedColor": "green"}}),
    override("cts", {"displayName": "CTs running", "color": {"mode": "fixed", "fixedColor": "green"}}),
    override("stopped", {"displayName": "Stopped", "color": {"mode": "fixed", "fixedColor": "text"}}),
    override("templates", {"displayName": "Templates", "color": {"mode": "fixed", "fixedColor": "blue"}}),
]


def nodes_up_query(src=FRAGMENTS["src"]):
    return fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and r._field == "avg1")
          |> last()
          |> group()
          |> map(fn: (r) => ({r with fresh: int(v: v.timeRangeStop) - int(v: r._time) < 60000000000}))
          |> reduce(identity: {up: 0, down: 0}, fn: (r, accumulator) => ({
               up: accumulator.up + (if r.fresh then 1 else 0), down: accumulator.down + (if r.fresh then 0 else 1)}))''',
              src=src)


NODES_UP_OVERRIDES = [override("up", {"displayName": "Up", "color": {"mode": "fixed", "fixedColor": "green"}}),
                      override("down", {"displayName": "Down", "thresholds": RED_IF_ANY})]


def weighted_cpu_query(src=FRAGMENTS["src"], sel="true"):
    """CPU over all selected nodes, weighted by their cores."""
    return fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and %(sel)s and (r._field == "cpu" or r._field == "cpus"))
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> group(columns: ["_time"])
          |> reduce(identity: {used: 0.0, cpus: 0.0}, fn: (r, accumulator) => ({used: accumulator.used + r.cpu * r.cpus, cpus: accumulator.cpus + r.cpus}))
          |> group()
          |> sort(columns: ["_time"])
          |> map(fn: (r) => ({_time: r._time, _value: r.used / r.cpus}))''', src=src, sel=sel)


def weighted_mem_query(src=FRAGMENTS["src"], sel="true"):
    return fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "memory" and r.object == "nodes" and %(sel)s and (r._field == "memused" or r._field == "memtotal"))
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> group(columns: ["_time"])
          |> reduce(identity: {used: 0.0, total: 0.0}, fn: (r, accumulator) => ({used: accumulator.used + r.memused, total: accumulator.total + r.memtotal}))
          |> group()
          |> sort(columns: ["_time"])
          |> map(fn: (r) => ({_time: r._time, _value: r.used / r.total}))''', src=src, sel=sel)


def storage_now_query(sel="true", keep=None, tail=""):
    """Current storages, shared ones once ("ceph_rbd"), local ones per node ("local (zoness)")."""
    return fx('''
        nums = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and
               (r._field == "total" or r._field == "used" or r._field == "avail" or r._field == "shared" or r._field == "active" or r._field == "enabled"))
          |> last()
          |> group()
          |> pivot(rowKey: ["host", "nodename"], columnKey: ["_field"], valueColumn: "_value")
        strs = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and (r._field == "type" or r._field == "content"))
          |> last()
          |> group()
          |> pivot(rowKey: ["host", "nodename"], columnKey: ["_field"], valueColumn: "_value")
        join(tables: {n: nums, s: strs}, on: ["host", "nodename"])
          |> map(fn: (r) => ({r with storage: if r.shared == 1.0 then r.host else r.host + " (" + r.nodename + ")",
               pct: if r.total > 0.0 then r.used / r.total else 0.0}))
          |> group(columns: ["storage"])
          |> first(column: "storage")
          |> group()
          |> sort(columns: ["pct"], desc: true)%(keep)s''', sel=sel,
              keep=(f"\n  |> keep(columns: {keep})".replace("'", '"') if keep else "") + textwrap.dedent(tail).rstrip())


def storage_series_query(field_expr, sel="true", window_fn="last"):
    """Storage series over time, shared storages once (they report the same from every node)."""
    return fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and
               (r._field == "used" or r._field == "total" or r._field == "shared"))
          |> aggregateWindow(every: v.windowPeriod, fn: %(fn)s, createEmpty: false)
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({_time: r._time, _value: %(value)s,
               series: if r.shared == 1.0 then r.host else r.host + " (" + r.nodename + ")"}))
          |> group(columns: ["series"])
          |> unique(column: "_time")
          |> sort(columns: ["_time"])''', sel=sel, value=field_expr, fn=window_fn)


def storage_bars(sel="true", title="Storage used"):
    p = bars(title, [storage_now_query(sel, keep=["storage", "pct"])], unit="percentunit", min_=0, max_=1, thresholds=FILL,
             bar_height=20, mode="gradient", desc="Used / total. Shared storages once, local ones per node.",
             links=[("Proxmox storage", STORAGE_DASH + "?var-bucket=${bucket}&" + TIME_URL)])
    p["options"]["reduceOptions"]["fields"] = "/^pct$/"
    return p


# --- Proxmox overview -------------------------------------------------------------------

def overview():
    b = Board()
    b.row("Cluster")
    b.add(stat("Nodes", [nodes_up_query()], text_mode="value_and_name", color_mode="value",
               overrides=NODES_UP_OVERRIDES,
               desc="Nodes that reported to InfluxDB within the last minute of the time range (Up) and nodes "
                    "seen earlier in the range that stopped reporting (Down)."), 4, 5)
    b.add(stat("Guests", [guest_counts_query()], text_mode="value_and_name", color_mode="value",
               overrides=GUEST_COUNT_OVERRIDES,
               desc="Running VMs and containers, stopped guests (templates not counted) and templates.",
               links=[("Proxmox guests", GUEST_DASH + "?var-bucket=${bucket}&" + TIME_URL)]), 7, 5)
    b.add(stat("CPU", [weighted_cpu_query()], unit="percentunit", decimals=1, color_mode="value", graph=True,
               thresholds=FRACTION, desc="Busy share of all node cores (pvestatd's cpu, weighted by cores)."), 3, 5)
    b.add(stat("Memory", [weighted_mem_query()], unit="percentunit", decimals=1, color_mode="value", graph=True,
               thresholds=FRACTION, desc="Used / total memory over all nodes (used = total - available)."), 3, 5)
    b.add(stat("Allocated to running guests", [fx('''
        guests = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and (r._field == "cpus" or r._field == "maxmem" or r._field == "uptime"))
          |> last()
          |> group()
          |> pivot(rowKey: ["vmid", "nodename"], columnKey: ["_field"], valueColumn: "_value")
          |> filter(fn: (r) => r.uptime > 0.0)
          |> reduce(identity: {vcpus: 0.0, vmem: 0.0}, fn: (r, accumulator) => ({vcpus: accumulator.vcpus + r.cpus, vmem: accumulator.vmem + r.maxmem}))
          |> map(fn: (r) => ({r with k: 1}))
        nodes = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r.object == "nodes" and ((r._measurement == "cpustat" and r._field == "cpus") or (r._measurement == "memory" and r._field == "memtotal")))
          |> last()
          |> group()
          |> pivot(rowKey: ["host"], columnKey: ["_field"], valueColumn: "_value")
          |> reduce(identity: {cores: 0.0, mem: 0.0}, fn: (r, accumulator) => ({cores: accumulator.cores + r.cpus, mem: accumulator.mem + r.memtotal}))
          |> map(fn: (r) => ({r with k: 1}))
        join(tables: {g: guests, n: nodes}, on: ["k"])
          |> map(fn: (r) => ({vCPUs: r.vcpus / r.cores, memory: r.vmem / r.mem}))''')],
        text_mode="value_and_name", color_mode="value", decimals=2,
        overrides=[override("vCPUs", {"unit": "x", "displayName": "vCPUs / cores",
                                      "thresholds": steps(("green", None), ("orange", 2), ("red", 4))}),
                   override("memory", {"unit": "percentunit", "decimals": 0, "displayName": "Memory / RAM",
                                       "thresholds": steps(("green", None), ("orange", 0.8), ("red", 1))})],
        desc="vCPUs and configured memory of the running guests, against the nodes' cores and RAM. "
             "Above 1x vCPUs is normal overcommit; memory near 100% leaves no room for an HA failover."), 7, 5)

    b.row("Nodes")
    b.add(table("Nodes", [node_table_query(), guests_per_node_query(), node_net_query()],
                desc="Last values in the time range. State is DOWN when the node stopped reporting. "
                     "Network is the current rate summed over the physical NICs. Click a node for its dashboard.",
                transformations=[joined("host"), organize(rename={
                    "host": "Node", "up": "State", "uptime": "Uptime", "cpu": "CPU", "cores": "Cores",
                    "load": "Load 5m / core", "iowait": "IO wait", "mem": "Memory", "memtotal": "RAM",
                    "swap": "Swap", "rootfs": "Root FS", "running": "Guests running", "guests": "Guests",
                    "receive": "Net in", "transmit": "Net out"},
                    order=["Node", "State", "Uptime", "CPU", "Cores", "Load 5m / core", "IO wait", "Memory", "RAM",
                           "Swap", "Root FS", "Guests running", "Guests", "Net in", "Net out"])],
                overrides=[cell("State", "color-background"), override("State", {"mappings": UP_MAP, "thresholds": UP_STEPS}),
                           override("Uptime", {"unit": "dtdurations"}),
                           *gauge_cell("CPU", "Memory", "Swap", "Root FS"),
                           override("Load 5m / core", {"decimals": 2, "thresholds": LOAD,
                                                       "custom.cellOptions": {"type": "color-text"}}),
                           override("IO wait", {"unit": "percentunit", "decimals": 2,
                                                "thresholds": steps(("green", None), ("orange", 0.05), ("red", 0.2)),
                                                "custom.cellOptions": {"type": "color-text"}}),
                           override("RAM", {"unit": "bytes", "decimals": 0}),
                           override("Net in", {"unit": "bps"}), override("Net out", {"unit": "bps"}),
                           override("Node", {"links": [node_link()]})],
                sort="Node"), 24, 9)

    b.row("Node trends")
    b.add(timeseries("CPU per node", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and r._field == "cpu")
          |> %(mean)s
          |> ''' + series("r.host"))], unit="percentunit", fill=0, min_=0,
        calcs=("mean", "max", "lastNotNull")), 8, 8)
    b.add(timeseries("Memory per node", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "memory" and r.object == "nodes" and (r._field == "memused" or r._field == "memtotal"))
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({r with _value: r.memused / r.memtotal}))
          |> ''' + series("r.host"))], unit="percentunit", fill=0, min_=0, max_=1,
        calcs=("mean", "max", "lastNotNull"), desc="Used = total - available."), 8, 8)
    b.add(timeseries("Load (5m) per core", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and (r._field == "avg5" or r._field == "cpus"))
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({r with _value: r.avg5 / r.cpus}))
          |> ''' + series("r.host"))], fill=0, min_=0, decimals=2, calcs=("mean", "max", "lastNotNull"),
        desc="5-minute load average divided by the node's cores; above 1 means runnable tasks are waiting."), 8, 8)
    b.add(timeseries("Network per node (physical NICs)", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "nics" and r.object == "nodes" and %(phys)s and (r._field == "receive" or r._field == "transmit"))
          |> %(rate)s
          |> group(columns: ["host", "_field"])
          |> aggregateWindow(every: v.windowPeriod, fn: sum, createEmpty: false)
          |> map(fn: (r) => ({r with _value: r._value * 8.0}))
          |> ''' + series('r.host + (if r._field == "receive" then " in" else " out")'))],
        unit="bps", fill=10, overrides=net_overrides(), calcs=("mean", "max"),
        desc="Summed over each node's physical NICs (bond members and uplinks); inbound up, outbound down."), 12, 9)
    b.add(timeseries("IO wait per node", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and r._field == "wait")
          |> %(mean)s
          |> ''' + series("r.host"))], unit="percentunit", fill=0, min_=0, calcs=("mean", "max", "lastNotNull"),
        desc="Share of CPU time spent waiting for I/O."), 12, 9)

    b.row("Guests")
    guest_links = [("Proxmox guests", GUEST_DASH + "?var-bucket=${bucket}&" + TIME_URL)]

    def top(title, value, unit, desc, flds, rate=False, **kw):
        if rate:
            q_ = '''
            %(src)s
              |> %(now_rate)s
              |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(flds)s)
              |> derivative(unit: 1s, nonNegative: true)
              |> last()'''
        else:
            q_ = '''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(flds)s)
              |> last()'''
        q_ += '''
              |> group()
              |> pivot(rowKey: ["vmid", "host"], columnKey: ["_field"], valueColumn: "_value")
              |> map(fn: (r) => ({guest: r.host, _value: %(value)s}))
              |> filter(fn: (r) => r._value > 0.0)
              |> top(n: 10)'''
        p = bars(title, [fx(q_, flds=flds, value=value)], unit=unit, desc=desc, links=guest_links,
                 bar_height=18, **kw)
        return p

    b.add(top("Top guests by CPU", "r.cpu", "percentunit", "Share of each guest's own vCPUs in use.",
              fields("cpu"), min_=0, max_=1, thresholds=FRACTION), 6, 9)
    b.add(top("Top guests by memory", "if exists r.memhost then r.memhost else r.mem", "bytes",
              "Host memory used by the guest (memhost for VMs, mem for containers).",
              fields("mem", "memhost"), thresholds=steps(("purple", None)), min_=0), 6, 9)
    b.add(top("Top guests by disk I/O", "r.diskread + r.diskwrite", "Bps", "Read + write throughput, now.",
              fields("diskread", "diskwrite"), rate=True, thresholds=steps(("blue", None)), min_=0), 6, 9)
    b.add(top("Top guests by network", "(r.netin + r.netout) * 8.0", "bps", "In + out, now.",
              fields("netin", "netout"), rate=True, thresholds=steps(("green", None)), min_=0), 6, 9)
    b.add(timeseries("Running guests", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and r._field == "status")
          |> aggregateWindow(every: v.windowPeriod, fn: last, createEmpty: false)
          |> map(fn: (r) => ({_time: r._time, object: r.object, _value: if r._value == "running" then 1 else 0}))
          |> group(columns: ["object"])
          |> aggregateWindow(every: v.windowPeriod, fn: sum, createEmpty: false)
          |> ''' + series('if r.object == "qemu" then "VMs" else "CTs"'))],
        stack=True, fill=40, decimals=0, step=True, calcs=("min", "max", "lastNotNull"),
        overrides=[fixed_color("VMs", "blue"), fixed_color("CTs", "purple")]), 12, 8)
    b.add(timeseries("Guest CPU by node (cores)", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and (r._field == "cpu" or r._field == "cpus"))
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({_time: r._time, nodename: r.nodename, _value: r.cpu * r.cpus}))
          |> group(columns: ["nodename"])
          |> aggregateWindow(every: v.windowPeriod, fn: sum, createEmpty: false)
          |> ''' + series("r.nodename"))], stack=True, fill=40, decimals=2, calcs=("mean", "max"),
        desc="Cores busy running guests, per node."), 12, 8)

    b.row("Storage")
    b.add(storage_bars(), 10, 9)
    b.add(timeseries("Storage used over time", [storage_series_query("r.used / r.total")],
                     unit="percentunit", fill=0, min_=0, calcs=("min", "max", "lastNotNull"),
                     desc="Used / total per storage."), 14, 9)
    return finish(dashboard("proxmox-overview", "Proxmox overview",
                            "The PVE nodes, guests and storages at a glance, from the PVE metric server data in InfluxDB.",
                            b, tags=["proxmox"], variables=[bucket_var()], extra_links=[PVE_LINK]))


# --- Guest tables (node and guest dashboards) ------------------------------------------

def guest_table(sel, with_node=False):
    """One row per guest: state, CPU, memory, I/O rates. sel filters the guests (Flux)."""
    nums = fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(sel)s and
               (r._field == "cpu" or r._field == "cpus" or r._field == "mem" or r._field == "memhost" or r._field == "maxmem" or r._field == "uptime" or r._field == "maxdisk"))
          |> last()
          |> group()
          |> pivot(rowKey: ["vmid"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({vmid: r.vmid, cpu: r.cpu, cpus: r.cpus, used: if exists r.memhost then r.memhost else r.mem,
               maxmem: r.maxmem, mempct: if r.maxmem > 0.0 then (if exists r.memhost then r.memhost else r.mem) / r.maxmem else 0.0,
               uptime: r.uptime, maxdisk: r.maxdisk}))''', sel=sel)
    strs = fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(sel)s and (r._field == "status" or r._field == "tags"))
          |> last()
          |> group()
          |> pivot(rowKey: ["vmid", "host", "nodename", "object"], columnKey: ["_field"], valueColumn: "_value")''', sel=sel)
    rates = fx('''
        %(src)s
          |> %(now_rate)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(sel)s and
               (r._field == "diskread" or r._field == "diskwrite" or r._field == "netin" or r._field == "netout"))
          |> derivative(unit: 1s, nonNegative: true)
          |> last()
          |> group()
          |> pivot(rowKey: ["vmid"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({r with netin: r.netin * 8.0, netout: r.netout * 8.0}))''', sel=sel)
    order = ["Name", "VMID", "Type", *(["Node"] if with_node else []), "Status", "Uptime", "vCPUs", "CPU",
             "Memory", "Configured", "Memory %", "Disk size", "Disk read", "Disk write", "Net in", "Net out", "Tags"]
    exclude = [] if with_node else ["nodename"]
    return table("Guests", [nums, strs, rates],
                 desc="Now (end of the time range). Memory is what the guest uses on the host (VM: memhost, "
                      "CT: mem); Configured is its maximum. CPU is the share of its own vCPUs. "
                      "Click a name for the guest's dashboard.",
                 transformations=[joined("vmid"), organize(exclude=exclude, rename={
                     "host": "Name", "vmid": "VMID", "object": "Type", "nodename": "Node", "status": "Status",
                     "uptime": "Uptime", "cpus": "vCPUs", "cpu": "CPU", "used": "Memory", "maxmem": "Configured",
                     "mempct": "Memory %", "maxdisk": "Disk size", "diskread": "Disk read", "diskwrite": "Disk write",
                     "netin": "Net in", "netout": "Net out", "tags": "Tags"}, order=order)],
                 overrides=[cell("Status", "color-text"), override("Status", {"mappings": STATUS_MAP}),
                            cell("Type", "color-text"), override("Type", {"mappings": TYPE_MAP}),
                            override("Uptime", {"unit": "dtdurations"}),
                            *gauge_cell("CPU", "Memory %"),
                            override("Memory", {"unit": "bytes"}), override("Configured", {"unit": "bytes"}),
                            override("Disk size", {"unit": "bytes"}),
                            override("Disk read", {"unit": "Bps"}), override("Disk write", {"unit": "Bps"}),
                            override("Net in", {"unit": "bps"}), override("Net out", {"unit": "bps"}),
                            override("Name", {"links": [guest_link()]}),
                            *([override("Node", {"links": [node_link("nodename")]})] if with_node else [])],
                 sort="Name")


def guest_stack(title, value_expr, flds, sel, unit, desc):
    return timeseries(title, [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(guests)s and %(sel)s and %(flds)s)
          |> %(mean)s
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> map(fn: (r) => ({r with _value: %(value)s}))
          |> filter(fn: (r) => r._value > 0.0)
          |> ''' + series("r.host"), sel=sel, flds=flds, value=value_expr)],
        unit=unit, stack=True, fill=30, calcs=("mean", "max", "lastNotNull"), desc=desc)


# --- Proxmox node ---------------------------------------------------------------------------

def node():
    b = Board()
    n = 'r.host == "${node}"'
    on = 'r.nodename == "${node}"'

    def last(measurement, *flds, extra=""):
        return fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "%(m)s" and r.object == "nodes" and %(n)s and %(flds)s)
              |> last()%(extra)s''', m=measurement, n=n, flds=fields(*flds), extra=extra)

    b.row("Summary")
    b.col(3,
          (stat("State", [fx('''
              %(src)s
                |> %(range)s
                |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and %(n)s and r._field == "avg1")
                |> last()
                |> map(fn: (r) => ({_time: r._time, _value: if int(v: v.timeRangeStop) - int(v: r._time) < 60000000000 then 1 else 0}))''',
                                  n=n)],
                mappings=UP_MAP, thresholds=UP_STEPS, no_value="no data",
                desc="UP if the node reported within the last minute of the time range."), 4),
          (stat("Uptime", [last("system", "uptime")], unit="dtdurations", color_mode="value", thresholds=BLUE,
                decimals=1), 4))
    b.add(gauge("CPU", [last("cpustat", "cpu")], unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Busy share of all cores."), 3, 8)
    b.add(gauge("Memory", [last("memory", "memused", "memtotal", extra='''
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
              |> map(fn: (r) => ({_time: r._time, _value: r.memused / r.memtotal}))''')],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Used = total - available."), 3, 8)
    b.add(gauge("Swap", [last("memory", "swapused", "swaptotal", extra='''
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
              |> map(fn: (r) => ({_time: r._time, _value: if r.swaptotal > 0.0 then r.swapused / r.swaptotal else 0.0}))''')],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION), 3, 8)
    b.add(gauge("Root FS", [last("blockstat", "per", extra='''
              |> map(fn: (r) => ({_time: r._time, _value: float(v: r._value) / 100.0}))''')],
                unit="percentunit", min_=0, max_=1, decimals=0, thresholds=FILL,
                desc="The node's root filesystem (local storage lives on it)."), 3, 8)
    b.add(stat("Load / core", [last("cpustat", "avg1", "avg5", "avg15", "cpus", extra='''
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
              |> map(fn: (r) => ({_time: r._time, _1m: r.avg1 / r.cpus, _5m: r.avg5 / r.cpus, _15m: r.avg15 / r.cpus}))''')],
               text_mode="value_and_name", color_mode="value", decimals=2, thresholds=LOAD, orientation="vertical",
               transformations=[organize(exclude=["_time"], order=["_1m", "_5m", "_15m"])],
               overrides=[override("_1m", {"displayName": "1m"}), override("_5m", {"displayName": "5m"}),
                          override("_15m", {"displayName": "15m"})],
               desc="Load averages divided by the cores; above 1 means tasks wait for a CPU."), 3, 8)
    b.add(stat("Guests", [guest_counts_query(sel=on)], text_mode="value_and_name", color_mode="value",
               overrides=GUEST_COUNT_OVERRIDES, orientation="vertical",
               desc="On this node now: running VMs and CTs, stopped guests (templates not counted), templates."), 3, 8)
    hw = stat("Hardware", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r.object == "nodes" and %(n)s and ((r._measurement == "cpustat" and r._field == "cpus") or
               (r._measurement == "memory" and (r._field == "memtotal" or r._field == "swaptotal")) or (r._measurement == "blockstat" and r._field == "blocks")))
          |> last()
          |> group()
          |> pivot(rowKey: ["host"], columnKey: ["_field"], valueColumn: "_value")''', n=n)],
               text_mode="value_and_name", color_mode="value", thresholds=BLUE, text_size=(11, 16),
               transformations=[organize(exclude=["host"], order=["cpus", "memtotal", "swaptotal", "blocks"])],
               overrides=[override("cpus", {"displayName": "Cores", "unit": "short"}),
                          override("memtotal", {"displayName": "RAM", "unit": "bytes", "decimals": 0}),
                          override("swaptotal", {"displayName": "Swap", "unit": "bytes", "decimals": 0}),
                          override("blocks", {"displayName": "Root FS", "unit": "bytes", "decimals": 0})])
    hw["options"]["reduceOptions"]["fields"] = "/^(cpus|memtotal|swaptotal|blocks)$/"
    exporter = stat("node_exporter", [q('max by (instance) (up{job="node", host="$node"})', "{{instance}}")],
                    mappings=mapping(**{"0": ("down", "orange"), "1": ("UP", "green")}), thresholds=UP_STEPS,
                    no_value="not scraped",
                    desc="Prometheus node_exporter on this node; click for Node Exporter Full (hardware, disks, "
                         "temperatures). greatfox has none installed yet, so it's down there.")
    field_links(exporter, ("Node Exporter Full",
                           NODE_DASH + "?var-job=node&var-node=${__field.labels.instance}&" + TIME_URL))
    b.col(4, (hw, 5), (exporter, 3))

    b.row("CPU and load")
    b.add(timeseries("CPU", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and %(n)s and (r._field == "cpu" or r._field == "wait"))
          |> %(mean)s
          |> ''' + series('if r._field == "cpu" then "busy" else "IO wait"'), n=n)],
        unit="percentunit", min_=0, fill=20, gradient="opacity",
        overrides=[fixed_color("busy", CPU), fixed_color("IO wait", WAIT)],
        desc="Busy share of all cores, and the share spent waiting for I/O."), 12, 8)
    b.add(timeseries("Load average", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "cpustat" and r.object == "nodes" and %(n)s and %(flds)s)
          |> %(mean)s
          |> ''' + series('if r._field == "cpus" then "cores" else strings.trimPrefix(v: r._field, prefix: "avg") + "m"'),
                                        n=n, flds=fields("avg1", "avg5", "avg15", "cpus"))],
        fill=0, min_=0, decimals=2,
        overrides=[override("cores", {"color": {"mode": "fixed", "fixedColor": "red"},
                                      "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})],
        desc="1, 5 and 15 minute load averages; the dashed line is the node's core count."), 12, 8)

    b.row("Memory and disk")
    b.add(timeseries("Memory", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "memory" and r.object == "nodes" and %(n)s and %(flds)s)
          |> %(mean)s
          |> filter(fn: (r) => r._field != "arcsize" or r._value > 1048576.0)
          |> ''' + series('if r._field == "memused" then "used" else if r._field == "memavailable" then "available" else "ZFS ARC"'),
                                  n=n, flds=fields("memused", "memavailable", "arcsize"))],
        unit="bytes", stack=True, fill=30,
        overrides=[fixed_color("used", MEM), fixed_color("available", "green"),
                   override("ZFS ARC", {"custom.stacking": {"mode": "none", "group": "A"}, "custom.fillOpacity": 0,
                                        "color": {"mode": "fixed", "fixedColor": "orange"}})],
        desc="Used (total - available) and available stack up to the total. ZFS ARC shows only on nodes with ZFS."),
          12, 8)
    b.add(timeseries("Swap", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "memory" and r.object == "nodes" and %(n)s and (r._field == "swapused" or r._field == "swaptotal"))
          |> %(mean)s
          |> ''' + series('if r._field == "swapused" then "used" else "total"'), n=n)],
        unit="bytes", fill=20, overrides=[fixed_color("used", SWAP),
                                          override("total", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "text"},
                                                             "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})]), 6, 8)
    b.add(timeseries("Root filesystem", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "blockstat" and r.object == "nodes" and %(n)s and r._field == "per")
          |> %(mean)s
          |> map(fn: (r) => ({r with _value: r._value / 100.0}))
          |> ''' + series('"used"'), n=n)],
        unit="percentunit", min_=0, max_=1, fill=20, gradient="opacity", thresholds=FILL,
        color={"mode": "thresholds"}, desc="Used share of /, as df reports it."), 6, 8)

    b.row("Network")
    for title, regex, desc in (
            ("Physical NICs", "^(eth|en|wl)", "Every physical NIC; inbound up, outbound down."),
            ("Bridges and bonds", "^(vmbr|bond)", "Linux bridges (guest traffic and VLANs) and bonds.")):
        b.add(timeseries(title, [fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "nics" and r.object == "nodes" and %(n)s and r.instance =~ /%(re)s/ and (r._field == "receive" or r._field == "transmit"))
              |> %(rate)s
              |> map(fn: (r) => ({r with _value: r._value * 8.0}))
              |> ''' + series('r.instance + (if r._field == "receive" then " in" else " out")'), n=n, re=regex)],
            unit="bps", fill=10, overrides=net_overrides(), calcs=("mean", "max"), desc=desc), 12, 9)
    nic_sel = f'{n} and r.instance !~ /^(tap|veth|fwbr|fwpr|fwln|lo$)/'
    b.add(table("Interfaces", [
        fx('''
            %(src)s
              |> %(now_rate)s
              |> filter(fn: (r) => r._measurement == "nics" and r.object == "nodes" and %(sel)s and (r._field == "receive" or r._field == "transmit"))
              |> derivative(unit: 1s, nonNegative: true)
              |> last()
              |> map(fn: (r) => ({instance: r.instance, _field: r._field + "_rate", _value: r._value * 8.0}))
              |> group()
              |> pivot(rowKey: ["instance"], columnKey: ["_field"], valueColumn: "_value")''', sel=nic_sel),
        fx('''
            %(src)s
              |> %(now)s
              |> filter(fn: (r) => r._measurement == "nics" and r.object == "nodes" and %(sel)s)
              |> last()
              |> map(fn: (r) => ({instance: r.instance, _field: r._field, _value: string(v: r._value)}))
              |> group()
              |> pivot(rowKey: ["instance"], columnKey: ["_field"], valueColumn: "_value")
              |> map(fn: (r) => ({instance: r.instance, type: r.type, receive: float(v: r.receive), transmit: float(v: r.transmit)}))''',
           sel=nic_sel),
    ], desc="Physical NICs, bonds, bridges and VLAN interfaces (guest tap/veth and firewall bridges left out). "
            "Totals are bytes since the node booted.",
        transformations=[joined("instance"), organize(rename={
            "instance": "Interface", "type": "Type", "receive_rate": "In", "transmit_rate": "Out",
            "receive": "Received", "transmit": "Sent"}, order=["Interface", "Type", "In", "Out", "Received", "Sent"])],
        overrides=[override("In", {"unit": "bps", "custom.cellOptions": {"type": "color-text"},
                                   "color": {"mode": "fixed", "fixedColor": NET_IN}}),
                   override("Out", {"unit": "bps", "custom.cellOptions": {"type": "color-text"},
                                    "color": {"mode": "fixed", "fixedColor": NET_OUT}}),
                   override("Received", {"unit": "bytes"}), override("Sent", {"unit": "bytes"}),
                   cell("Type", "color-text"),
                   override("Type", {"mappings": mapping(physical=("physical", "blue"), virtual=("virtual", "text"))})],
        sort="In", desc_sort=True), 24, 9)

    b.row("Guests on ${node}")
    b.add(guest_table(on), 24, 10)
    b.add(guest_stack("Guest CPU (cores)", "r.cpu * r.cpus", fields("cpu", "cpus"), on, "short",
                      "Cores each guest keeps busy (CPU share x vCPUs), stacked."), 12, 9)
    b.add(guest_stack("Guest memory (host)", "if exists r.memhost then r.memhost else r.mem",
                      fields("mem", "memhost"), on, "bytes",
                      "Host memory each guest uses (VM: memhost, CT: mem), stacked."), 12, 9)
    b.add(guest_stack("Guest disk I/O", "r.diskread + r.diskwrite", fields("diskread", "diskwrite"), on, "Bps",
                      "Read + write per guest, stacked."), 12, 8)
    b.add(guest_stack("Guest network", "(r.netin + r.netout) * 8.0", fields("netin", "netout"), on, "bps",
                      "In + out per guest, stacked."), 12, 8)
    # The two rate panels need rates, not counters.
    for p in b.target[-2:]:
        p["targets"][0]["query"] = p["targets"][0]["query"].replace(
            "|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)",
            "|> " + FRAGMENTS["rate"])

    b.row("Storages on ${node}")
    b.add(storage_bars(on, "Storage used"), 8, 9)
    b.add(storage_table(on), 16, 9)

    b.row("Hardware (node_exporter)", collapsed=True)
    b.add(timeseries("Temperatures", [q('max by (chip) (node_hwmon_temp_celsius{job="node", host="$node"})', "{{chip}}")],
                     unit="celsius", fill=0, calcs=("mean", "max", "lastNotNull"),
                     desc="Hottest sensor per hwmon chip (node_exporter). Empty without node_exporter (greatfox)."), 12, 8)
    b.add(timeseries("Disk busy", [q('rate(node_disk_io_time_seconds_total{job="node", host="$node", device!~"(dm-|rbd|nbd|zd|loop).*"}[$__rate_interval])',
                                     "{{device}}")],
                     unit="percentunit", min_=0, max_=1, fill=0, calcs=("mean", "max"),
                     desc="Share of time each physical disk was busy (OSD and boot disks)."), 12, 8)

    return finish(dashboard("proxmox-node", "Proxmox node",
                            "One PVE node in depth: CPU, load, memory, swap, root disk, NICs, its guests and storages.",
                            b, tags=["proxmox"], variables=[bucket_var(), node_var()], extra_links=[PVE_LINK, {
                                "type": "link", "title": "Logs of this node", "icon": "doc", "tags": [], "tooltip": "",
                                "url": "/d/logs-proxmox/logs-proxmox?var-node=${node}", "includeVars": False,
                                "keepTime": True, "asDropdown": False, "targetBlank": False}]))


def storage_table(sel="true", title="Storages"):
    """Storages now, with growth over the time range and when they'd be full at that rate."""
    p = table(title, [fx('''
        cur = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and
               (r._field == "total" or r._field == "used" or r._field == "avail" or r._field == "shared" or r._field == "active" or r._field == "enabled"))
          |> last()
          |> group()
          |> pivot(rowKey: ["host", "nodename"], columnKey: ["_field"], valueColumn: "_value")
        strs = %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and (r._field == "type" or r._field == "content"))
          |> last()
          |> group()
          |> pivot(rowKey: ["host", "nodename"], columnKey: ["_field"], valueColumn: "_value")
        used = %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(sel)s and r._field == "used")
        growth = join(tables: {f: used |> first(), l: used |> last()}, on: ["host", "nodename"])
          |> map(fn: (r) => ({host: r.host, nodename: r.nodename,
               rate: if r._time_l > r._time_f then (r._value_l - r._value_f) / (float(v: int(v: r._time_l) - int(v: r._time_f)) / 1000000000.0) else 0.0}))
        join(tables: {a: join(tables: {n: cur, s: strs}, on: ["host", "nodename"]), g: growth}, on: ["host", "nodename"])
          |> map(fn: (r) => ({
               storage: if r.shared == 1.0 then r.host else r.host + " (" + r.nodename + ")",
               nodename: if r.shared == 1.0 then "all" else r.nodename,
               type: r.type, content: r.content, shared: r.shared, active: r.active, enabled: r.enabled,
               used: r.used, avail: r.avail, total: r.total, pct: if r.total > 0.0 then r.used / r.total else 0.0,
               day: r.rate * 86400.0,
               full: if r.rate > 0.0 then r.avail / r.rate else -1.0,
               link: if r.type == "rbd" or r.type == "cephfs" then "%(ceph)s?orgId=1"
                     else if r.shared == 1.0 then "%(storage_dash)s?var-bucket=${bucket}&var-storage=" + r.host
                     else "%(node_dash)s?var-bucket=${bucket}&var-node=" + r.nodename}))
          |> group(columns: ["storage"])
          |> first(column: "storage")
          |> group()
          |> sort(columns: ["pct"], desc: true)''', sel=sel, ceph=CEPH_DASH, storage_dash=STORAGE_DASH,
                                node_dash=PVE_NODE_DASH)],
              desc="Now, shared storages once. Growth is the change of used space over the time range, per day; "
                   "Full in extrapolates it (blank when not growing). Click a storage: Ceph storages open the "
                   "Ceph cluster dashboard, local ones their node.",
              transformations=[organize(rename={
                  "storage": "Storage", "nodename": "Node", "type": "Type", "content": "Content", "shared": "Shared",
                  "active": "Active", "enabled": "Enabled", "used": "Used", "avail": "Available", "total": "Total",
                  "pct": "Used %", "day": "Growth / day", "full": "Full in"},
                  order=["Storage", "Node", "Type", "Shared", "Content", "Used", "Available", "Total", "Used %",
                         "Growth / day", "Full in", "Active", "Enabled", "link"])],
              overrides=[*hidden("link", "Active", "Enabled"),
                         override("Storage", {"links": [{"title": "${__data.fields.Storage}",
                                                         "url": "${__data.fields.link}&" + TIME_URL}]}),
                         cell("Shared", "color-text"), override("Shared", {"mappings": SHARED_MAP}),
                         override("Used", {"unit": "bytes"}), override("Available", {"unit": "bytes"}),
                         override("Total", {"unit": "bytes"}),
                         *gauge_cell("Used %", thresholds=FILL),
                         override("Growth / day", {"unit": "bytes", "decimals": 1}),
                         override("Full in", {"unit": "dtdurations",
                                              "mappings": [{"type": "range", "options": {"from": -1e18, "to": 0,
                                                                                         "result": {"text": "not filling up", "index": 0}}}],
                                              "thresholds": steps(("red", None), ("orange", 7 * 86400), ("green", 30 * 86400)),
                                              "custom.cellOptions": {"type": "color-text"}})],
              sort="Used %", desc_sort=True)
    return p


# --- Proxmox guests -----------------------------------------------------------------------

def guests():
    b = Board()
    g = FRAGMENTS["guest"]

    def latest(flds, measurement="system", value="r._value", extra=""):
        """The newest value(s) of one guest (a migrated guest has a series per node)."""
        return fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "%(m)s" and %(g)s and %(flds)s)
              |> last()
              |> group()
              |> sort(columns: ["_time"])
              |> last()
              |> map(fn: (r) => ({_time: r._time, _value: %(value)s}))%(extra)s''',
                  m=measurement, g=g, flds=flds, value=value, extra=extra)

    def pair(measurement, flds, value):
        """A value computed from several fields of one guest's newest sample."""
        return fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "%(m)s" and %(g)s and %(flds)s)
              |> last()
              |> group()
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
              |> sort(columns: ["_time"])
              |> last(column: "_time")
              |> map(fn: (r) => ({_time: r._time, _value: %(value)s}))''', m=measurement, g=g, flds=flds, value=value)

    def ts(flds, label, measurement="system", rate=False, scale="", extra_filter="true"):
        return fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "%(m)s" and %(g)s and %(flds)s and %(xf)s)
              |> %(agg)s%(scale)s
              |> ''' + series(label), m=measurement, g=g, flds=flds, agg=FRAGMENTS["rate" if rate else "mean"],
                  scale=f"\n  |> map(fn: (r) => ({{r with _value: r._value{scale}}}))" if scale else "", xf=extra_filter)

    b.row("All guests")
    b.add(guest_table(FRAGMENTS["on_node"], with_node=True), 24, 10)

    b.row("Guest ${guest:text}")
    b.add(text_stat("Status", [latest(fields("status"))], mappings=STATUS_MAP, text_size=(12, 22)), 3, 4)
    b.add(text_stat("Type", [latest(fields("uptime"), value="r.object")], mappings=TYPE_MAP, text_size=(12, 22)), 2, 4)
    node_stat = text_stat("Node", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(g)s and r._field == "uptime")
          |> last()
          |> group()
          |> sort(columns: ["_time"])
          |> last()
          |> map(fn: (r) => ({_time: r._time, _value: r.nodename}))''', g=g)], thresholds=BLUE, text_size=(12, 22),
                          desc="The node the guest runs on (the newest one if it migrated). Click for its dashboard.")
    field_links(node_stat, ("Proxmox node", PVE_NODE_DASH + "?var-bucket=${bucket}&var-node=${__value.raw}&" + TIME_URL))
    b.add(node_stat, 3, 4)
    b.add(stat("Uptime", [latest(fields("uptime"))], unit="dtdurations", decimals=1, color_mode="value",
               thresholds=steps(("orange", None), ("green", 3600)), mappings=mapping(**{"0": ("not running", "text")}),
               text_size=(12, 22)), 3, 4)
    b.add(stat("vCPUs", [latest(fields("cpus"))], color_mode="value", thresholds=BLUE, text_size=(12, 22)), 2, 4)
    b.add(stat("Memory", [latest(fields("maxmem"))], unit="bytes", decimals=0, color_mode="value", thresholds=BLUE,
               text_size=(12, 22), desc="Configured memory."), 3, 4)
    b.add(stat("Disk size", [latest(fields("maxdisk"))], unit="bytes", decimals=0, color_mode="value",
               thresholds=BLUE, text_size=(12, 22), desc="Size of the boot disk (CT: root filesystem)."), 3, 4)
    b.add(text_stat("Tags", [latest(fields("tags"), value='strings.replaceAll(v: r._value, t: ";", u: " · ")')],
                    thresholds=steps(("text", None)), text_size=(12, 16), no_value="none"), 5, 4)

    b.add(gauge("CPU", [latest(fields("cpu"))], unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Share of the guest's vCPUs in use."), 4, 7)
    b.add(gauge("Memory used", [pair("system", fields("mem", "memhost", "maxmem"),
                                     "(if exists r.memhost then r.memhost else r.mem) / r.maxmem")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Host memory the guest uses (VM: memhost, CT: mem) / configured memory. VMs with PCI "
                     "passthrough pin all their memory, so they sit at 100%."), 4, 7)
    b.add(gauge("Balloon", [pair("ballooninfo", fields("actual", "max_mem"), "r.actual / r.max_mem")],
                unit="percentunit", min_=0, max_=1, decimals=0, thresholds=steps(("orange", None), ("green", 0.999)),
                no_value="no balloon",
                desc="VMs with the balloon driver: current balloon size / maximum. Below 100% means PVE took "
                     "memory back from the guest."), 4, 7)
    b.add(gauge("Root disk (CT)", [pair("system", fields("disk", "maxdisk"), "r.disk / r.maxdisk")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FILL, no_value="n/a",
                desc="Containers only: used / size of the root filesystem. PVE doesn't know how full a VM's "
                     "disk is (always 0)."), 4, 7)
    b.add(stat("Pressure (avg10)", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(g)s and %(flds)s)
          |> last()
          |> group()
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> sort(columns: ["_time"])
          |> last(column: "_time")
          |> map(fn: (r) => ({cpu: r.pressurecpusome, io: r.pressureiosome, memory: r.pressurememorysome}))''',
                                         g=g, flds=fields("pressurecpusome", "pressureiosome", "pressurememorysome"))],
               unit="percent", decimals=1, text_mode="value_and_name", color_mode="value", orientation="vertical",
               thresholds=steps(("green", None), ("orange", 10), ("red", 40)),
               desc="Pressure stall information of the guest's cgroup: share of time some task waited for "
                    "CPU, I/O or memory (10 s average)."), 4, 7)
    b.add(text_stat("QEMU", [fx('''
        %(src)s
          |> %(range)s
          |> filter(fn: (r) => r._measurement == "system" and %(g)s and (r._field == "running-qemu" or r._field == "running-machine"))
          |> last()
          |> group()
          |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
          |> sort(columns: ["_time"])
          |> last(column: "_time")
          |> map(fn: (r) => ({version: r["running-qemu"], machine: r["running-machine"]}))''', g=g)],
                    text_mode="value_and_name", thresholds=steps(("text", None)), text_size=(11, 14),
                    orientation="vertical", no_value="not a running VM",
                    desc="QEMU version and machine type the VM runs with (a VM keeps them until it restarts)."), 4, 7)

    b.row("CPU and memory")
    b.add(timeseries("CPU", [ts(fields("cpu"), '"CPU"')], unit="percentunit", min_=0, fill=20, gradient="opacity",
                     overrides=[fixed_color("CPU", CPU)], desc="Share of the guest's vCPUs in use."), 8, 8)
    b.add(timeseries("Memory", [ts(fields("mem", "memhost", "maxmem", "balloon", "swap"),
                                   '(if r._field == "memhost" then "host" else if r._field == "mem" then "used" '
                                   'else if r._field == "maxmem" then "configured" else if r._field == "balloon" '
                                   'then "balloon target" else "swap")')],
                     unit="bytes", fill=10, min_=0,
                     overrides=[fixed_color("used", MEM), fixed_color("host", "blue"), fixed_color("swap", SWAP),
                                override("configured", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "text"},
                                                        "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}}),
                                override("balloon target", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "green"},
                                                            "custom.lineStyle": {"fill": "dash", "dash": [4, 6]}})],
                     desc="used: what the guest reports in use (VM: via the balloon driver, else the same as host); "
                          "host: memory the VM process holds on the node; configured: the maximum; "
                          "balloon target: what PVE asks the balloon to give back to; swap: CT swap."), 8, 8)
    b.add(timeseries("Pressure", [ts(fields(*[f"pressure{k}{s}" for k in ("cpu", "io", "memory") for s in ("some", "full")]),
                                     'strings.trimPrefix(v: strings.replaceAll(v: strings.replaceAll(v: r._field, t: "some", u: " some"), '
                                     't: "full", u: " full"), prefix: "pressure")')],
                     unit="percent", fill=0, min_=0,
                     overrides=[override("/full$/", {"custom.lineStyle": {"fill": "dash", "dash": [10, 10]}}, regex=False)],
                     desc="Pressure stall information (10 s averages): some = at least one task waited, full = all "
                          "tasks waited."), 8, 8)
    # override() treats a name starting with / as a regex only through byRegexp; fix the matcher.
    b.target[-1]["fieldConfig"]["overrides"][0]["matcher"] = {"id": "byRegexp", "options": ".* full$"}

    b.row("Disk")
    b.add(timeseries("Disk throughput", [ts(fields("diskread", "diskwrite"),
                                            'if r._field == "diskread" then "read" else "write"', rate=True)],
                     unit="Bps", fill=20, overrides=rw_overrides(), calcs=("mean", "max"),
                     desc="All disks of the guest; reads up, writes down."), 8, 8)
    b.add(timeseries("IOPS per disk (VM)", [ts(fields("rd_operations", "wr_operations"),
                                               'r.instance + (if r._field == "rd_operations" then " read" else " write")',
                                               measurement="blockstat", rate=True)],
                     unit="iops", fill=10, overrides=rw_overrides(), calcs=("mean", "max"),
                     desc="QEMU block statistics per virtual disk (VMs only)."), 8, 8)

    def latency(kind):
        return fx('''
            %(src)s
              |> %(range)s
              |> filter(fn: (r) => r._measurement == "blockstat" and %(g)s and (r._field == "%(k)s_total_time_ns" or r._field == "%(k)s_operations"))
              |> %(rate)s
              |> pivot(rowKey: ["_time"], columnKey: ["_field"], valueColumn: "_value")
              |> filter(fn: (r) => r.%(k)s_operations > 0.0)
              |> map(fn: (r) => ({r with _value: r.%(k)s_total_time_ns / r.%(k)s_operations / 1000000000.0}))
              |> ''' + series('r.instance + " %(name)s"'), g=g, k=kind, name="read" if kind == "rd" else "write")

    b.add(timeseries("Latency per disk (VM)", [latency("rd"), latency("wr")], unit="s", fill=0,
                     overrides=[override("(?i).*read$", {"color": {"mode": "fixed", "fixedColor": READ}}, regex=True),
                                override("(?i).*write$", {"color": {"mode": "fixed", "fixedColor": WRITE}}, regex=True)],
                     calcs=("mean", "max"), desc="Average time per completed read and write, per virtual disk."), 8, 8)
    b.add(timeseries("Throughput per disk (VM)", [ts(fields("rd_bytes", "wr_bytes"),
                                                     'r.instance + (if r._field == "rd_bytes" then " read" else " write")',
                                                     measurement="blockstat", rate=True)],
                     unit="Bps", fill=10, overrides=rw_overrides(), calcs=("mean", "max")), 8, 8)
    b.add(timeseries("Root disk used (CT)", [ts(fields("disk", "maxdisk"),
                                                'if r._field == "disk" then "used" else "size"')],
                     unit="bytes", fill=20, min_=0,
                     overrides=[fixed_color("used", "blue"),
                                override("size", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "text"},
                                                  "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})],
                     desc="Containers only; PVE doesn't see inside a VM's disks."), 8, 8)
    b.add(stat("I/O errors (VM)", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "blockstat" and %(g)s and (strings.hasPrefix(v: r._field, prefix: "failed_") or strings.hasPrefix(v: r._field, prefix: "invalid_")))
          |> last()
          |> group(columns: ["instance"])
          |> sum()
          |> ''' + series("r.instance").replace('  |> sort(columns: ["_time"])\n', "").replace('"_time", ', ""), g=g)],
               text_mode="value_and_name", thresholds=RED_IF_ANY, decimals=0, no_value="no VM disks",
               desc="Failed and invalid operations per virtual disk since the VM started (should be 0)."), 8, 8)
    b.target[-1]["fieldConfig"]["defaults"]["displayName"] = "${__field.labels.series}"

    b.row("Network")
    b.add(timeseries("Network", [ts(fields("netin", "netout"), 'if r._field == "netin" then "in" else "out"',
                                    rate=True, scale=" * 8.0")],
                     unit="bps", fill=20, overrides=net_overrides(), calcs=("mean", "max"),
                     desc="All NICs of the guest; inbound up, outbound down."), 12, 8)
    b.add(timeseries("Per NIC (VM)", [ts(fields("netin", "netout"),
                                         'r.instance + (if r._field == "netin" then " in" else " out")',
                                         measurement="nics", rate=True, scale=" * 8.0")],
                     unit="bps", fill=10, overrides=net_overrides(), calcs=("mean", "max"),
                     desc="Per tap interface (VMs only; container veths are on the node dashboard)."), 12, 8)

    b.row("Balloon and guest memory (VM)", collapsed=True)
    b.add(timeseries("Balloon", [ts(fields("actual", "max_mem", "total_mem", "free_mem"),
                                    '(if r._field == "actual" then "balloon size" else if r._field == "max_mem" '
                                    'then "maximum" else if r._field == "total_mem" then "guest total" else "guest free")',
                                    measurement="ballooninfo")],
                     unit="bytes", fill=0, min_=0,
                     desc="From the balloon driver: balloon size (memory the guest may use), maximum, and the "
                          "guest's own view of total and free memory."), 8, 8)
    b.add(timeseries("Page faults", [ts(fields("major_page_faults", "minor_page_faults"),
                                        'if r._field == "major_page_faults" then "major" else "minor"',
                                        measurement="ballooninfo", rate=True)],
                     unit="short", fill=0, desc="Per second, as the guest reports them. Major faults read from disk."), 8, 8)
    b.add(timeseries("Guest swap", [ts(fields("mem_swapped_in", "mem_swapped_out"),
                                       'if r._field == "mem_swapped_in" then "in" else "out"',
                                       measurement="ballooninfo", rate=True)],
                     unit="Bps", fill=10, overrides=net_overrides(), desc="Swapped in / out inside the guest."), 8, 8)

    return finish(dashboard("proxmox-guest", "Proxmox guests",
                            "Every VM and container, and one in depth: state, CPU, memory, balloon, pressure, disk and network.",
                            b, tags=["proxmox"], variables=[bucket_var(), node_var(multi=True), guest_var()],
                            extra_links=[PVE_LINK]))


# --- Proxmox storage ------------------------------------------------------------------------

def storage():
    b = Board()
    s = FRAGMENTS["storage"]
    b.row("Summary")
    b.add(storage_bars(s), 10, 10)
    b.col(5,
          (stat("Storages", [storage_now_query(s, tail='''
              |> reduce(identity: {storages: 0, inactive: 0, fullest: 0.0}, fn: (r, accumulator) => ({
                   storages: accumulator.storages + 1, inactive: accumulator.inactive + (if r.active == 1.0 then 0 else 1),
                   fullest: if r.pct > accumulator.fullest then r.pct else accumulator.fullest}))''')],
                text_mode="value_and_name", color_mode="value", orientation="vertical",
                transformations=[organize(order=["storages", "inactive", "fullest"])],
                overrides=[override("storages", {"displayName": "Storages", "color": {"mode": "fixed", "fixedColor": "blue"}}),
                           override("inactive", {"displayName": "Inactive", "thresholds": RED_IF_ANY}),
                           override("fullest", {"displayName": "Fullest", "unit": "percentunit", "decimals": 1,
                                                "thresholds": FILL})],
                desc="Storages (shared ones once), inactive ones (PVE can't reach them) and the fullest one."), 10))
    ceph_link = [("Ceph cluster", CEPH_DASH + "?" + TIME_URL)]
    b.col(9,
          (stat("Ceph health", [q("ceph_health_status")], mappings=mapping(**{
              "0": ("HEALTH_OK", "green"), "1": ("HEALTH_WARN", "orange"), "2": ("HEALTH_ERR", "red")}),
                thresholds=steps(("green", None), ("orange", 1), ("red", 2)), no_value="no ceph metrics",
                links=ceph_link, desc="ceph_rbd and cephfs live on the PVE Ceph cluster (Prometheus, mgr exporter)."), 5),
          (stat("Ceph raw used", [q("ceph_cluster_total_used_raw_bytes / ceph_cluster_total_bytes")],
                unit="percentunit", decimals=1, color_mode="value", graph=True, thresholds=FILL, links=ceph_link,
                desc="Raw used / raw capacity over all OSDs (replication included); PVE's ceph_rbd/cephfs "
                     "numbers are per pool, after replication."), 5))
    b.add(storage_table(s), 24, 10)

    b.row("Trends")
    b.add(timeseries("Used", [storage_series_query("r.used", s)], unit="bytes", fill=0, min_=0,
                     calcs=("min", "max", "lastNotNull")), 8, 9)
    b.add(timeseries("Used %", [storage_series_query("r.used / r.total", s)], unit="percentunit", fill=0, min_=0,
                     calcs=("min", "max", "lastNotNull")), 8, 9)
    b.add(timeseries("Free", [storage_series_query("r.total - r.used", s)], unit="bytes", fill=0, min_=0,
                     calcs=("min", "lastNotNull"), desc="Total - used."), 8, 9)

    b.row("Local storages per node", collapsed=True)
    b.add(table("Local storage used per node", [fx('''
        %(src)s
          |> %(now)s
          |> filter(fn: (r) => r._measurement == "system" and r.object == "storages" and %(s)s and (r._field == "used" or r._field == "total" or r._field == "shared"))
          |> last()
          |> group()
          |> pivot(rowKey: ["host", "nodename"], columnKey: ["_field"], valueColumn: "_value")
          |> filter(fn: (r) => r.shared == 0.0)
          |> map(fn: (r) => ({nodename: r.nodename, host: r.host, pct: if r.total > 0.0 then r.used / r.total else 0.0}))
          |> pivot(rowKey: ["nodename"], columnKey: ["host"], valueColumn: "pct")''', s=s)],
                desc="Used share of each node-local storage.",
                transformations=[organize(rename={"nodename": "Node"})],
                overrides=[*[o for o in gauge_cell(".*", thresholds=FILL)],
                           override("Node", {"links": [node_link("nodename")], "custom.cellOptions": {"type": "auto"},
                                             "unit": "none"})],
                sort="Node"), 24, 9)
    b.target[-1]["fieldConfig"]["overrides"][0]["matcher"] = {"id": "byType", "options": "number"}

    return finish(dashboard("proxmox-storage", "Proxmox storage",
                            "PVE storages: capacity, use, growth and when they fill up; Ceph-backed ones link to Ceph.",
                            b, tags=["proxmox"], variables=[bucket_var(), storage_var()], extra_links=[PVE_LINK],
                            time_from="now-24h"))


# --- Row for the lylat.space overview (custom.py) ----------------------------------------

def overview_row(b):
    """Proxmox at a glance on the landing page: both buckets, no variables."""
    both = ('union(tables: [from(bucket: "pve_cluster") |> %(r)s |> filter(fn: (r) => %(f)s), '
            'from(bucket: "pve_greatfox") |> %(r)s |> filter(fn: (r) => %(f)s)])')
    link = [("Proxmox overview", OVERVIEW_DASH + "?" + TIME_URL)]
    nodes = fx('''
        %(both)s
          |> last()
          |> group()
          |> map(fn: (r) => ({r with fresh: int(v: v.timeRangeStop) - int(v: r._time) < 60000000000}))
          |> reduce(identity: {up: 0, down: 0}, fn: (r, accumulator) => ({
               up: accumulator.up + (if r.fresh then 1 else 0), down: accumulator.down + (if r.fresh then 0 else 1)}))''',
               both=both % {"r": FRAGMENTS["range"],
                            "f": 'r._measurement == "cpustat" and r.object == "nodes" and r._field == "avg1"'})
    b.add(stat("PVE nodes", [nodes], text_mode="value_and_name", color_mode="value", overrides=NODES_UP_OVERRIDES,
               links=link, desc="The lylat cluster and greatfox: nodes reporting to InfluxDB in the last minute (Up) "
                                "and nodes that stopped reporting (Down)."), 4, 5)
    guests = fx('''
        %(both)s
          |> last()
          |> map(fn: (r) => ({vmid: r.vmid, nodename: r.nodename, object: r.object, _field: r._field, _value: string(v: r._value)}))
          |> group()
          |> pivot(rowKey: ["vmid", "nodename", "object"], columnKey: ["_field"], valueColumn: "_value")
          |> reduce(identity: {vms: 0, cts: 0, stopped: 0}, fn: (r, accumulator) => ({
               vms: accumulator.vms + (if r.status == "running" and r.object == "qemu" then 1 else 0),
               cts: accumulator.cts + (if r.status == "running" and r.object == "lxc" then 1 else 0),
               stopped: accumulator.stopped + (if r.status != "running" and not exists r.template then 1 else 0)}))''',
                both=both % {"r": FRAGMENTS["now"],
                             "f": 'r._measurement == "system" and (r.object == "qemu" or r.object == "lxc") and '
                                  '(r._field == "status" or r._field == "template")'})
    b.add(stat("PVE guests", [guests], text_mode="value_and_name", color_mode="value",
               overrides=GUEST_COUNT_OVERRIDES, links=link,
               desc="Both PVE setups: running VMs and containers, stopped guests (templates not counted)."), 6, 5)
    cluster = 'from(bucket: "pve_cluster")'
    b.add(stat("lylat CPU", [weighted_cpu_query(src=cluster)], unit="percentunit", decimals=1, color_mode="value",
               graph=True, thresholds=FRACTION, links=link, desc="Busy share of all cores of the lylat cluster."), 4, 5)
    b.add(stat("lylat memory", [weighted_mem_query(src=cluster)], unit="percentunit", decimals=1, color_mode="value",
               graph=True, thresholds=FRACTION, links=link, desc="Used / total memory of the lylat cluster."), 4, 5)
    fullest = storage_now_query(tail='''
        |> top(n: 1, columns: ["pct"])
        |> keep(columns: ["storage", "pct"])''')
    fullest["query"] = fullest["query"].replace("${bucket}", "pve_cluster")
    p = stat("Fullest PVE storage", [fullest], unit="percentunit", decimals=1, color_mode="value", thresholds=FILL,
             links=[("Proxmox storage", STORAGE_DASH + "?" + TIME_URL)],
             desc="The lylat cluster's fullest storage (shared ones once, local ones per node).")
    p["options"]["reduceOptions"] = {"values": True, "calcs": ["lastNotNull"], "fields": "/^pct$/"}
    b.add(p, 6, 5)
    for panel in b.target[-5:]:
        finish({"panels": [panel]})


# --- helpers for the finished dashboards ---------------------------------------------

def walk(panels):
    for p in panels:
        yield p
        yield from walk(p.get("panels", []))


def finish(dash):
    """Panels whose targets are Flux queries use the InfluxDB datasource."""
    for p in walk(dash["panels"]):
        targets = p.get("targets", [])
        if targets and all("query" in t for t in targets):
            p["datasource"] = dict(INFLUX)
            for t in targets:
                t.pop("expr", None)
    return dash


DASHBOARDS = {
    "Proxmox/proxmox-overview.json": overview,
    "Proxmox/proxmox-node.json": node,
    "Proxmox/proxmox-guest.json": guests,
    "Proxmox/proxmox-storage.json": storage,
}
