"""Proxmox dashboards, built from the pvestatd stats in Prometheus/Mimir (job "pvestatd").

Run custom.py, not this file: it imports these builders and writes the JSON with
the others. Every dashboard here:

- queries the default Prometheus datasource (uid "prometheus", Mimir) and limits the
  nodes with a "Cluster" variable: the 7-node cluster lylat or the standalone greatfox;
- carries the "lylat" and "proxmox" tags, the Dashboards dropdown and a
  "Proxmox dashboards" dropdown that keeps the selected cluster, node and guest.

pvestatd on every node pushes its stats every ~10 s to a Telegraf per backend, which serves
them as pvestatd_<measurement>_<field> (modules/services/monitoring/pvestatd.tf); Prometheus
scrapes them every 10 s, so the panels set a 10 s minimum interval. PVE 9 names:

  measurement  object            labels                          fields
  system       nodes             host                            uptime
  cpustat      nodes             host                            cpu, wait (fractions), avg1/5/15, cpus
  memory       nodes             host                            memtotal/used/free/available, swap*, arc*
  blockstat    nodes             host                            root filesystem: per (% used), used, blocks, ...
  nics         nodes             host, device (NIC)              receive, transmit (byte counters)
  system       qemu, lxc         host (= guest name), vmid,      running (1 = status running, else 0), cpu
                                 nodename, tags                  (fraction of its vCPUs), cpus, mem, memhost
                                                                 (qemu), maxmem, disk (lxc), maxdisk,
                                                                 diskread/write, netin/out (byte counters),
                                                                 uptime, pressure*, template (only on templates)
  blockstat    qemu              vmid, nodename, device (disk)   rd/wr bytes, operations, total_time_ns, ...
  nics         qemu              vmid, nodename, device (tap)    netin, netout
  ballooninfo  qemu              vmid, nodename                  actual, max_mem, free_mem, total_mem, ...
  system       storages          host (= storage), nodename,     total, used, avail, shared, active, enabled
                                 type, content

Counters are untyped: rate() over $__rate_interval. String fields are gone (the guest's status
is pvestatd_system_running; QEMU version/machine and the NIC type are not exported). A storage's
content label comes in a different order from push to push (each order is its own series), so
storage queries first collapse it with max by (host, nodename).
"""
from custom import (BLUE, CEPH_DASH, FILL, MERGE, NODE_DASH, READ, RED_IF_ANY, UP_MAP, UP_STEPS, WRITE, Board,
                    bargauge, cell, dashboard, fixed_color, gauge, hidden, mapping, matrix, organize, override, q,
                    query_var, stat, steps, table, timeseries)
from theme import ACCENT, ACCENT2, ACCENT3, INFO, OK, SERIES, TEXT

OVERVIEW_DASH = "/d/proxmox-overview/proxmox-overview"
PVE_NODE_DASH = "/d/proxmox-node/proxmox-node"
GUEST_DASH = "/d/proxmox-guest/proxmox-guest"
STORAGE_DASH = "/d/proxmox-storage/proxmox-storage"

# The standalone node; everything else is the lylat cluster. The Cluster variable's value is the
# comparison against it (host${cluster}"greatfox"): no quotes in the value, which Grafana would escape.
STANDALONE = "greatfox"
CLUSTERS = (("lylat cluster", "!="), (STANDALONE, "="))
CL = '${cluster}"' + STANDALONE + '"'
CLUSTER_URL = "${cluster:queryparam}"

NODES = f'object="nodes", host{CL}'
GUESTS = f'object=~"qemu|lxc", nodename{CL}'
STORAGES = f'object="storages", nodename{CL}'
PHYS = 'device=~"(eth|en|wl).*"'              # physical NICs (the dashboards' choice, incl. Wi-Fi)
PVE_PHYS = "(eth[0-9]+|en[^:.]+|ib[^:.]+)"   # pvestatd's own "physical" NIC type (PVE::Network)
GUEST_KEY = "vmid, host, object, nodename, tags"
RATE = "[$__rate_interval]"

# Every dashboard tagged "proxmox" gets a "Proxmox dashboards" dropdown; it carries the
# variables, so cluster/node/guest stick.
PVE_LINK = {"type": "dashboards", "tags": ["proxmox"], "asDropdown": True, "title": "Proxmox dashboards",
            "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
            "tooltip": "", "url": ""}

CPU, MEM, SWAP, WAIT = "blue", "purple", "orange", "orange"
NET_IN, NET_OUT = ACCENT2, ACCENT  # directions, not states (like custom.READ/WRITE)
# Panels with a series per node of the lylat cluster color them by node (in legend order); a node
# not listed here (greatfox, a new one) keeps the in/out colors.
CLUSTER_NODES = ("eldarad", "fichina", "fortuna", "macbeth", "titania", "venom", "zoness")
DASHED = {"fill": "dash", "dash": [10, 10]}
FRACTION = steps(("green", None), ("orange", 0.75), ("red", 0.9))
LOAD = steps(("green", None), ("orange", 0.8), ("red", 1.5))
RUNNING_MAP = mapping(**{"1": ("running", "green"), "0": ("stopped", "text")})
TYPE_MAP = mapping(qemu=("VM", "blue"), lxc=("CT", "purple"))
SHARED_MAP = mapping(**{"0": ("local", "text"), "1": ("shared", "blue")})
TIME_URL = "${__url_time_range}"
SORT_DESC = {"id": "sortBy", "options": {"fields": {}, "sort": [{"field": "Value", "desc": True}]}}


# --- PromQL ----------------------------------------------------------------------------

def m(name, sel):
    """One pvestatd metric: m("system_cpu", GUESTS) -> pvestatd_system_cpu{object=~"qemu|lxc", ...}."""
    return f"pvestatd_{name}{{{sel}}}"


def last(expr):
    """The newest value in the time range (a node that stopped reporting keeps its last values)."""
    return f"last_over_time({expr}[$__range])"


def rate(expr):
    return f"rate({expr}{RATE})"


def tq(expr):
    return q(expr, table=True)


def cols(*names):
    """Renames for the merged instant tables: Value #A, #B, ... in query order."""
    return {f"Value #{chr(ord('A') + i)}": n for i, n in enumerate(names) if n}


def on_node(expr):
    """Guest series renamed to their node: host = nodename."""
    return f'label_replace({expr}, "host", "$1", "nodename", "(.*)")'


def per_storage(field, sel):
    return f"max by (host, nodename) ({m('system_' + field, sel)})"


def storage_key(expr, sel, shared=None):
    """expr (per host, nodename) per storage: shared ones once ("ceph_rbd"), local ones per node
    ("local (zoness)"), in the label storage. shared: the 0/1 flag per host, nodename to go by."""
    shared = shared or per_storage("shared", sel)
    return (f'max by (storage) ('
            f'label_replace(max by (host) (({expr}) and on (host, nodename) ({shared} == 1)), "storage", "$1", "host", "(.*)")'
            f' or label_replace(label_join(({expr}) and on (host, nodename) ({shared} == 0), "storage", " (", "host", '
            f'"nodename"), "storage", "$1)", "storage", "(.+)"))')


def storage_pct(sel):
    return f"{per_storage('used', sel)} / ({per_storage('total', sel)} > 0)"


