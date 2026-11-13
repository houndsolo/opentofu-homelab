"""nginx reverse proxy dashboard, built by custom.py (imported there).

proxy01/proxy02 run nginx in Podman behind keepalived's VIP proxy-vip (10.2.11.107) and publish
https://<name>.lylat.space for the web UIs (services-config proxy.tf). Data:

- Prometheus job "nginx": nginx-prometheus-exporter on each proxy reading stub_status (connections and
  request counters, no per-site split); job "node", role "proxy": node_exporter (address-info shows the
  VIP holder);
- Prometheus job "blackbox-https": the published sites probed through the proxy from mon01/02 (status,
  TLS, certificate expiry; monitoring-config blackbox_https_targets);
- Loki {app="nginx"}: the access log in logfmt (log_format lylat in proxy-nginx.conf.tftpl: vhost,
  status, rt, urt, upstream, ...) for everything per site, and nginx's error log; {app="Keepalived_vrrp"}
  for VIP moves.
"""
from custom import (Board, MERGE, UP_MAP, UP_STEPS, BLUE, cell, dashboard, fixed_color, organize, override, q, stat,
                    steps, table, timeseries)
from logs import lq, logs, log_table, on_loki, per_bucket, top
from theme import ERROR, INFO, OK, WARN, WARN_HIGH

NGX = 'job="nginx"'
NODE = 'job="node", role="proxy"'
HTTPS = 'job="blackbox-https"'
VIP = 'job="node", role="proxy", device=~"vrrp.*"'
LOG = '{host=~"proxy[0-9]+", app="nginx"}'
# Access lines only, parsed. __error__="": a quote in a user agent (nginx writes it as \x22) makes logfmt fail
# on that line; dropping those few keeps the metric queries from failing as a whole.
ACCESS = LOG + ' |= "vhost=" | logfmt | __error__=""'
# nginx's error log, minus the per-reload worker housekeeping (signals, workers exiting).
ERRORS = LOG + ' != "vhost=" !~ `signal (17|29) |worker process [0-9]+ exited|: exit(ing)?$`'
KEEPALIVED = '{host=~"proxy[0-9]+", app="Keepalived_vrrp"}'
TIME = "${__url_time_range}"
NODE_DASH = "/d/node-exporter-full/node-exporter-full"
PROBES_DASH = "/d/blackbox-probes/blackbox-probes"

NEED_PROBES = "Needs the blackbox-https probes (monitoring-config blackbox_https_targets)"
NEED_ADDR = "Needs node_exporter --collector.netdev.address-info (services-config node-exporter.container)"
NEED_LOG = "No access lines in range (log_format lylat, services-config proxy-nginx.conf)"
CLASS_COLORS = {"2xx": OK, "3xx": INFO, "4xx": WARN, "5xx": ERROR}
DAYS_LEFT = steps((ERROR, None), (WARN_HIGH, 3 * 86400), (OK, 14 * 86400))


def acc(window, *filters):
    """Access-log count over window, with extra pipeline stages (e.g. '| status >= 500')."""
    return f"count_over_time({ACCESS} {' '.join(filters)} [{window}])"


def unwrapped(field, window):
    """Durations from the access log; urt is "-" without an upstream and a list after a retry, so those drop out."""
    return f'{ACCESS} | {field} != "" | {field} != "-" | unwrap {field} | __error__="" [{window}]'


