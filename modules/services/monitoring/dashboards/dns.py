"""DNS (BIND) dashboard, built by custom.py (imported there).

dns01/dns02 run BIND 9 in Podman (services-config main.tf): dns01 is the primary for lylat.space and
10.in-addr.arpa, dns02 the secondary (NOTIFY + TSIG transfers); both recurse through 1.1.1.1/1.0.0.1, and
keepalived's dns-vip 10.8.53.53 sits on one of them. Data:

- Prometheus job "bind": bind_exporter on each VM reading BIND's statistics channel (services-config
  dns-bind-exporter.tf): queries by type, responses by rcode, recursion, the resolver (forwarders, cache,
  DNSSEC), zone serials and transfers;
- job "blackbox-dns_soa": SOA probes of each server's service address from mon01/02;
- job "node", role "dns": node_exporter (address-info shows the VIP holder);
- Loki {app="bind9"} (named's own log) and {app=~"Keepalived.*"} on dns01/02.
"""
from custom import (Board, UP_MAP, UP_STEPS, BLUE, dashboard, override, q, stat, steps, table, timeseries, organize,
                    MERGE)
from logs import lq, logs, on_loki
from theme import ERROR, OK, WARN_HIGH

BIND = 'job="bind"'
VIEW = 'job="bind", view="_default"'
SERVFAIL = 'job="bind", rcode="SERVFAIL"'
NXDOMAIN = 'job="bind", rcode="NXDOMAIN"'
NODE = 'job="node", role="dns"'
SOA = 'job="blackbox-dns_soa"'
VIP = 'job="node", role="dns", device=~"vrrp.*"'
# The zones OpenTofu serves; the automatic empty zones (RFC 1918, ...) all report serial 0.
ZONES = 'job="bind", zone_name=~"lylat.space|10.in-addr.arpa"'
BIND_LOG = '{host=~"dns0[12]", app="bind9"}'
KEEPALIVED = '{host=~"dns0[12]", app=~"Keepalived.*"}'
TIME = "${__url_time_range}"
NODE_DASH = "/d/node-exporter-full/node-exporter-full"
PROBES_DASH = "/d/blackbox-probes/blackbox-probes"

NEED_EXP = "Needs bind_exporter (services-config dns-bind-exporter.tf)"
NEED_ADDR = "Needs node_exporter --collector.netdev.address-info (services-config node-exporter.container)"
RATE = "[$__rate_interval]"
SHARE = steps((OK, None), (WARN_HIGH, 0.01), (ERROR, 0.05))


def rate(metric, sel=BIND, by="host"):
    return f"sum by ({by}) (rate({metric}{{{sel}}}{RATE}))"


