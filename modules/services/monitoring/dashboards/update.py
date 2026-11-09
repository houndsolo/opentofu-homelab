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
- the device/node picker shows the scrape target's "host" label (value stays the
  instance the queries filter on) and lists only targets that have the
  dashboard's metrics;
- a fixed, readable uid, a "lylat" tag and a "Dashboards" dropdown listing every
  dashboard with that tag; the SNMP ones also get an "snmp" tag and a dropdown
  that jumps between them keeping the selected device and time range, and the
  Ceph ones a "ceph" tag and a "Ceph dashboards" dropdown (shared with the
  custom Ceph dashboards).

The custom dashboards (overview, FRR, probes, monitoring stack, Ceph cluster and
OSD) are built by custom.py instead.
"""
import json
import pathlib
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent

# ceph/ceph tentacle branch, monitoring/ceph-mixin/dashboards_out (Ceph 20.2 = tentacle).
CEPH_MIXIN_COMMIT = "804c592824f88ea7e06a9b84a82be359b8dec325"  # 2026-09-30
CEPH_MIXIN_URL = ("https://raw.githubusercontent.com/ceph/ceph/" + CEPH_MIXIN_COMMIT
                  + "/monitoring/ceph-mixin/dashboards_out/{}.json")


def ceph_mixin(name, uid, title, reset_vars=("cluster",)):
    # The mixin's $cluster picker lists label_values(ceph_health_status, cluster): just "lylat".
    return {"url": CEPH_MIXIN_URL.format(name), "source": f"ceph-mixin {name} @ {CEPH_MIXIN_COMMIT[:12]}",
            "uid": uid, "title": title, "group": "ceph", "reset_vars": list(reset_vars)}


# file (relative to this directory, subdirectory = Grafana folder) => upstream
DASHBOARDS = {
    "Network/snmp-device-summary.json": {
        "gnet_id": 12489, "revision": 5, "uid": "snmp-device-summary", "group": "snmp",
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
    },
    "Network/snmp-interface-detail.json": {
        "gnet_id": 12492, "revision": 4, "uid": "snmp-interface-detail", "group": "snmp",
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
    },
    "Network/mikrotik-snmp.json": {
        "gnet_id": 14420, "revision": 9, "uid": "mikrotik-snmp", "group": "snmp",
        "picker": {"var": "instance", "metric": "mtxrBoardName", "label": "Device"},
        "drop_vars": ["Job"],  # hidden and unused by any panel
        "refresh": "1m",       # upstream refreshes every 10s; we scrape every 30s
    },
    # Works for job=node (hosts) and job=vyos-node (VyOS routers): pick the job, then the host.
    "Hosts/node-exporter-full.json": {
        "gnet_id": 1860, "revision": 46, "uid": "node-exporter-full",
        "picker": {"var": "node", "metric": 'node_uname_info{job="$job"}', "label": "Host"},
        "drop_vars": ["nodename"],  # only fed the old instance picker; the host picker replaces both
        "reset_vars": ["job"],      # no saved selection from the upstream author
    },
    # Official Ceph dashboards (the ones the Ceph dashboard embeds). The headline "Ceph
    # cluster" and "Ceph OSD" dashboards are custom.py's; these add depth. rgw, nvmeof,
    # smb and hardware ones are left out (not deployed here); so are the host ones, which
    # join node_exporter on the instance label (ours is host).
    "Storage/ceph-cluster-advanced.json": ceph_mixin("ceph-cluster-advanced", "ceph-cluster-advanced",
                                                     "Ceph cluster advanced (mixin)"),
    "Storage/ceph-osds-overview.json": ceph_mixin("osds-overview", "ceph-osds-overview", "Ceph OSDs overview (mixin)"),
    "Storage/ceph-osd-device-details.json": ceph_mixin("osd-device-details", "ceph-osd-device-details",
                                                       "Ceph OSD device details (mixin)"),
    "Storage/ceph-pools-overview.json": ceph_mixin("pool-overview", "ceph-pools-overview", "Ceph pools overview (mixin)"),
    "Storage/ceph-pool-details.json": ceph_mixin("pool-detail", "ceph-pool-details", "Ceph pool details (mixin)"),
    "Storage/ceph-rbd-overview.json": ceph_mixin("rbd-overview", "ceph-rbd-overview", "Ceph RBD overview (mixin)"),
    "Storage/ceph-rbd-details.json": ceph_mixin("rbd-details", "ceph-rbd-details", "Ceph RBD details (mixin)"),
    "Storage/ceph-filesystem.json": ceph_mixin("cephfsdashboard", "ceph-filesystem", "Ceph filesystem (mixin)",
                                               reset_vars=("cluster", "name")),
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
GROUP_LINKS = {"snmp": SNMP_LINK, "ceph": CEPH_LINK}

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
UPSTREAM_DS_UIDS = {"${DS_PROMETHEUS}", "$DS_PROMETHEUS", "$source", "${source}", "PBFA97CFB590B2093",
                    "${ds_prometheus}", "$ds_prometheus", "$datasource", "${datasource}"}


def fix_datasources(node):
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and (ds.get("type") == "prometheus" or ds.get("uid") in UPSTREAM_DS_UIDS):
            node["datasource"] = dict(PROMETHEUS)
        elif isinstance(ds, str) and ds in UPSTREAM_DS_UIDS:
            node["datasource"] = dict(PROMETHEUS)
        for value in node.values():
            fix_datasources(value)
    elif isinstance(node, list):
        for value in node:
            fix_datasources(value)


def adapt(dash, spec):
    for key in ("__inputs", "__elements", "__requires", "iteration"):
        dash.pop(key, None)
    dash["id"] = None
    dash["uid"] = spec["uid"]
    if "title" in spec:
        dash["title"] = spec["title"]
    if "refresh" in spec:
        dash["refresh"] = spec["refresh"]

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
    fix_datasources(dash)

    group = spec.get("group")
    dash["tags"] = sorted(set(dash.get("tags", [])) | {"lylat"} | ({group} if group else set()))
    links = [link for link in dash.get("links", []) if link.get("type") != "dashboards"]
    dash["links"] = ([dict(GROUP_LINKS[group])] if group else []) + [dict(NAV_LINK)] + links
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
        out.write_text(json.dumps(adapt(dash, spec), indent=2, ensure_ascii=False) + "\n")
        print(f"{rel}: {upstream_title} ({source})")


if __name__ == "__main__":
    main()
