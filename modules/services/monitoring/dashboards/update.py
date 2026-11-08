#!/usr/bin/env python3
"""Download the community dashboards from grafana.com and adapt them for provisioning.

    python3 -I modules/services/monitoring/dashboards/update.py

Re-run after bumping a revision below. The edits are deliberately small, so a
diff against the upstream JSON stays readable:

- every Prometheus datasource reference points at the provisioned datasource
  (uid "prometheus"); datasource template variables and the import-only
  __inputs/__requires sections are dropped, so no import dialog is needed;
- the instance picker shows the scrape target's "host" label (value stays the
  device IP the queries filter on) and lists only devices that have the
  dashboard's metrics;
- a fixed, readable uid, an "snmp" tag and a dashboard-links dropdown that
  jumps between the SNMP dashboards keeping the selected device and time range.
"""
import json
import pathlib
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent

# file (relative to this directory, subdirectory = Grafana folder) => upstream
DASHBOARDS = {
    "Network/snmp-device-summary.json": {
        "gnet_id": 12489, "revision": 5, "uid": "snmp-device-summary", "instance_metric": "ifOperStatus",
    },
    "Network/snmp-interface-detail.json": {
        "gnet_id": 12492, "revision": 4, "uid": "snmp-interface-detail", "instance_metric": "ifOperStatus",
    },
    "Network/mikrotik-snmp.json": {
        "gnet_id": 14420, "revision": 9, "uid": "mikrotik-snmp", "instance_metric": "mtxrBoardName",
        "drop_vars": ["Job"],  # hidden and unused by any panel
        "refresh": "1m",       # upstream refreshes every 10s; we scrape every 30s
    },
}

PROMETHEUS = {"type": "prometheus", "uid": "prometheus"}
UPSTREAM_DS_UIDS = {"${DS_PROMETHEUS}", "$DS_PROMETHEUS", "$source", "${source}", "PBFA97CFB590B2093"}


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
    for v in variables:
        if v["name"] == "instance":
            query = f"query_result(count by (host, instance) ({spec['instance_metric']}))"
            v.update({
                "definition": query,
                "query": {"query": query, "refId": "PrometheusVariableQueryEditor-VariableQuery"},
                # query_result lines look like {host="m326-1",instance="10.5.0.5"} 30 1700000000000
                "regex": '/host="(?<text>[^"]+)".*instance="(?<value>[^"]+)"/',
                "label": "Device",
                "sort": 1,
                "current": {},
            })
            v.pop("options", None)
    fix_datasources(dash)

    dash["tags"] = sorted(set(dash.get("tags", [])) | {"snmp"})
    links = [link for link in dash.get("links", []) if link.get("type") != "dashboards"]
    links.insert(0, {
        "type": "dashboards", "tags": ["snmp"], "asDropdown": True, "title": "SNMP dashboards",
        "includeVars": True, "keepTime": True, "icon": "external link", "targetBlank": False,
        "tooltip": "", "url": "",
    })
    dash["links"] = links
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