def bars(title, targets, **kw):
    """A bar per row of an instant table, largest first; the row's string column names the bar."""
    p = bargauge(title, targets, **kw)
    p["options"]["reduceOptions"] = {"values": True, "calcs": ["lastNotNull"], "fields": "/^Value$/", "limit": 50}
    p["transformations"] = [*p.get("transformations", []), SORT_DESC]
    return p


def field_links(p, *links):
    """Data links on the values (they can use ${__field.labels.x} / ${__data.fields.x})."""
    p["fieldConfig"]["defaults"]["links"] = [{"title": t, "url": u, "targetBlank": False} for t, u in links]
    return p


def gauge_cell(*names, unit="percentunit", thresholds=FRACTION):
    return [override(n, {"unit": unit, "min": 0, "max": 1 if unit == "percentunit" else 100, "decimals": 1,
                         "thresholds": thresholds,
                         "custom.cellOptions": {"type": "gauge", "mode": "basic", "valueDisplayMode": "text"}})
            for n in names]


def net_overrides(rx="in", tx="out"):
    """Inbound above the axis, outbound mirrored below it.

    Override regexes use the /pattern/flags form: JavaScript has no inline (?i), and Grafana silently
    drops a matcher whose regex doesn't compile."""
    return [override(f"/.*\\b{rx}$/i", {"color": {"mode": "fixed", "fixedColor": NET_IN}}, regex=True),
            override(f"/.*\\b{tx}$/i", {"color": {"mode": "fixed", "fixedColor": NET_OUT},
                                          "custom.transform": "negative-Y"}, regex=True)]


def rw_overrides():
    return [override("/.*\\bread$/i", {"color": {"mode": "fixed", "fixedColor": READ}}, regex=True),
            override("/.*\\bwrite$/i", {"color": {"mode": "fixed", "fixedColor": WRITE},
                                          "custom.transform": "negative-Y"}, regex=True)]


def node_link(field="host"):
    return {"title": "Proxmox node",
            "url": PVE_NODE_DASH + "?" + CLUSTER_URL + "&var-node=${__data.fields." + field + "}&" + TIME_URL}


def guest_link():
    return {"title": "Proxmox guest",
            "url": GUEST_DASH + "?" + CLUSTER_URL + "&var-guest=${__data.fields.vmid}&" + TIME_URL}


# --- Variables -----------------------------------------------------------------------

def cluster_var():
    options = [{"text": t, "value": v, "selected": i == 0} for i, (t, v) in enumerate(CLUSTERS)]
    return {"name": "cluster", "label": "Cluster", "type": "custom", "hide": 0,
            "query": ",".join(f"{t} : {v}" for t, v in CLUSTERS),
            "description": "The lylat cluster (every node but greatfox) or the standalone greatfox.",
            "multi": False, "includeAll": False, "options": options,
            "current": {"text": CLUSTERS[0][0], "value": CLUSTERS[0][1], "selected": True}}


def node_var(multi=False):
    return query_var("node", "Node", f"label_values({m('cpustat_cpus', NODES)}, host)",
                     multi=multi, include_all=multi)


def guest_var():
    # "dns01 (5301)" as the text, the vmid as the value (names aren't unique: greatfox has two
    # arch-6800xt-nvme). query_result is an instant query: the guests reported at the end of the range.
    v = query_var("guest", "Guest", "query_result(label_replace(label_join(max by (vmid, host) ("
                  + m("system_uptime", GUESTS + ', nodename=~"$node"')
                  + '), "label", " (", "host", "vmid"), "label", "$1)", "label", "(.+)"))',
                  multi=False, include_all=False)
    v["regex"] = '/label="(?<text>[^"]+)".*vmid="(?<value>[^"]+)"/'
    return v


def storage_var():
    return query_var("storage", "Storage", f"label_values({m('system_total', STORAGES)}, host)")


# --- Shared queries ------------------------------------------------------------------

NODE_COLUMNS = ["Node", "State", "Uptime", "CPU", "Cores", "Load 5m / core", "IO wait", "Memory", "RAM", "Swap",
                "Root FS", "Guests running", "Guests", "Net in", "Net out"]


def node_table_targets(sel=NODES, guests=GUESTS):
    """One row per node: last values in the time range; State = reported in the last minute of it."""
    def by(e):
        return f"max by (host) ({e})"

    def lv(field):
        return last(m(field, sel))

    avg1 = m("cpustat_avg1", sel)
    running = on_node(m("system_running", guests))
    return [
        tq(f"{by(f'present_over_time({avg1}[1m])')} or {by(last(avg1))} * 0"),
        tq(by(lv("system_uptime"))),
        tq(by(lv("cpustat_cpu"))),
        tq(by(lv("cpustat_cpus"))),
        tq(by(f"{lv('cpustat_avg5')} / {lv('cpustat_cpus')}")),
        tq(by(lv("cpustat_wait"))),
        tq(by(f"{lv('memory_memused')} / {lv('memory_memtotal')}")),
        tq(by(lv("memory_memtotal"))),
        tq(by(f"{lv('memory_swapused')} / clamp_min({lv('memory_swaptotal')}, 1)")),
        tq(by(f"{lv('blockstat_per')} / 100")),
        tq(f"sum by (host) ({running})"),
        tq(f"count by (host) ({running})"),
        tq(f"sum by (host) ({rate(m('nics_receive', sel + ', ' + PHYS))}) * 8"),
        tq(f"sum by (host) ({rate(m('nics_transmit', sel + ', ' + PHYS))}) * 8"),
    ]


def guest_count_targets(sel=GUESTS, templates=True):
    """Running VMs and CTs, stopped guests (templates left out) and templates, now."""
    def running(obj):
        return f'count({m("system_running", sel + ", object=" + chr(34) + obj + chr(34))} == 1) or vector(0)'

    t = [q(running("qemu"), "vms", instant=True), q(running("lxc"), "cts", instant=True),
         q(f"count({m('system_running', sel)} == 0 unless on (object, vmid, nodename) "
           f"{m('system_template', sel)}) or vector(0)", "stopped", instant=True)]
    if templates:
        t.append(q(f"count({m('system_template', sel)}) or vector(0)", "templates", instant=True))
    return t


GUEST_COUNT_OVERRIDES = [
    override("vms", {"displayName": "VMs running", "color": {"mode": "fixed", "fixedColor": "green"}}),
    override("cts", {"displayName": "CTs running", "color": {"mode": "fixed", "fixedColor": "green"}}),
    override("stopped", {"displayName": "Stopped", "color": {"mode": "fixed", "fixedColor": "text"}}),
    override("templates", {"displayName": "Templates", "color": {"mode": "fixed", "fixedColor": "blue"}}),
]


def nodes_up_targets(sel=NODES):
    x = m("cpustat_avg1", sel)
    return [q(f"count(present_over_time({x}[1m])) or vector(0)", "up", instant=True),
            q(f"count(present_over_time({x}[$__range]) unless present_over_time({x}[1m])) or vector(0)", "down",
              instant=True)]


NODES_UP_OVERRIDES = [override("up", {"displayName": "Up", "color": {"mode": "fixed", "fixedColor": "green"}}),
                      override("down", {"displayName": "Down", "thresholds": RED_IF_ANY})]


