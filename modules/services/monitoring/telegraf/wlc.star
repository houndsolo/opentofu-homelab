# Clone of every C9800 telemetry metric, renamed to wlc_<short> and made Prometheus-friendly (see telemetry.tf).
NAMES = {
    "memory-oper:memory-statistics/memory-statistic": "memory",
    "platform-software-oper:cisco-platform-software/control-processes/control-process": "control_process",
    "platform-software-oper:cisco-platform-software/control-processes/control-process/load-avg-minutes/load-avg-minute": "load_avg",
    "platform-software-oper:cisco-platform-software/control-processes/control-process/per-core-stats/per-core-stat": "cpu_core",
    "process-cpu-oper:cpu-usage/cpu-utilization": "cpu",
    "wireless-access-point-oper:access-point-oper-data/ap-name-mac-map": "ap_name_mac",
    "wireless-access-point-oper:access-point-oper-data/capwap-data": "ap_capwap",
    "wireless-access-point-oper:access-point-oper-data/ethernet-if-stats": "ap_ethernet",
    "wireless-access-point-oper:access-point-oper-data/radio-oper-data": "ap_radio",
    "wireless-access-point-oper:access-point-oper-data/radio-oper-data/radio-band-info": "ap_radio_band",
    "wireless-access-point-oper:access-point-oper-data/radio-oper-data/vap-oper-config": "ap_vap",
    "wireless-access-point-oper:access-point-oper-data/radio-oper-stats": "ap_radio_stats",
    "wireless-access-point-oper:access-point-oper-data/wtp-slot-wlan-stats": "ap_slot_wlan",
    "wireless-ap-global-oper:ap-global-oper-data/ewlc-ap-stats": "ap_global",
    "wireless-ap-global-oper:ap-global-oper-data/wlan-client-stats": "wlan_clients",
    "wireless-client-global-oper:client-global-oper-data/client-live-stats": "client_live",
    "wireless-client-oper:client-oper-data/common-oper-data": "client_common",
    "wireless-client-oper:client-oper-data/dot11-oper-data": "client_dot11",
    "wireless-client-oper:client-oper-data/sisf-db-mac": "client_ip",
    "wireless-client-oper:client-oper-data/traffic-stats": "client_traffic",
    "wireless-rrm-oper:rrm-oper-data/rrm-measurement/foreign/foreign": "rrm_foreign",
    "wireless-rrm-oper:rrm-oper-data/rrm-measurement/foreign/foreign/foreign-data": "rrm_foreign_data",
    "wireless-rrm-oper:rrm-oper-data/rrm-measurement/load": "rrm_load",
    "wireless-rrm-oper:rrm-oper-data/rrm-measurement/noise/noise": "rrm_noise",
    "wireless-rrm-oper:rrm-oper-data/rrm-measurement/noise/noise/noise-data": "rrm_noise_data",
    "wireless-wlan-global-oper:wlan-global-oper-data/wlan-info": "wlan_info",
}
DROP_TAGS = ["path", "subscription"]

def label(k):
    out = ""
    for c in k.elems():
        out += c if (c.isalnum() or c == "_") else "_"
    return out

def volatile(k):
    # Changes on (nearly) every push: as a label it would start a new series each time.
    return k.endswith("_time") or k.endswith("_ts") or "timestamp" in k

def apply(metric):
    full = metric.name[len("wlc_"):]
    if full.startswith("Cisco-IOS-XE-"):
        full = full[len("Cisco-IOS-XE-"):]
    short = NAMES.get(full)
    if short == None:
        short = label(full.replace("-oper:", "_").replace("-", "_").replace("/", "_").replace(":", "_"))
    metric.name = "wlc_" + short
    for t in DROP_TAGS:
        if t in metric.tags:
            metric.tags.pop(t)
    if "source" in metric.tags:
        metric.tags["host"] = metric.tags.pop("source")
    info = {}
    for k, v in list(metric.fields.items()):
        if type(v) != "string":
            continue
        metric.fields.pop(k)
        if k == "current_rate":
            # "m9 ss2" = MCS 9, 2 spatial streams; legacy rates are Mb/s ("24.0").
            p = v.split(" ")
            if len(p) == 2 and p[0].startswith("m") and p[0][1:].isdigit() and p[1].startswith("ss") and p[1][2:].isdigit():
                metric.fields["current_rate_mcs"] = int(p[0][1:])
                metric.fields["current_rate_ss"] = int(p[1][2:])
            elif v.replace(".", "", 1).isdigit():
                metric.fields["current_rate_mbps"] = float(v)
            continue
        if volatile(k):
            continue
        v = v.strip()
        if v != "" and label(k) not in metric.tags:
            info[label(k)] = v
    out = []
    if len(list(metric.fields.keys())) > 0:
        out.append(metric)
    if len(info) > 0:
        # Same measurement, field "info": prometheus_client names it wlc_<short>_info.
        m = Metric(metric.name)
        for k, v in metric.tags.items():
            m.tags[k] = v
        for k, v in info.items():
            m.tags[k] = v
        m.fields["info"] = 1
        m.time = metric.time
        out.append(m)
    return out
