"""Interface throughput from snmp_exporter's if_mib, built by custom.py."""
from custom import (Board, dashboard, mapping, organize, override, q, query_var,
                    state_timeline, steps, table, timeseries)
from theme import ACCENT, ACCENT2, OK, WARN, ERROR, TEXT_MUTED

JOBS = 'snmp-fs-switches|snmp-mikrotik-access|snmp-spines|snmp-wlc|snmp-mikrotik-hr'
BASE = f'job=~"{JOBS}"'
SEL = BASE + ',host=~"${device:regex}",ifIndex=~"${interface:regex}"'
LEGEND = '{{host}} · {{ifName}} · {{ifAlias}}'
SNMP_LINK = {"type": "dashboards", "tags": ["snmp"], "asDropdown": True,
             "title": "SNMP dashboards", "includeVars": True, "keepTime": True}


def rate(metric):
    return f'rate({metric}{{{SEL}}}[$__rate_interval])'


def throughput():
    b = Board()
    incoming, outgoing = rate('ifHCInOctets') + ' * 8', rate('ifHCOutOctets') + ' * 8'
    # ifSpeed saturates at 2^32-1 on fast links. Prefer valid ifHighSpeed (Mbit/s),
    # falling back to nonzero, unsaturated ifSpeed. Unknown speeds stay unknown.
    speed = (f'((ifHighSpeed{{{SEL}}} > 0) * 1000000 or on(host, instance, ifIndex) '
             f'(ifSpeed{{{SEL}}} > 0 and ifSpeed{{{SEL}}} < 4294967295))')
    colors = [override('.* · in$', {'color': {'mode': 'fixed', 'fixedColor': ACCENT2}}, regex=True),
              override('.* · out$', {'color': {'mode': 'fixed', 'fixedColor': ACCENT}}, regex=True)]
    b.add(timeseries('Interface throughput', [q(incoming, LEGEND + ' · in'),
                                             q(f'-({outgoing})', LEGEND + ' · out')],
                     unit='bps', overrides=colors, desc='Ingress above zero; egress below zero. Device perspective.'), 24, 10)
    b.add(timeseries('Link utilisation', [
        q(f'100 * ({incoming}) / on(host, instance, ifIndex) {speed}', LEGEND + ' · in'),
        q(f'100 * ({outgoing}) / on(host, instance, ifIndex) {speed}', LEGEND + ' · out')],
        unit='percent', min_=0, overrides=colors,
        thresholds=steps((OK, None), (WARN, 70), (ERROR, 90)),
        desc='Each full-duplex direction divided by link speed. ifHighSpeed preferred on fast links; '
             'ifSpeed fallback. Zero/unknown speed omitted.'), 12, 9)
    b.add(state_timeline('Operational status', [q(f'ifOperStatus{{{SEL}}}', LEGEND)],
        mappings=mapping(**{'1': ('Up', OK), '2': ('Down', ERROR), '3': ('Testing', WARN),
                            '4': ('Unknown', TEXT_MUTED), '5': ('Dormant', WARN),
                            '6': ('Not present', TEXT_MUTED), '7': ('Lower layer down', ERROR)})), 12, 9)
    for title, metrics in [('Errors', ('ifInErrors', 'ifOutErrors')),
                           ('Discards', ('ifInDiscards', 'ifOutDiscards'))]:
        b.add(timeseries(title, [q(rate(metrics[0]), LEGEND + ' · in'),
                                q(rate(metrics[1]), LEGEND + ' · out')], unit='pps', min_=0,
                         overrides=colors, desc='Counter rates per second; both directions positive.'), 12, 8)
    links = [{'title': title, 'url': f'/d/{uid}?var-instance=${{__field.labels.instance}}'
              '&var-ifName=${__data.fields.Interface}&${__url_time_range}'}
             for title, uid in [('Device summary', 'snmp-device-summary'),
                                ('Interface detail', 'snmp-interface-detail'), ('MikroTik', 'mikrotik-snmp')]]
    b.add(table('Busiest interfaces', [q(f'topk($top, ({incoming}) + ({outgoing}))', table=True)],
        unit='bps', sort='Total bps', desc_sort=True,
        desc='Instant ranking by ingress + egress bps over the rate interval, within the selected interfaces.',
        transformations=[organize(exclude=['Time', '__name__', 'job', 'ifIndex'],
                                  rename={'host': 'Device', 'ifName': 'Interface', 'ifAlias': 'Alias',
                                          'ifDescr': 'Description', 'Value': 'Total bps'})],
        overrides=[override('Total bps', {'links': links}),
                   override('instance', {'custom.hidden': True})]), 24, 9)
    device = query_var('device', 'Device', f'label_values(ifHCInOctets{{{BASE}}}, host)')
    interface = query_var('interface', 'Interface', '')
    # A synthetic display label also covers empty aliases and makes names visible.
    query = (f'query_result(label_join(count by (ifIndex, ifName, ifAlias) '
             f'(ifHCInOctets{{{BASE},host=~"${{device:regex}}"}}), "display", " · ", "ifName", "ifAlias"))')
    interface.update(query={'query': query, 'refId': 'PrometheusVariableQueryEditor-VariableQuery'},
                     definition=query, regex='/display="(?<text>[^"]*)".*ifIndex="(?<value>[^"]*)"/')
    top = {'name': 'top', 'label': 'Top N', 'type': 'custom', 'query': '5,10,20,50',
           'current': {'text': '10', 'value': '10'}, 'options': [], 'multi': False, 'includeAll': False}
    return dashboard('snmp-throughput', 'SNMP interface throughput',
        'Interface traffic, link utilisation, errors and operational state. Interface indices are local '
        'to each device; when selecting several devices, selected indices apply to each device.',
        b, tags=['snmp', 'network'], variables=[device, interface, top], extra_links=[SNMP_LINK])


DASHBOARDS = {'Network/snmp-throughput.json': throughput}