def weighted_cpu(sel=NODES):
    """CPU over all selected nodes, weighted by their cores."""
    return q(f"sum({m('cpustat_cpu', sel)} * {m('cpustat_cpus', sel)}) / sum({m('cpustat_cpus', sel)})", "CPU")


def weighted_mem(sel=NODES):
    return q(f"sum({m('memory_memused', sel)}) / sum({m('memory_memtotal', sel)})", "Memory")


def storage_bars(sel=STORAGES, title="Storage used"):
    return bars(title, [tq(storage_key(storage_pct(sel), sel))], unit="percentunit", min_=0, max_=1,
                thresholds=FILL, bar_height=20, mode="gradient",
                desc="Used / total. Shared storages once, local ones per node.",
                links=[("Proxmox storage", STORAGE_DASH + "?" + CLUSTER_URL + "&" + TIME_URL)])


def storage_series(expr_of, sel=STORAGES):
    """Storage series over time, shared storages once (they report the same from every node)."""
    return q(storage_key(expr_of(sel), sel), "{{storage}}")


# --- Proxmox overview -------------------------------------------------------------------

def overview():
    b = Board()
    b.row("Cluster")
    b.add(stat("Nodes", nodes_up_targets(), text_mode="value_and_name", color_mode="value",
               overrides=NODES_UP_OVERRIDES,
               desc="Nodes that reported within the last minute of the time range (Up) and nodes "
                    "seen earlier in the range that stopped reporting (Down)."), 4, 5)
    b.add(stat("Guests", guest_count_targets(), text_mode="value_and_name", color_mode="value",
               overrides=GUEST_COUNT_OVERRIDES,
               desc="Running VMs and containers, stopped guests (templates not counted) and templates.",
               links=[("Proxmox guests", GUEST_DASH + "?" + CLUSTER_URL + "&" + TIME_URL)]), 7, 5)
    b.add(stat("CPU", [weighted_cpu()], unit="percentunit", decimals=1, color_mode="value", graph=True,
               thresholds=FRACTION, desc="Busy share of all node cores (pvestatd's cpu, weighted by cores)."), 3, 5)
    b.add(stat("Memory", [weighted_mem()], unit="percentunit", decimals=1, color_mode="value", graph=True,
               thresholds=FRACTION, desc="Used / total memory over all nodes (used = total - available)."), 3, 5)
    up = f"{m('system_uptime', GUESTS)} > 0"
    b.add(stat("Allocated to running guests", [
        q(f"sum({m('system_cpus', GUESTS)} and {up}) / sum({m('cpustat_cpus', NODES)})", "vCPUs", instant=True),
        q(f"sum({m('system_maxmem', GUESTS)} and {up}) / sum({m('memory_memtotal', NODES)})", "memory",
          instant=True)],
        text_mode="value_and_name", color_mode="value", decimals=2,
        overrides=[override("vCPUs", {"unit": "x", "displayName": "vCPUs / cores",
                                      "thresholds": steps(("green", None), ("orange", 2), ("red", 4))}),
                   override("memory", {"unit": "percentunit", "decimals": 0, "displayName": "Memory / RAM",
                                       "thresholds": steps(("green", None), ("orange", 0.8), ("red", 1))})],
        desc="vCPUs and configured memory of the running guests, against the nodes' cores and RAM. "
             "Above 1x vCPUs is normal overcommit; memory near 100% leaves no room for an HA failover."), 7, 5)

    b.row("Nodes")
    b.add(table("Nodes", node_table_targets(),
                desc="Last values in the time range. State is DOWN when the node stopped reporting. "
                     "Network is the current rate summed over the physical NICs. Click a node for its dashboard.",
                transformations=[MERGE, organize(exclude=["Time"], rename={"host": "Node", **cols(*NODE_COLUMNS[1:])},
                                                 order=NODE_COLUMNS)],
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
    b.add(timeseries("CPU per node", [q(m("cpustat_cpu", NODES), "{{host}}")], unit="percentunit", fill=0, min_=0,
                     calcs=("mean", "max", "lastNotNull")), 8, 8)
    b.add(timeseries("Memory per node", [q(f"{m('memory_memused', NODES)} / {m('memory_memtotal', NODES)}", "{{host}}")],
                     unit="percentunit", fill=0, min_=0, max_=1, calcs=("mean", "max", "lastNotNull"),
                     desc="Used = total - available."), 8, 8)
    b.add(timeseries("Load (5m) per core", [q(f"{m('cpustat_avg5', NODES)} / {m('cpustat_cpus', NODES)}", "{{host}}")],
                     fill=0, min_=0, decimals=2, calcs=("mean", "max", "lastNotNull"),
                     desc="5-minute load average divided by the node's cores; above 1 means runnable tasks are waiting."),
          8, 8)
    b.add(timeseries("Network per node (physical NICs)", [
        q(f"sum by (host) ({rate(m('nics_receive', NODES + ', ' + PHYS))}) * 8", "{{host}} in"),
        q(f"sum by (host) ({rate(m('nics_transmit', NODES + ', ' + PHYS))}) * 8", "{{host}} out")],
        unit="bps", fill=10, calcs=("mean", "max"),
        overrides=[*net_overrides(),
                   override("/.*\\bout$/i", {"custom.lineStyle": DASHED}, regex=True),
                   *[override(f"/^{n} (in|out)$/", {"color": {"mode": "fixed", "fixedColor": c}}, regex=True)
                     for n, c in zip(CLUSTER_NODES, SERIES)]],
        desc="Summed over each node's physical NICs (bond members and uplinks); one color per node, inbound "
             "up (solid), outbound down (dashed)."), 12, 9)
    b.add(timeseries("IO wait per node", [q(m("cpustat_wait", NODES), "{{host}}")], unit="percentunit", fill=0,
                     min_=0, calcs=("mean", "max", "lastNotNull"), desc="Share of CPU time spent waiting for I/O."),
          12, 9)

    b.row("Guests")
    guest_links = [("Proxmox guests", GUEST_DASH + "?" + CLUSTER_URL + "&" + TIME_URL)]

    def top(title, value, unit, desc, rate_=False, **kw):
        if rate_:  # only guests moving data now are listed, so a quiet host has none
            kw.setdefault("no_value", "idle")
        p = bars(title, [tq(f"topk(10, max by (host, vmid) ({value}) > 0)")], unit=unit, desc=desc,
                 links=guest_links, bar_height=18, transformations=[organize(exclude=["vmid"])], **kw)
        return p

    g = GUESTS
    b.add(top("Top guests by CPU", m("system_cpu", g), "percentunit", "Share of each guest's own vCPUs in use.",
              min_=0, max_=1, thresholds=FRACTION), 6, 9)
    b.add(top("Top guests by memory", f"{m('system_memhost', g)} or {m('system_mem', g)}", "bytes",
              "Host memory used by the guest (memhost for VMs, mem for containers).",
              thresholds=steps(("purple", None)), min_=0), 6, 9)
    b.add(top("Top guests by disk I/O", f"{rate(m('system_diskread', g))} + {rate(m('system_diskwrite', g))}", "Bps",
              "Read + write throughput, now.", rate_=True, thresholds=steps(("blue", None)), min_=0), 6, 9)
    b.add(top("Top guests by network", f"({rate(m('system_netin', g))} + {rate(m('system_netout', g))}) * 8", "bps",
              "In + out, now.", rate_=True, thresholds=steps(("green", None)), min_=0), 6, 9)
    b.add(timeseries("Running guests", [
        q(f'count({m("system_running", g + ", object=" + chr(34) + "qemu" + chr(34))} == 1) or vector(0)', "VMs"),
        q(f'count({m("system_running", g + ", object=" + chr(34) + "lxc" + chr(34))} == 1) or vector(0)', "CTs")],
        stack=True, fill=40, decimals=0, step=True, calcs=("min", "max", "lastNotNull"),
        overrides=[fixed_color("VMs", "blue"), fixed_color("CTs", "purple")]), 12, 8)
    b.add(timeseries("Guest CPU by node (cores)", [
        q(f"sum by (nodename) ({m('system_cpu', g)} * {m('system_cpus', g)})", "{{nodename}}")],
        stack=True, fill=40, decimals=2, calcs=("mean", "max"), desc="Cores busy running guests, per node."), 12, 8)

    b.row("Storage")
    b.add(storage_bars(), 10, 9)
    b.add(timeseries("Storage used over time", [storage_series(storage_pct)],
                     unit="percentunit", fill=0, min_=0, calcs=("min", "max", "lastNotNull"),
                     desc="Used / total per storage."), 14, 9)
    return finish(dashboard("proxmox-overview", "Proxmox overview",
                            "The PVE nodes, guests and storages at a glance, from pvestatd's stats in Prometheus.",
                            b, tags=["proxmox"], variables=[cluster_var()], extra_links=[PVE_LINK]))


# --- Guest tables (node and guest dashboards) ------------------------------------------

GUEST_VALUES = ["Status", "Uptime", "vCPUs", "CPU", "Memory", "Configured", "Memory %", "Disk size", "Disk read",
                "Disk write", "Net in", "Net out"]


def guest_table(sel, with_node=False):
    """One row per guest: state, CPU, memory, I/O rates, now. sel selects the guests."""
    def by(e):
        return tq(f"max by ({GUEST_KEY}) ({e})")

    used = f"({m('system_memhost', sel)} or {m('system_mem', sel)})"
    targets = [by(m("system_running", sel)), by(m("system_uptime", sel)), by(m("system_cpus", sel)),
               by(m("system_cpu", sel)), by(used), by(m("system_maxmem", sel)),
               by(f"{used} / ({m('system_maxmem', sel)} > 0)"), by(m("system_maxdisk", sel)),
               by(rate(m("system_diskread", sel))), by(rate(m("system_diskwrite", sel))),
               by(f"{rate(m('system_netin', sel))} * 8"), by(f"{rate(m('system_netout', sel))} * 8")]
    order = ["Name", "VMID", "Type", *(["Node"] if with_node else []), "Status", "Uptime", "vCPUs", "CPU",
             "Memory", "Configured", "Memory %", "Disk size", "Disk read", "Disk write", "Net in", "Net out", "Tags"]
    exclude = ["Time"] + ([] if with_node else ["nodename"])
    return table("Guests", targets,
                 desc="Now (end of the time range). Memory is what the guest uses on the host (VM: memhost, "
                      "CT: mem); Configured is its maximum. CPU is the share of its own vCPUs. "
                      "Click a name for the guest's dashboard.",
                 transformations=[MERGE, organize(exclude=exclude, rename={
                     "host": "Name", "vmid": "VMID", "object": "Type", "nodename": "Node", "tags": "Tags",
                     **cols(*GUEST_VALUES)}, order=order)],
                 overrides=[cell("Status", "color-text"), override("Status", {"mappings": RUNNING_MAP}),
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


def guest_stack(title, expr, unit, desc):
    return timeseries(title, [q(f"max by (host, vmid) ({expr}) > 0", "{{host}}")],
                      unit=unit, stack=True, fill=30, calcs=("mean", "max", "lastNotNull"), desc=desc)


# --- Proxmox node ---------------------------------------------------------------------------

def node():
    b = Board()
    n = 'object="nodes", host="$node"'
    on = 'object=~"qemu|lxc", nodename="$node"'
    on_storage = 'object="storages", nodename="$node"'

    def lv(field, sel=n):
        return f"max({last(m(field, sel))})"

    def now(expr, legend="__auto"):
        return q(expr, legend, instant=True)

    b.row("Summary")
    avg1 = m("cpustat_avg1", n)
    b.col(3,
          (stat("State", [now(f"max(present_over_time({avg1}[1m])) or max({last(avg1)}) * 0")],
                mappings=UP_MAP, thresholds=UP_STEPS, no_value="no data",
                desc="UP if the node reported within the last minute of the time range."), 4),
          (stat("Uptime", [now(lv("system_uptime"))], unit="dtdurations", color_mode="value", thresholds=BLUE,
                decimals=1), 4))
    b.add(gauge("CPU", [now(lv("cpustat_cpu"))], unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Busy share of all cores."), 3, 8)
    b.add(gauge("Memory", [now(f"max({last(m('memory_memused', n))} / {last(m('memory_memtotal', n))})")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Used = total - available."), 3, 8)
    b.add(gauge("Swap", [now(f"max({last(m('memory_swapused', n))} / clamp_min({last(m('memory_swaptotal', n))}, 1))")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION), 3, 8)
    b.add(gauge("Root FS", [now(f"{lv('blockstat_per')} / 100")],
                unit="percentunit", min_=0, max_=1, decimals=0, thresholds=FILL,
                desc="The node's root filesystem (local storage lives on it)."), 3, 8)
    b.add(stat("Load / core", [now(f"max({last(m('cpustat_' + k, n))} / {last(m('cpustat_cpus', n))})", f"_{k[3:]}m")
                               for k in ("avg1", "avg5", "avg15")],
               text_mode="value_and_name", color_mode="value", decimals=2, thresholds=LOAD, orientation="vertical",
               overrides=[override("_1m", {"displayName": "1m"}), override("_5m", {"displayName": "5m"}),
                          override("_15m", {"displayName": "15m"})],
               desc="Load averages divided by the cores; above 1 means tasks wait for a CPU."), 3, 8)
    b.add(stat("Guests", guest_count_targets(sel=on), text_mode="value_and_name", color_mode="value",
               overrides=GUEST_COUNT_OVERRIDES, orientation="vertical",
               desc="On this node now: running VMs and CTs, stopped guests (templates not counted), templates."), 3, 8)
    hw = stat("Hardware", [now(lv(f), name) for f, name in (("cpustat_cpus", "cpus"), ("memory_memtotal", "memtotal"),
                                                             ("memory_swaptotal", "swaptotal"),
                                                             ("blockstat_blocks", "blocks"))],
              text_mode="value_and_name", color_mode="value", thresholds=BLUE, text_size=(11, 16),
              overrides=[override("cpus", {"displayName": "Cores", "unit": "short"}),
                         override("memtotal", {"displayName": "RAM", "unit": "bytes", "decimals": 0}),
                         override("swaptotal", {"displayName": "Swap", "unit": "bytes", "decimals": 0}),
                         override("blocks", {"displayName": "Root FS", "unit": "bytes", "decimals": 0})])
    exporter = stat("node_exporter", [q('max by (instance) (up{job="node", host="$node"})', "{{instance}}")],
                    mappings=UP_MAP, thresholds=UP_STEPS,
                    no_value="not scraped",
                    desc="Prometheus node_exporter on this node; click for Node Exporter Full (hardware, disks, "
                         "temperatures).")
    field_links(exporter, ("Node Exporter Full",
                           NODE_DASH + "?var-job=node&var-node=${__field.labels.instance}&" + TIME_URL))
    b.col(4, (hw, 5), (exporter, 3))

    b.row("CPU and load")
    b.add(timeseries("CPU", [q(m("cpustat_cpu", n), "busy"), q(m("cpustat_wait", n), "IO wait")],
                     unit="percentunit", min_=0, fill=20, gradient="opacity",
                     overrides=[fixed_color("busy", CPU), fixed_color("IO wait", WAIT)],
                     desc="Busy share of all cores, and the share spent waiting for I/O."), 12, 8)
    b.add(timeseries("Load average", [*[q(m(f"cpustat_avg{k}", n), f"{k}m") for k in (1, 5, 15)],
                                      q(m("cpustat_cpus", n), "cores")],
                     fill=0, min_=0, decimals=2,
                     overrides=[override("cores", {"color": {"mode": "fixed", "fixedColor": "red"},
                                                   "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})],
                     desc="1, 5 and 15 minute load averages; the dashed line is the node's core count."), 12, 8)

    b.row("Memory and disk")
    b.add(timeseries("Memory", [q(m("memory_memused", n), "used"), q(m("memory_memavailable", n), "available"),
                                q(f"{m('memory_arcsize', n)} > 1048576", "ZFS ARC")],
                     unit="bytes", stack=True, fill=30,
                     overrides=[fixed_color("used", MEM), fixed_color("available", "green"),
                                override("ZFS ARC", {"custom.stacking": {"mode": "none", "group": "A"},
                                                     "custom.fillOpacity": 0,
                                                     "color": {"mode": "fixed", "fixedColor": "orange"}})],
                     desc="Used (total - available) and available stack up to the total. ZFS ARC shows only on "
                          "nodes with ZFS."), 12, 8)
    b.add(timeseries("Swap", [q(m("memory_swapused", n), "used"), q(m("memory_swaptotal", n), "total")],
                     unit="bytes", fill=20, overrides=[fixed_color("used", SWAP),
                                                       override("total", {"custom.fillOpacity": 0,
                                                                          "color": {"mode": "fixed", "fixedColor": "text"},
                                                                          "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})]),
          6, 8)
    b.add(timeseries("Root filesystem", [q(f"{m('blockstat_per', n)} / 100", "used")],
                     unit="percentunit", min_=0, max_=1, fill=20, gradient="opacity", thresholds=FILL,
                     color={"mode": "thresholds"}, desc="Used share of /, as df reports it."), 6, 8)

    b.row("Network")
    for title, regex, desc in (
            ("Physical NICs", "(eth|en|wl).*", "Every physical NIC; inbound up, outbound down."),
            ("Bridges and bonds", "(vmbr|bond).*", "Linux bridges (guest traffic and VLANs) and bonds.")):
        sel = f'{n}, device=~"{regex}"'
        b.add(timeseries(title, [q(f"{rate(m('nics_receive', sel))} * 8", "{{device}} in"),
                                 q(f"{rate(m('nics_transmit', sel))} * 8", "{{device}} out")],
                         unit="bps", fill=10, overrides=net_overrides(), calcs=("mean", "max"), desc=desc), 12, 9)
    nic_sel = f'{n}, device!~"(tap|veth|fwbr|fwpr|fwln).*|lo"'

    def nic(expr):
        # pvestatd's NIC type string isn't exported: the same rule as PVE (physical_nic_regex), as a label.
        typed = f'label_replace(label_replace({expr}, "type", "virtual", "device", ".*"), "type", "physical", "device", "{PVE_PHYS}")'
        return tq(f"max by (device, type) ({typed})")

    b.add(table("Interfaces", [
        nic(f"{rate(m('nics_receive', nic_sel))} * 8"), nic(f"{rate(m('nics_transmit', nic_sel))} * 8"),
        nic(m("nics_receive", nic_sel)), nic(m("nics_transmit", nic_sel)),
    ], desc="Physical NICs, bonds, bridges and VLAN interfaces (guest tap/veth and firewall bridges left out). "
            "Totals are bytes since the node booted. Type follows PVE's rule for physical NIC names.",
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "device": "Interface", "type": "Type", **cols("In", "Out", "Received", "Sent")},
            order=["Interface", "Type", "In", "Out", "Received", "Sent"])],
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
    b.add(guest_stack("Guest CPU (cores)", f"{m('system_cpu', on)} * {m('system_cpus', on)}", "short",
                      "Cores each guest keeps busy (CPU share x vCPUs), stacked."), 12, 9)
    b.add(guest_stack("Guest memory (host)", f"{m('system_memhost', on)} or {m('system_mem', on)}", "bytes",
                      "Host memory each guest uses (VM: memhost, CT: mem), stacked."), 12, 9)
    b.add(guest_stack("Guest disk I/O", f"{rate(m('system_diskread', on))} + {rate(m('system_diskwrite', on))}",
                      "Bps", "Read + write per guest, stacked."), 12, 8)
    b.add(guest_stack("Guest network", f"({rate(m('system_netin', on))} + {rate(m('system_netout', on))}) * 8",
                      "bps", "In + out per guest, stacked."), 12, 8)

    b.row("Storages on ${node}")
    b.add(storage_bars(on_storage, "Storage used"), 8, 9)
    b.add(storage_table(on_storage), 16, 9)

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
                            b, tags=["proxmox"], variables=[cluster_var(), node_var()], extra_links=[PVE_LINK, {
                                "type": "link", "title": "Logs of this node", "icon": "doc", "tags": [], "tooltip": "",
                                "url": "/d/logs-proxmox/logs-proxmox?var-node=${node}", "includeVars": False,
                                "keepTime": True, "asDropdown": False, "targetBlank": False}]))


STORAGE_COLUMNS = ["Used", "Available", "Total", "Used %", "Shared", "Active", "Enabled", "Growth / day", "Full in"]


def storage_info(sel):
    """One series per storage carrying its node ("all" for shared ones), type, content and the link
    target: Ceph storages open the Ceph cluster dashboard, shared ones the storage dashboard, local
    ones their node."""
    total = f"topk by (host, nodename) (1, {m('system_total', sel)})"  # one content order per storage
    shared = per_storage("shared", sel)

    def ceph(e):
        return f'label_replace({e}, "link", "{CEPH_DASH}?orgId=1", "type", "rbd|cephfs")'

    one = (f'label_replace(label_replace(topk by (host) (1, {total} and on (host, nodename) ({shared} == 1)), '
           f'"storage", "$1", "host", "(.*)"), "node", "all", "host", ".*")')
    one = ceph(f'label_replace({one}, "link", "{STORAGE_DASH}?var-storage=$1", "host", "(.*)")')
    local = (f'label_replace(label_replace(label_join({total} and on (host, nodename) ({shared} == 0), "storage", " (", '
             f'"host", "nodename"), "storage", "$1)", "storage", "(.+)"), "node", "$1", "nodename", "(.*)")')
    local = ceph(f'label_replace({local}, "link", "{PVE_NODE_DASH}?var-node=$1", "nodename", "(.*)")')
    return f"max by (storage, node, type, content, link) ({one} or {local})"


def storage_table(sel=STORAGES, title="Storages"):
    """Storages now, with growth over the time range and when they'd be full at that rate."""
    used, avail = per_storage("used", sel), per_storage("avail", sel)
    growth = f"delta(({used})[$__range:5m]) / $__range_s"  # bytes per second over the time range
    values = [used, avail, per_storage("total", sel), storage_pct(sel), per_storage("shared", sel),
              per_storage("active", sel), per_storage("enabled", sel), f"{growth} * 86400",
              f"({avail} / (({growth}) > 0)) or ({avail} * 0 - 1)"]
    p = table(title, [tq(storage_info(sel)), *[tq(storage_key(v, sel)) for v in values]],
              desc="Now, shared storages once. Growth is the change of used space over the time range, per day; "
                   "Full in extrapolates it (\"not filling up\" when not growing). Click a storage: Ceph storages open the "
                   "Ceph cluster dashboard, local ones their node.",
              transformations=[MERGE, organize(exclude=["Time", "Value #A"], rename={
                  "storage": "Storage", "node": "Node", "type": "Type", "content": "Content",
                  **cols(None, *STORAGE_COLUMNS)},
                  order=["Storage", "Node", "Type", "Shared", "Content", "Used", "Available", "Total", "Used %",
                         "Growth / day", "Full in", "Active", "Enabled", "link"])],
              overrides=[*hidden("link", "Active", "Enabled"),
                         override("Storage", {"links": [{"title": "${__data.fields.Storage}",
                                                         "url": "${__data.fields.link}&" + CLUSTER_URL + "&" + TIME_URL}]}),
                         cell("Shared", "color-text"), override("Shared", {"mappings": SHARED_MAP}),
                         override("Used", {"unit": "bytes"}), override("Available", {"unit": "bytes"}),
                         override("Total", {"unit": "bytes"}),
                         *gauge_cell("Used %", thresholds=FILL),
                         override("Growth / day", {"unit": "bytes", "decimals": 1}),
                         override("Full in", {"unit": "dtdurations",
                                              "mappings": [{"type": "range", "options": {"from": -1e18, "to": 0,
                                                                                         "result": {"text": "not filling up", "color": "green", "index": 0}}}],
                                              "thresholds": steps(("red", None), ("orange", 7 * 86400), ("green", 30 * 86400)),
                                              "custom.cellOptions": {"type": "color-text"}})],
              sort="Used %", desc_sort=True)
    return p


# --- Proxmox guests -----------------------------------------------------------------------

# Empty by design: VM-only panels on a container or a stopped VM, balloon panels without a balloon driver.
VM_ONLY = "running VMs only"
NO_BALLOON = "no balloon driver data"


def guests():
    b = Board()
    g = f'vmid="$guest", nodename{CL}'

    def gm(field, extra=""):
        return m(field, g + extra)

    def now(expr, legend="__auto"):
        return q(expr, legend, instant=True)

    b.row("All guests")
    b.add(guest_table(GUESTS + ', nodename=~"$node"', with_node=True), 24, 10)

    b.row("Guest ${guest:text}")
    b.add(stat("Status", [now(f"max({gm('system_running')})")], mappings=RUNNING_MAP, color_mode="value",
               text_size=(12, 22), desc="running, or stopped (PVE's other states: paused, prelaunch, suspended, "
                                        "also read stopped here)."), 3, 4)
    b.add(stat("Type", [now(f"(count({gm('system_uptime', ', object=' + chr(34) + 'qemu' + chr(34))}) * 1) or "
                            f"(count({gm('system_uptime', ', object=' + chr(34) + 'lxc' + chr(34))}) * 2)")],
               mappings=mapping(**{"1": ("VM", "blue"), "2": ("CT", "purple")}), color_mode="value",
               text_size=(12, 22)), 2, 4)
    node_stat = stat("Node", [now(f"max by (nodename) ({gm('system_uptime')})", "{{nodename}}")], text_mode="name",
                     color_mode="value", thresholds=BLUE, text_size=(12, 22),
                     desc="The node the guest runs on. Click for its dashboard.")
    field_links(node_stat, ("Proxmox node", PVE_NODE_DASH + "?" + CLUSTER_URL + "&var-node=${__field.labels.nodename}&"
                            + TIME_URL))
    b.add(node_stat, 3, 4)
    b.add(stat("Uptime", [now(f"max({gm('system_uptime')})")], unit="dtdurations", decimals=1, color_mode="value",
               thresholds=steps(("orange", None), ("green", 3600)), mappings=mapping(**{"0": ("not running", "text")}),
               text_size=(12, 22)), 3, 4)
    b.add(stat("vCPUs", [now(f"max({gm('system_cpus')})")], color_mode="value", thresholds=BLUE,
               text_size=(12, 22)), 2, 4)
    b.add(stat("Memory", [now(f"max({gm('system_maxmem')})")], unit="bytes", decimals=0, color_mode="value",
               thresholds=BLUE, text_size=(12, 22), desc="Configured memory."), 3, 4)
    b.add(stat("Disk size", [now(f"max({gm('system_maxdisk')})")], unit="bytes", decimals=0, color_mode="value",
               thresholds=BLUE, text_size=(12, 22), desc="Size of the boot disk (CT: root filesystem)."), 3, 4)
    tags = f"max by (tags) ({gm('system_uptime', ', tags!=' + chr(34) + chr(34))})"
    for _ in range(6):  # "a;b;c" -> "a · b · c" (one separator per pass, up to 7 tags)
        tags = f'label_replace({tags}, "tags", "$1 · $2", "tags", "(.*);(.*)")'
    b.add(stat("Tags", [now(tags, "{{tags}}")], text_mode="name", color_mode="value",
               thresholds=steps(("text", None)), text_size=(12, 16), no_value="none"), 5, 4)

    b.add(gauge("CPU", [now(f"max({gm('system_cpu')})")], unit="percentunit", min_=0, max_=1, decimals=1,
                thresholds=FRACTION, desc="Share of the guest's vCPUs in use."), 4, 7)
    b.add(gauge("Memory used", [now(f"max(({gm('system_memhost')} or {gm('system_mem')}) / {gm('system_maxmem')})")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FRACTION,
                desc="Host memory the guest uses (VM: memhost, CT: mem) / configured memory. VMs with PCI "
                     "passthrough pin all their memory, so they sit at 100%."), 4, 7)
    b.add(gauge("Balloon", [now(f"max({gm('ballooninfo_actual')} / {gm('ballooninfo_max_mem')})")],
                unit="percentunit", min_=0, max_=1, decimals=0, thresholds=steps(("orange", None), ("green", 0.999)),
                no_value="no balloon",
                desc="VMs with the balloon driver: current balloon size / maximum. Below 100% means PVE took "
                     "memory back from the guest."), 4, 7)
    lxc = ', object="lxc"'
    b.add(gauge("Root disk (CT)", [now(f"max({gm('system_disk', lxc)} / {gm('system_maxdisk', lxc)})")],
                unit="percentunit", min_=0, max_=1, decimals=1, thresholds=FILL, no_value="n/a",
                desc="Containers only: used / size of the root filesystem. PVE doesn't know how full a VM's "
                     "disk is (always 0)."), 4, 7)
    # The QEMU version/machine panel is gone: pvestatd sends them as strings, which aren't exported.
    b.add(stat("Pressure (avg10)", [now(f"max({gm('system_pressure' + k + 'some')})", k)
                                    for k in ("cpu", "io", "memory")],
               unit="percent", decimals=1, text_mode="value_and_name", color_mode="value", orientation="vertical",
               thresholds=steps(("green", None), ("orange", 10), ("red", 40)),
               desc="Pressure stall information of the guest's cgroup: share of time some task waited for "
                    "CPU, I/O or memory (10 s average)."), 8, 7)

    b.row("CPU and memory")
    b.add(timeseries("CPU", [q(gm("system_cpu"), "CPU")], unit="percentunit", min_=0, fill=20, gradient="opacity",
                     overrides=[fixed_color("CPU", CPU)], desc="Share of the guest's vCPUs in use."), 8, 8)
    b.add(timeseries("Memory", [q(gm("system_memhost"), "host"), q(gm("system_mem"), "used"),
                                q(gm("system_maxmem"), "configured"), q(gm("system_balloon"), "balloon target"),
                                q(gm("system_swap"), "swap")],
                     unit="bytes", fill=10, min_=0,
                     overrides=[fixed_color("used", MEM), fixed_color("host", "blue"), fixed_color("swap", SWAP),
                                override("configured", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "text"},
                                                        "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}}),
                                override("balloon target", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "green"},
                                                            "custom.lineStyle": {"fill": "dash", "dash": [4, 6]}})],
                     desc="used: what the guest reports in use (VM: via the balloon driver, else the same as host); "
                          "host: memory the VM process holds on the node; configured: the maximum; "
                          "balloon target: what PVE asks the balloon to give back to; swap: CT swap."), 8, 8)
    b.add(timeseries("Pressure", [q(gm(f"system_pressure{k}{s}"), f"{k} {s}")
                                  for k in ("cpu", "io", "memory") for s in ("some", "full")],
                     unit="percent", fill=0, min_=0, no_value="not running",
                     overrides=[*[override(f"^{k} ", {"color": {"mode": "fixed", "fixedColor": c}}, regex=True)
                                  for k, c in (("cpu", ACCENT), ("io", ACCENT2), ("memory", ACCENT3))],
                                override(".* full$", {"custom.lineStyle": DASHED}, regex=True)],
                     desc="Pressure stall information (10 s averages): some = at least one task waited, full = all "
                          "tasks waited."), 8, 8)

    b.row("Disk")
    b.add(timeseries("Disk throughput", [q(rate(gm("system_diskread")), "read"), q(rate(gm("system_diskwrite")), "write")],
                     unit="Bps", fill=20, overrides=rw_overrides(), calcs=("mean", "max"), no_value="not running",
                     desc="All disks of the guest; reads up, writes down."), 8, 8)
    b.add(timeseries("IOPS per disk (VM)", [q(rate(gm("blockstat_rd_operations")), "{{device}} read"),
                                            q(rate(gm("blockstat_wr_operations")), "{{device}} write")],
                     unit="iops", fill=10, overrides=rw_overrides(), calcs=("mean", "max"), no_value=VM_ONLY,
                     desc="QEMU block statistics per virtual disk (VMs only)."), 8, 8)

    def latency(kind):
        return q(f"{rate(gm(f'blockstat_{kind}_total_time_ns'))} / ({rate(gm(f'blockstat_{kind}_operations'))} > 0) / 1e9",
                 "{{device}} " + ("read" if kind == "rd" else "write"))

    b.add(timeseries("Latency per disk (VM)", [latency("rd"), latency("wr")], unit="s", fill=0,
                     overrides=[override("/.*read$/i", {"color": {"mode": "fixed", "fixedColor": READ}}, regex=True),
                                override("/.*write$/i", {"color": {"mode": "fixed", "fixedColor": WRITE}}, regex=True)],
                     calcs=("mean", "max"), no_value=VM_ONLY,
                     desc="Average time per completed read and write, per virtual disk."), 8, 8)
    b.add(timeseries("Throughput per disk (VM)", [q(rate(gm("blockstat_rd_bytes")), "{{device}} read"),
                                                  q(rate(gm("blockstat_wr_bytes")), "{{device}} write")],
                     unit="Bps", fill=10, overrides=rw_overrides(), calcs=("mean", "max"), no_value=VM_ONLY), 8, 8)
    b.add(timeseries("Root disk used (CT)", [q(gm("system_disk", lxc), "used"), q(gm("system_maxdisk", lxc), "size")],
                     unit="bytes", fill=20, min_=0, no_value="containers only",
                     overrides=[fixed_color("used", "blue"),
                                override("size", {"custom.fillOpacity": 0, "color": {"mode": "fixed", "fixedColor": "text"},
                                                  "custom.lineStyle": {"fill": "dash", "dash": [10, 10]}})],
                     desc="Containers only; PVE doesn't see inside a VM's disks."), 8, 8)
    errors = '{__name__=~"pvestatd_blockstat_(failed|invalid)_.*", ' + g + "}"
    b.add(stat("I/O errors (VM)", [now(f"sum by (device) ({errors})", "{{device}}")],
               text_mode="value_and_name", thresholds=RED_IF_ANY, decimals=0, no_value="no VM disks",
               desc="Failed and invalid operations per virtual disk since the VM started (should be 0)."), 8, 8)

    b.row("Network")
    b.add(timeseries("Network", [q(f"{rate(gm('system_netin'))} * 8", "in"), q(f"{rate(gm('system_netout'))} * 8", "out")],
                     unit="bps", fill=20, overrides=net_overrides(), calcs=("mean", "max"),
                     desc="All NICs of the guest; inbound up, outbound down."), 12, 8)
    b.add(timeseries("Per NIC (VM)", [q(f"{rate(gm('nics_netin'))} * 8", "{{device}} in"),
                                      q(f"{rate(gm('nics_netout'))} * 8", "{{device}} out")],
                     unit="bps", fill=10, overrides=net_overrides(), calcs=("mean", "max"), no_value=VM_ONLY,
                     desc="Per tap interface (VMs only; container veths are on the node dashboard)."), 12, 8)

    b.row("Balloon and guest memory (VM)", collapsed=True)
    b.add(timeseries("Balloon", [q(gm("ballooninfo_actual"), "balloon size"), q(gm("ballooninfo_max_mem"), "maximum"),
                                 q(gm("ballooninfo_total_mem"), "guest total"), q(gm("ballooninfo_free_mem"), "guest free")],
                     unit="bytes", fill=0, min_=0, no_value=NO_BALLOON,
                     overrides=[fixed_color("balloon size", OK), fixed_color("guest total", INFO),
                                fixed_color("guest free", ACCENT2),
                                override("maximum", {"color": {"mode": "fixed", "fixedColor": TEXT},
                                                     "custom.lineStyle": DASHED})],
                     desc="From the balloon driver: balloon size (memory the guest may use), maximum, and the "
                          "guest's own view of total and free memory."), 8, 8)
    b.add(timeseries("Page faults", [q(rate(gm("ballooninfo_major_page_faults")), "major"),
                                     q(rate(gm("ballooninfo_minor_page_faults")), "minor")],
                     unit="short", fill=0, no_value=NO_BALLOON,
                     overrides=[fixed_color("minor", ACCENT2), fixed_color("major", ACCENT)],
                     desc="Per second, as the guest reports them. Major faults read from disk."), 8, 8)
    b.add(timeseries("Guest swap", [q(rate(gm("ballooninfo_mem_swapped_in")), "in"),
                                    q(rate(gm("ballooninfo_mem_swapped_out")), "out")],
                     unit="Bps", fill=10, overrides=net_overrides(), no_value=NO_BALLOON,
                     desc="Swapped in / out inside the guest."), 8, 8)

    return finish(dashboard("proxmox-guest", "Proxmox guests",
                            "Every VM and container, and one in depth: state, CPU, memory, balloon, pressure, disk and network.",
                            b, tags=["proxmox"], variables=[cluster_var(), node_var(multi=True), guest_var()],
                            extra_links=[PVE_LINK]))


# --- Proxmox storage ------------------------------------------------------------------------

def storage():
    b = Board()
    s = STORAGES + ', host=~"$storage"'
    b.row("Summary")
    b.add(storage_bars(s), 10, 10)
    # pvestatd sends only active storages to the metric server (update_storage_status() skips
    # inactive ones), so "active" is always 1 here. What it can show: storages that reported
    # during the time range and then stopped (went inactive, node down, removed).
    flag = m("system_shared", s)
    seen = f"max by (host, nodename) (last_over_time({flag}[$__range]))"

    def present(window):
        return storage_key(f"max by (host, nodename) (present_over_time({flag}[{window}]))", s, shared=seen)

    b.col(5,
          (stat("Storages", [
              q(f"count({storage_key(storage_pct(s), s)}) or vector(0)", "storages", instant=True),
              q(f"count({present('$__range')} unless on (storage) {present('2m')}) or vector(0)", "quiet", instant=True),
              q(f"max({storage_key(storage_pct(s), s)})", "fullest", instant=True)],
                text_mode="value_and_name", color_mode="value", orientation="vertical",
                overrides=[override("storages", {"displayName": "Storages", "color": {"mode": "fixed", "fixedColor": "blue"}}),
                           override("quiet", {"displayName": "Stopped reporting", "thresholds": RED_IF_ANY}),
                           override("fullest", {"displayName": "Fullest", "unit": "percentunit", "decimals": 1,
                                                "thresholds": FILL})],
                desc="Storages reporting now (shared ones once), the ones that reported earlier in the time range "
                     "but not in the last 2 minutes (went inactive, node down or storage removed), and the fullest "
                     "one. PVE sends only active storages to the metric server, so a storage that was never active "
                     "in the range (an unreachable PBS, say) is not counted: `pvesm status` lists those."), 10))
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
    b.add(timeseries("Used", [storage_series(lambda x: per_storage("used", x), s)], unit="bytes", fill=0, min_=0,
                     calcs=("min", "max", "lastNotNull")), 8, 9)
    b.add(timeseries("Used %", [storage_series(storage_pct, s)], unit="percentunit", fill=0, min_=0,
                     calcs=("min", "max", "lastNotNull")), 8, 9)
    b.add(timeseries("Free", [storage_series(lambda x: f"{per_storage('total', x)} - {per_storage('used', x)}", s)],
                     unit="bytes", fill=0, min_=0, calcs=("min", "lastNotNull"), desc="Total - used."), 8, 9)

    b.row("Local storages per node", collapsed=True)
    b.add(table("Local storage used per node", [
        tq(f"max by (nodename, host) (({storage_pct(s)}) and on (host, nodename) ({per_storage('shared', s)} == 0))")],
        desc="Used share of each node-local storage.", no_value="no node-local storage selected",
        transformations=matrix("host", row="nodename", corner="Node"),
        overrides=[*[o for o in gauge_cell(".*", thresholds=FILL)],
                   override("Node", {"links": [node_link("Node")], "custom.cellOptions": {"type": "auto"},
                                     "unit": "none"})],
        sort="Node"), 24, 9)
    b.target[-1]["fieldConfig"]["overrides"][0]["matcher"] = {"id": "byType", "options": "number"}

    return finish(dashboard("proxmox-storage", "Proxmox storage",
                            "PVE storages: capacity, use, growth and when they fill up; Ceph-backed ones link to Ceph.",
                            b, tags=["proxmox"], variables=[cluster_var(), storage_var()], extra_links=[PVE_LINK],
                            time_from="now-24h"))


# --- Row for the lylat.space overview (custom.py) ----------------------------------------

def overview_row(b):
    """Proxmox at a glance on the landing page: the cluster and greatfox, no variables."""
    link = [("Proxmox overview", OVERVIEW_DASH + "?" + TIME_URL)]
    lylat_nodes = f'object="nodes", host!="{STANDALONE}"'
    lylat_storages = f'object="storages", nodename!="{STANDALONE}"'
    b.add(stat("PVE nodes", nodes_up_targets('object="nodes"'), text_mode="value_and_name", color_mode="value",
               overrides=NODES_UP_OVERRIDES, links=link,
               desc="The lylat cluster and greatfox: nodes reporting in the last minute (Up) "
                    "and nodes that stopped reporting (Down)."), 4, 5)
    b.add(stat("PVE guests", guest_count_targets('object=~"qemu|lxc"', templates=False), text_mode="value_and_name",
               color_mode="value", overrides=GUEST_COUNT_OVERRIDES, links=link,
               desc="Both PVE setups: running VMs and containers, stopped guests (templates not counted)."), 6, 5)
    b.add(stat("lylat CPU", [weighted_cpu(lylat_nodes)], unit="percentunit", decimals=1, color_mode="value",
               graph=True, thresholds=FRACTION, links=link, desc="Busy share of all cores of the lylat cluster."), 4, 5)
    b.add(stat("lylat memory", [weighted_mem(lylat_nodes)], unit="percentunit", decimals=1, color_mode="value",
               graph=True, thresholds=FRACTION, links=link, desc="Used / total memory of the lylat cluster."), 4, 5)
    b.add(stat("Fullest PVE storage", [q(f"topk(1, {storage_key(storage_pct(lylat_storages), lylat_storages)})",
                                         "{{storage}}", instant=True)],
               unit="percentunit", decimals=1, color_mode="value", thresholds=FILL,
               links=[("Proxmox storage", STORAGE_DASH + "?" + TIME_URL)],
               desc="The lylat cluster's fullest storage (shared ones once, local ones per node)."), 6, 5)
    for panel in b.target[-5:]:
        finish({"panels": [panel]})


# --- helpers for the finished dashboards ---------------------------------------------

def walk(panels):
    for p in panels:
        yield p
        yield from walk(p.get("panels", []))


def finish(dash):
    """Panels on pvestatd series get a 10 s minimum interval (its push and scrape interval), so
    zoomed-in views show every sample."""
    for p in walk(dash["panels"]):
        if any("pvestatd_" in t.get("expr", "") for t in p.get("targets", [])):
            p["interval"] = "10s"
    return dash


DASHBOARDS = {
    "Proxmox/proxmox-overview.json": overview,
    "Proxmox/proxmox-node.json": node,
    "Proxmox/proxmox-guest.json": guests,
    "Proxmox/proxmox-storage.json": storage,
}
