#!/usr/bin/env python3
"""Download the community dashboards from grafana.com and adapt them for provisioning.

    python3 -I modules/services/monitoring/dashboards/update.py

Re-run after bumping a revision below. The edits are deliberately small, so a
diff against the upstream JSON stays readable:

- every Prometheus datasource reference points at the provisioned datasource
  (uid "prometheus"); datasource template variables and the import-only
  __inputs/__requires sections are dropped, so no import dialog is needed;
- the device/node picker shows the scrape target's "host" label (value stays the
  instance the queries filter on) and lists only targets that have the
  dashboard's metrics;
- a fixed, readable uid, a "lylat" tag and a "Dashboards" dropdown listing every
  dashboard with that tag; the SNMP ones also get an "snmp" tag and a dropdown
  that jumps between them keeping the selected device and time range.

The custom dashboards (overview, FRR, probes, monitoring stack) are built by
custom.py instead.
"""
import json
import pathlib
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent

# file (relative to this directory, subdirectory = Grafana folder) => upstream
DASHBOARDS = {
    "Network/snmp-device-summary.json": {
        "gnet_id": 12489, "revision": 5, "uid": "snmp-device-summary", "snmp": True,
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
    },
    "Network/snmp-interface-detail.json": {
        "gnet_id": 12492, "revision": 4, "uid": "snmp-interface-detail", "snmp": True,
        "picker": {"var": "instance", "metric": "ifOperStatus", "label": "Device"},
    },
    "Network/mikrotik-snmp.json": {
        "gnet_id": 14420, "revision": 9, "uid": "mikrotik-snmp", "snmp": True,
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

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
UPSTREAM_DS_UIDS = {"${DS_PROMETHEUS}", "$DS_PROMETHEUS", "$source", "${source}", "PBFA97CFB590B2093",
                    "${ds_prometheus}", "$ds_prometheus"}


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
    if "refresh" in spec:
        dash["refresh"] = spec["refresh"]

    variables = dash["templating"]["list"]
    variables[:] = [
        v for v in variables
        if v.get("type") != "datasource" and v["name"] not in spec.get("drop_vars", [])
    ]
    picker = spec["picker"]
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

    tags = {"lylat"} | ({"snmp"} if spec.get("snmp") else set())
    dash["tags"] = sorted(set(dash.get("tags", [])) | tags)
    links = [link for link in dash.get("links", []) if link.get("type") != "dashboards"]
    dash["links"] = ([dict(SNMP_LINK)] if spec.get("snmp") else []) + [dict(NAV_LINK)] + links
    return dash


def main():
    for rel, spec in DASHBOARDS.items():
        url = f"https://grafana.com/api/dashboards/{spec['gnet_id']}/revisions/{spec['revision']}/download"
        with urllib.request.urlopen(url, timeout=30) as resp:
            dash = json.loads(resp.read().decode(), strict=False)
        out = HERE / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(adapt(dash, spec), indent=2, ensure_ascii=False) + "\n")
        print(f"{rel}: {dash['title']} (grafana.com {spec['gnet_id']} rev {spec['revision']})")


if __name__ == "__main__":
    main()