def dns():
    b = Board()
    b.row("Status")
    b.col(4,
          (stat("VIP on", [q(f"max by (host) (node_network_address_info{{{VIP}}})", "{{host}}", instant=True)],
                text_mode="name", color_mode="value", thresholds=BLUE, no_value=NEED_ADDR, text_size=(12, 30),
                desc="The server holding keepalived's dns-vip (10.8.53.53). Clients configured with both "
                     "10.8.53.1 and 10.8.53.2 use them directly and don't depend on it."), 4),
          (stat("BIND", [q(f"max by (host) (bind_up{{{BIND}}})", "{{host}}", instant=True)],
                text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, no_value=NEED_EXP,
                text_size=(12, 18),
                desc="named answering its statistics channel on each server (bind_up). Alerts BindDown, BindAllDown."), 4))
    b.col(4,
          (stat("SOA probes", [q(f"max by (host) (probe_success{{{SOA}}})", "{{host}}", instant=True)],
                text_mode="value_and_name", mappings=UP_MAP, thresholds=UP_STEPS, text_size=(12, 18),
                links=[("Blackbox probes", PROBES_DASH + "?" + TIME)],
                desc="Blackbox SOA query for lylat.space against each server's service address from mon01/02. "
                     "Alert: ProbeFailed."), 4),
          (stat("Last reload", [q(f"time() - max by (host) (bind_config_time_seconds{{{BIND}}})", "{{host}}",
                                  instant=True)],
                unit="dtdurations", text_mode="value_and_name", color_mode="value", thresholds=BLUE,
                no_value=NEED_EXP, text_size=(12, 16),
                desc="Time since named last loaded its configuration: a restart, or a reload by the deploy "
                     "after a named.conf change (services-config deploy.sh)."), 4))
    b.add(stat("Zone serials", [q(f"max by (host, zone_name) (bind_zone_serial{{{ZONES}}})", "{{host}} {{zone_name}}",
                                  instant=True)],
               decimals=0, text_mode="value_and_name", color_mode="value", thresholds=BLUE, no_value=NEED_EXP,
               orientation="horizontal", text_size=(12, 16),
               desc="SOA serial of each OpenTofu-managed zone on each server. dns02 follows dns01 within seconds "
                    "of a NOTIFY; 15 minutes apart fires BindZoneSerialMismatch."), 6, 8)
    b.col(5,
          (stat("Queries/s", [q(f"sum(rate(bind_incoming_queries_total{{{BIND}}}{RATE}))")],
                unit="qps", decimals=1, graph=True, color_mode="value", thresholds=BLUE, no_value=NEED_EXP,
                text_size=(12, 22), desc="Both servers, every query type."), 4),
          (stat("Cache hit ratio", [q(f"1 - sum(rate(bind_query_recursions_total{{{BIND}}}{RATE})) / "
                                      f"sum(rate(bind_incoming_queries_total{{{BIND}}}{RATE}))")],
                unit="percentunit", decimals=1, color_mode="value", thresholds=BLUE, no_value=NEED_EXP,
                text_size=(12, 22),
                desc="Queries answered without recursing (from the cache or the local zones)."), 4))
    b.col(5,
          (stat("SERVFAIL", [q(f"sum(rate(bind_response_rcodes_total{{{SERVFAIL}}}{RATE})) / "
                               f"sum(rate(bind_response_rcodes_total{{{BIND}}}{RATE}))")],
                unit="percentunit", decimals=2, color_mode="value", thresholds=SHARE, no_value=NEED_EXP,
                text_size=(12, 22),
                desc="Share of answers that are SERVFAIL: the forwarders failing, DNSSEC validation failures, or "
                     "a broken delegation. Alert BindHighServfailRate over 5% for 15 min."), 4),
          (stat("NXDOMAIN", [q(f"sum(rate(bind_response_rcodes_total{{{NXDOMAIN}}}{RATE})) / "
                               f"sum(rate(bind_response_rcodes_total{{{BIND}}}{RATE}))")],
                unit="percentunit", decimals=2, color_mode="value", thresholds=BLUE, no_value=NEED_EXP,
                text_size=(12, 22),
                desc="Share of answers for names that don't exist (search-domain suffixes, typos, old names)."), 4))

    b.row("Queries")
    b.add(timeseries("Queries/s by type", [q(rate("bind_incoming_queries_total", by="type"), "{{type}}")],
                     unit="qps", stack=True, fill=40, calcs=("mean", "max"), no_value=NEED_EXP,
                     desc="Incoming queries on both servers by QTYPE."), 8, 8)
    b.add(timeseries("Responses/s by rcode", [
        q(f"sum by (rcode) (rate(bind_response_rcodes_total{{{BIND}}}{RATE})) > 0", "{{rcode}}")],
        unit="qps", stack=True, fill=40, calcs=("mean", "max"), no_value=NEED_EXP,
        desc="Answers by response code; codes that never occur in the range are hidden.",
        overrides=[override("SERVFAIL", {"color": {"mode": "fixed", "fixedColor": ERROR}}),
                   override("NOERROR", {"color": {"mode": "fixed", "fixedColor": OK}})]), 8, 8)
    b.add(timeseries("Queries/s by server", [q(rate("bind_incoming_queries_total"), "{{host}}")],
                     unit="qps", calcs=("mean", "max", "lastNotNull"), no_value=NEED_EXP,
                     desc="Clients with both resolvers spread over both; the VIP holder takes the dns-vip clients."),
          8, 8)
    b.add(timeseries("SERVFAIL / NXDOMAIN share", [
        q(f"{rate('bind_response_rcodes_total', SERVFAIL)} / {rate('bind_response_rcodes_total')}", "{{host}} SERVFAIL"),
        q(f"{rate('bind_response_rcodes_total', NXDOMAIN)} / {rate('bind_response_rcodes_total')}", "{{host}} NXDOMAIN"),
    ], unit="percentunit", fill=0, calcs=("mean", "max"), no_value=NEED_EXP,
        desc="Per server. A SERVFAIL step on both at once points at the forwarders; on one only, at that server.",
        overrides=[override(".*SERVFAIL", {"custom.lineWidth": 2}, regex=True)]), 12, 8)
    b.add(timeseries("Rejected / failed queries", [
        q(f"sum by (host, error) (rate(bind_query_errors_total{{{BIND}}}{RATE})) > 0", "{{host}} {{error}}")],
        unit="qps", fill=0, calcs=("mean", "max"), no_value="No rejected or failed queries in range",
        desc="Queries named refused (Rejected: not in trusted_clients / allow-query), dropped or failed."), 12, 8)

    b.row("Recursion and cache")
    b.add(timeseries("Recursion", [
        q(rate("bind_query_recursions_total"), "{{host}} recursions/s"),
        q(f"sum by (host) (rate(bind_resolver_queries_total{{{VIEW}}}{RATE}))", "{{host}} queries to forwarders/s"),
    ], unit="qps", fill=0, calcs=("mean", "max"), no_value=NEED_EXP,
        desc="Client queries that needed recursion, and the queries named sent to the forwarders "
             "(1.1.1.1/1.0.0.1, 10.0.1.110 for haylett.lan) for them."), 8, 8)
    b.add(timeseries("Forwarder round-trip p50 / p95", [
        q(f"histogram_quantile(0.5, sum by (host, le) (rate(bind_resolver_query_duration_seconds_bucket{{{VIEW}}}{RATE})))",
          "{{host}} p50"),
        q(f"histogram_quantile(0.95, sum by (host, le) (rate(bind_resolver_query_duration_seconds_bucket{{{VIEW}}}{RATE})))",
          "{{host}} p95"),
    ], unit="s", fill=0, calcs=("mean", "max"), no_value=NEED_EXP,
        desc="How long the forwarders take to answer (BIND's RTT buckets: <10ms, <100ms, <500ms, <800ms, "
             "<1.6s, more)."), 8, 8)
    b.add(timeseries("Recursive clients", [q(f"max by (host) (bind_recursive_clients{{{BIND}}})", "{{host}}")],
                     decimals=0, fill=0, calcs=("mean", "max", "lastNotNull"), no_value=NEED_EXP,
                     desc="Recursive lookups in progress. The log's \"clients-per-query increased\" lines mean "
                          "many clients waited for the same slow name."), 8, 8)
    b.add(timeseries("Resolver errors", [
        q(f"sum by (host, error) (rate(bind_resolver_response_errors_total{{{VIEW}}}{RATE})) > 0",
          "{{host}} {{error}}"),
        q(f"sum by (host, error) (rate(bind_resolver_query_errors_total{{{VIEW}}}{RATE})) > 0",
          "{{host}} {{error}}"),
        q(f"sum by (host) (rate(bind_resolver_query_retries_total{{{VIEW}}}{RATE})) > 0", "{{host}} retries"),
    ], unit="qps", fill=0, calcs=("mean", "max"), no_value="No resolver errors in range",
        desc="Errors on the forwarder side: SERVFAIL/NXDOMAIN/FORMERR answers from them, timeouts (QueryTimeout), "
             "lame servers, retries."), 8, 8)
    b.add(timeseries("DNSSEC validation", [
        q(f"sum by (host, result) (rate(bind_resolver_dnssec_validation_success_total{{{VIEW}}}{RATE}))",
          "{{host}} {{result}}"),
        q(f"sum by (host) (rate(bind_resolver_dnssec_validation_errors_total{{{VIEW}}}{RATE}))", "{{host}} failed"),
    ], unit="ops", fill=0, calcs=("mean", "max"), no_value=NEED_EXP,
        desc="Validations of forwarded answers (dnssec-validation auto). Failures turn into SERVFAIL for the "
             "client; haylett.lan is exempt (validate-except).",
        overrides=[override(".*failed", {"color": {"mode": "fixed", "fixedColor": ERROR}}, regex=True)]), 8, 8)
    b.add(timeseries("Cache RRsets", [
        q(f"sum by (host) (bind_resolver_cache_rrsets{{{VIEW}}})", "{{host}}")],
        decimals=0, fill=0, calcs=("mean", "max", "lastNotNull"), no_value=NEED_EXP,
        desc="RRsets in the resolver cache (positive and negative); it empties on a restart, not on a reload."),
        8, 8)

    b.row("Zones")
    b.add(timeseries("Zone serials", [
        q(f"max by (host, zone_name) (bind_zone_serial{{{ZONES}}})", "{{host}} {{zone_name}}")],
        decimals=0, fill=0, step=True, calcs=("lastNotNull",), no_value=NEED_EXP,
        desc="Serial per zone and server over time; each OpenTofu DNS change bumps it on dns01, dns02 follows."),
        12, 8)
    b.add(timeseries("Zone transfers", [
        q(f"sum by (host) (increase(bind_zone_transfer_success_total{{{BIND}}}{RATE})) > 0", "{{host}} ok"),
        q(f"sum by (host) (increase(bind_zone_transfer_failure_total{{{BIND}}}{RATE})) > 0", "{{host}} failed"),
        q(f"sum by (host) (increase(bind_zone_transfer_rejected_total{{{BIND}}}{RATE})) > 0", "{{host}} rejected"),
    ], draw="bars", fill=70, decimals=0, calcs=("sum",), no_value="No zone transfers in range",
        desc="AXFR/IXFR: ok on dns01 = dns02 (or OpenTofu) pulled a zone; rejected = a transfer without the "
             "TSIG key.",
        overrides=[override(".*failed", {"color": {"mode": "fixed", "fixedColor": ERROR}}, regex=True),
                   override(".*rejected", {"color": {"mode": "fixed", "fixedColor": WARN_HIGH}}, regex=True)]),
        12, 8)

    b.row("Probes")
    b.add(timeseries("SOA probe time", [
        q(f'max by (host) (probe_dns_duration_seconds{{phase="request", {SOA}}})', "{{host}}")],
        unit="s", fill=0, calcs=("mean", "max"),
        desc="The SOA query from mon01/02 to each server's service address."), 8, 8)
    b.add(timeseries("SOA serial (probes)", [q(f"max by (host) (probe_dns_serial{{{SOA}}})", "{{host}}")],
                     decimals=0, fill=0, step=True, calcs=("lastNotNull",),
                     desc="lylat.space's serial as each server answers it, independent of the exporter."), 8, 8)
    b.add(table("Probes now", [
        q(f"max by (host) (probe_success{{{SOA}}})", table=True),
        q(f"max by (host) (probe_dns_serial{{{SOA}}})", table=True),
        q(f'max by (host) (probe_dns_duration_seconds{{phase="request", {SOA}}})', table=True)],
        transformations=[MERGE, organize(exclude=["Time"], rename={
            "host": "Server", "Value #A": "OK", "Value #B": "Serial", "Value #C": "Query time"})],
        overrides=[override("OK", {"mappings": UP_MAP, "custom.cellOptions": {"type": "color-background"},
                                   "thresholds": UP_STEPS}),
                   override("Query time", {"unit": "s"}), override("Serial", {"decimals": 0})],
        desc="The latest SOA probe per server."), 8, 8)

    b.row("DNS VMs")
    b.add(timeseries("CPU", [
        q(f'100 * (1 - avg by (host) (rate(node_cpu_seconds_total{{mode="idle", {NODE}}}{RATE})))', "{{host}}")],
        unit="percent", min_=0, calcs=("mean", "max"),
        links=[("Node Exporter Full", NODE_DASH + "?var-job=node&" + TIME)]), 6, 7)
    b.add(timeseries("Memory used", [
        q(f"node_memory_MemTotal_bytes{{{NODE}}} - node_memory_MemAvailable_bytes{{{NODE}}}", "{{host}}")],
        unit="bytes", min_=0, calcs=("mean", "max"), desc="Mostly named's cache."), 6, 7)
    b.add(timeseries("Network (rx + tx)", [
        q(f'sum by (host) (rate(node_network_receive_bytes_total{{{NODE}, device=~"e.*"}}{RATE}) + '
          f'rate(node_network_transmit_bytes_total{{{NODE}, device=~"e.*"}}{RATE})) * 8', "{{host}}")],
        unit="bps", calcs=("mean", "max"), desc="All physical NICs: management, the service VLAN and keepalived's."),
        6, 7)
    b.add(on_loki(timeseries("VIP moves", [
        lq(f'sum by (host) (count_over_time({KEEPALIVED} |~ "Entering MASTER STATE" [$__auto]))', "{{host}} took the VIP")],
        draw="bars", fill=70, decimals=0, calcs=("sum",), no_value="No VIP moves in range",
        desc="keepalived taking over dns-vip: a failed BIND health check, a restart or a reboot.")), 6, 7)

    b.row("Logs")
    b.add(logs("bind9", BIND_LOG,
               desc="named's own log on both servers (zone transfers, NOTIFYs, reloads, resolver trouble). Podman "
                    "logs its stderr, so Loki's level says error for every line; the text tells what it is."), 16, 12)
    b.add(logs("keepalived", KEEPALIVED, desc="VRRP state changes and BIND health-check results on both servers."),
          8, 12)

    return dashboard("dns-bind", "DNS (BIND)",
                     "dns01/02 behind dns-vip: BIND up, queries by type and rcode, recursion and cache, zone serials "
                     "and transfers, SOA probes, the VMs and the logs.",
                     b, tags=["services", "dns"], time_from="now-6h")


DASHBOARDS = {"Services/dns-bind.json": dns}