def nginx():
    b = Board()
    b.row("Status")
    b.col(4,
          (stat("VIP on", [q(f"max by (host) (node_network_address_info{{{VIP}}})", "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value=NEED_ADDR, text_size=(12, 30),
                desc="The proxy holding keepalived's VIP proxy-vip (10.2.11.107): every published name is a CNAME "
                     "to it. The other one is the standby."), 4),
          (stat("nginx", [q(f"max by (host) (nginx_up{{{NGX}}})", "{{host}}", instant=True)],
                text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, text_size=(12, 18),
                desc="nginx answering its exporter (stub_status) on each proxy. keepalived moves the VIP away from "
                     "a proxy whose /healthz fails."), 4))
    b.add(stat("Sites (HTTPS through the proxy)", [q(f"max by (host) (probe_success{{{HTTPS}}})", "{{host}}",
                                                     instant=True)],
               text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, no_value=NEED_PROBES,
               orientation="horizontal", text_size=(12, 16),
               desc="Blackbox probes from mon01/02 of each published site by name: DNS, the VIP, TLS with a valid "
                    "certificate and a 2xx from the backend. Alert: ProbeFailed.",
               links=[("Blackbox probes", PROBES_DASH + "?" + TIME)]), 6, 8)
    b.col(5,
          (stat("Certificate expires in", [q(f"min(probe_ssl_earliest_cert_expiry{{{HTTPS}}}) - time()", instant=True)],
                unit="dtdurations", color_mode="value", thresholds=DAYS_LEFT, no_value=NEED_PROBES, text_size=(12, 22),
                desc="The wildcard *.lylat.space as the sites serve it (Let's Encrypt, roots/certs). It renews "
                     "itself at ~30 days left. Orange under 14 days (alert TLSCertExpiringSoon), red under 3."), 4),
          (stat("Certificate", [q(f"max by (subject, issuer) (probe_ssl_last_chain_info{{{HTTPS}}})",
                                  "{{subject}} · {{issuer}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value=NEED_PROBES, text_size=(12, 14),
                desc="Subject and issuer of the leaf certificate."), 4))
    b.col(5,
          (stat("Requests/s", [q(f"sum(rate(nginx_http_requests_total{{{NGX}}}[$__rate_interval]))")],
                unit="reqps", decimals=2, graph=True, color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Both proxies, every request including keepalived's /healthz checks (stub_status counts all)."), 4),
          (stat("Active connections", [q(f"sum(nginx_connections_active{{{NGX}}})")], decimals=0, graph=True,
                color_mode="value", thresholds=BLUE, text_size=(12, 22),
                desc="Open client connections on both proxies (reading + writing + idle keep-alive)."), 4))
    b.col(4,
          (on_loki(stat("Errors in range (5xx)", [
              lq(f"sum({acc('$__range', '| status >= 500')}) / sum({acc('$__range')})", "5xx", instant=True)],
              unit="percentunit", decimals=2, color_mode="value", no_value="0",
              thresholds=steps((OK, None), (WARN_HIGH, 0.001), (ERROR, 0.01)), text_size=(12, 22),
              desc="Share of requests answered with a 5xx (502/504 = the backend VIP didn't answer).")), 4),
          (on_loki(stat("Requests in range", [lq(f"sum({acc('$__range')})", "requests", instant=True)],
                        decimals=0, color_mode="value", thresholds=BLUE, no_value=NEED_LOG, text_size=(12, 22),
                        desc="Requests to the published sites in the time range (access log; /healthz isn't logged).")), 4))

    b.row("Sites (access log)")
    b.add(on_loki(timeseries("Requests by site", [
        lq(f"sum by (vhost) (rate({ACCESS} [$__auto]))", "{{vhost}}")],
        unit="reqps", calcs=("mean", "max"), no_value=NEED_LOG,
        desc="Requests per published name (the Host header; scanners asking for the bare IP show up as that).")),
        12, 9)
    status_class = '| label_format class=`{{ substr 0 1 .status }}xx`'
    b.add(by_class(per_bucket("Responses by status class", [
        lq(f"sum by (class) (count_over_time({ACCESS} {status_class} [$__auto]))", "{{class}}")],
        desc="Responses per status class: 3xx are mostly the http->https redirects and Grafana's login redirect.")),
        12, 9)
    b.add(on_loki(timeseries("Request time p95 by site", [
        lq(f"quantile_over_time(0.95, {unwrapped('rt', '$__auto')}) by (vhost)", "{{vhost}}")],
        unit="s", calcs=("mean", "max"), no_value=NEED_LOG,
        desc="$request_time: first byte from the client to the last byte sent. Long-polling and websockets "
             "(Grafana live) show their whole duration.")), 12, 8)
    b.add(on_loki(timeseries("Upstream time p95 by site", [
        lq(f"quantile_over_time(0.95, {unwrapped('urt', '$__auto')}) by (vhost)", "{{vhost}}")],
        unit="s", calcs=("mean", "max"), no_value=NEED_LOG,
        desc="$upstream_response_time: how long the backend VIP (grafana-vip, netbox-vip, dark-triage-vip) took. "
             "The difference to the request time is the client side.")), 12, 8)

    cols = [
        ("Requests", f"sum by (vhost) ({acc('$__range')})"),
        ("2xx", f"sum by (vhost) ({acc('$__range', '| status >= 200 | status < 300')})"),
        ("4xx", f"sum by (vhost) ({acc('$__range', '| status >= 400 | status < 500')})"),
        ("5xx", f"sum by (vhost) ({acc('$__range', '| status >= 500')})"),
        ("p95 time", f"quantile_over_time(0.95, {unwrapped('rt', '$__range')}) by (vhost)"),
        ("Sent", f"sum by (vhost) (sum_over_time({ACCESS} | unwrap bytes | __error__=\"\" [$__range]))"),
    ]
    rename = {"vhost": "Site"}
    rename.update({f"Value #{chr(65 + i)}": name for i, (name, _) in enumerate(cols)})
    b.add(on_loki(table("Sites in range", [lq(e, instant=True) for _, e in cols], no_value=NEED_LOG,
                        desc="Per published name over the time range, from the access log.",
                        transformations=[MERGE, organize(exclude=["Time"], rename=rename,
                                                         order=["Site", *[n for n, _ in cols]])],
                        overrides=[override("p95 time", {"unit": "s", "decimals": 3}),
                                   override("Sent", {"unit": "bytes"}),
                                   cell("5xx", "color-text"), override("5xx", {"thresholds": steps((OK, None), (ERROR, 1))}),
                                   cell("4xx", "color-text"), override("4xx", {"thresholds": steps((OK, None), (WARN, 1))})],
                        sort="Requests", desc_sort=True)), 12, 8)
    b.add(top("Top paths", f"sum by (vhost, uri) ({acc('$__range')})", "{{vhost}} {{uri}}",
              desc="Most requested paths over the time range."), 6, 8)
    b.add(top("Top clients", f"sum by (client) ({acc('$__range')})", "{{client}}",
              desc="Client addresses over the time range."), 6, 8)
    b.add(log_table("Failed requests (4xx/5xx)", f"{ACCESS} | status >= 400",
                    ["host", "vhost", "status", "method", "uri", "upstream", "urt", "client"],
                    rename={"host": "Proxy", "vhost": "Site", "status": "Status", "method": "Method", "uri": "Path",
                            "upstream": "Upstream", "urt": "Upstream time", "client": "Client"},
                    widths={"Proxy": 80, "Site": 190, "Status": 60, "Method": 70, "Upstream time": 110},
                    desc="Requests answered with an error. 502/504: nginx couldn't reach the backend VIP."), 24, 8)

    b.row("Connections (stub_status)")
    b.add(timeseries("Requests/s by proxy", [
        q(f"sum by (host) (rate(nginx_http_requests_total{{{NGX}}}[$__rate_interval]))", "{{host}}")],
        unit="reqps", calcs=("mean", "max", "lastNotNull"),
        desc="The VIP holder takes the client traffic; both answer keepalived's and the exporter's checks."), 8, 8)
    b.add(timeseries("Connections by state", [
        q(f"sum by (host) (nginx_connections_reading{{{NGX}}})", "{{host}} reading"),
        q(f"sum by (host) (nginx_connections_writing{{{NGX}}})", "{{host}} writing"),
        q(f"sum by (host) (nginx_connections_waiting{{{NGX}}})", "{{host}} idle (keep-alive)"),
    ], decimals=0, calcs=("mean", "max", "lastNotNull"),
        desc="reading: receiving the request; writing: proxying/sending the response (websockets stay here); "
             "idle: keep-alive connections waiting for the next request."), 8, 8)
    b.add(timeseries("Connections accepted / dropped", [
        q(f"sum by (host) (rate(nginx_connections_accepted{{{NGX}}}[$__rate_interval]))", "{{host}} accepted"),
        q(f"sum by (host) (rate(nginx_connections_accepted{{{NGX}}}[$__rate_interval]) - "
          f"rate(nginx_connections_handled{{{NGX}}}[$__rate_interval]))", "{{host}} dropped"),
    ], unit="cps", calcs=("mean", "max"),
        desc="Dropped = accepted but not handled: worker_connections (1024) exhausted.",
        overrides=[override(".*dropped", {"color": {"mode": "fixed", "fixedColor": ERROR}}, regex=True)]), 8, 8)

    b.row("Probes")
    b.add(timeseries("Probe time by site", [
        q(f"max by (host) (probe_duration_seconds{{{HTTPS}}})", "{{host}}")],
        unit="s", calcs=("mean", "max"), no_value=NEED_PROBES,
        desc="The whole HTTPS request from mon01/02: DNS, TCP and TLS to the VIP, nginx and the backend."), 12, 8)
    b.add(timeseries("Probe phases (all sites)", [
        q(f"avg by (phase) (probe_http_duration_seconds{{{HTTPS}}})", "{{phase}}")],
        unit="s", stack=True, fill=40, calcs=("mean", "max"), no_value=NEED_PROBES,
        desc="resolve: DNS (dns-vip); connect: TCP to proxy-vip; tls: handshake; processing: nginx plus the "
             "backend until the first byte; transfer: the body."), 12, 8)

    b.row("Proxy VMs")
    b.add(timeseries("CPU", [
        q(f'100 * (1 - avg by (host) (rate(node_cpu_seconds_total{{mode="idle", {NODE}}}[$__rate_interval])))',
          "{{host}}")], unit="percent", min_=0, calcs=("mean", "max"),
        links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)]), 6, 7)
    b.add(timeseries("Memory used", [
        q(f"node_memory_MemTotal_bytes{{{NODE}}} - node_memory_MemAvailable_bytes{{{NODE}}}", "{{host}}")],
        unit="bytes", min_=0, calcs=("mean", "max")), 6, 7)
    b.add(timeseries("Network (rx + tx)", [
        q(f'sum by (host) (rate(node_network_receive_bytes_total{{{NODE}, device=~"e.*"}}[$__rate_interval]) + '
          f'rate(node_network_transmit_bytes_total{{{NODE}, device=~"e.*"}}[$__rate_interval])) * 8', "{{host}}")],
        unit="bps", calcs=("mean", "max"), desc="All physical NICs: management, VLAN 2 (clients and backends) and "
                                                "VLAN 220 (keepalived)."), 6, 7)
    b.add(on_loki(timeseries("VIP moves", [
        lq(f'sum by (host) (count_over_time({KEEPALIVED} |~ "Entering MASTER STATE" [$__auto]))', "{{host}} took the VIP")],
        draw="bars", fill=70, decimals=0, calcs=("sum",), no_value="No VIP moves in range",
        desc="keepalived taking over the VIP: a deploy that restarts nginx, a failed health check or a reboot.")), 6, 7)

    b.row("Logs")
    b.add(logs("nginx error log", ERRORS,
               desc="nginx's own messages (warnings, upstream errors, reloads). The container logs them on stderr, "
                    "so Loki's level says error for all of them; the [level] in the text is the real one."), 12, 10)
    b.add(logs("keepalived", KEEPALIVED, desc="VRRP state changes and health-check results on both proxies."), 12, 10)

    return dashboard("nginx-proxy", "nginx reverse proxy",
                     "proxy01/02 behind proxy-vip: published sites, TLS certificate, traffic per site, connections, "
                     "probes and logs.",
                     b, tags=["services", "nginx"], time_from="now-6h")


def overview_tiles(b, w):
    """The published sites and the certificate for custom.overview(): a w-wide column."""
    link = [("nginx reverse proxy", "/d/nginx-proxy/nginx-reverse-proxy?" + TIME)]
    b.col(w,
          (stat("Sites (HTTPS)", [q(f"max by (host) (probe_success{{{HTTPS}}})", "{{host}}", instant=True)],
                text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, no_value=NEED_PROBES,
                text_size=(11, 14), links=link,
                desc="https://<name>.lylat.space through the nginx proxy (proxy-vip), probed by name from mon01/02."), 5),
          (stat("Certificate expires in", [q(f"min(probe_ssl_earliest_cert_expiry{{{HTTPS}}}) - time()", instant=True)],
                unit="dtdurations", color_mode="value", thresholds=DAYS_LEFT, no_value=NEED_PROBES, text_size=(11, 18),
                links=link, desc="*.lylat.space (Let's Encrypt, renewed by roots/certs at ~30 days left)."), 3))


def by_class(p):
    """Fixed colours per status class."""
    p["fieldConfig"]["overrides"] += [fixed_color(c, color) for c, color in CLASS_COLORS.items()]
    return p


DASHBOARDS = {"Services/nginx-proxy.json": nginx}
