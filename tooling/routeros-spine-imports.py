#!/usr/bin/env python3
"""Import existing spine objects. Run from the repository root.

python3 import-spines.py             # Preview only
python3 import-spines.py --import    # Write state; never apply router changes

Requires Python 3 and initialized OpenTofu. REST credentials are prompted.
The OpenTofu provider must also have valid credentials configured.
Matches exact configured names/values, never chooses the first ambiguous match.
If old RouterOS names differ, align HCL with those names before importing.
"""
import argparse
import base64
import datetime
import getpass
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request


def tofu(root, *args, input=None):
    return subprocess.run(['tofu', f'-chdir={root}', *args], input=input,
                          text=True, check=True, capture_output=True).stdout


def same_address(a, b):
    try:
        return ipaddress.ip_network(a, strict=False) == ipaddress.ip_network(b, strict=False)
    except ValueError:
        return a == b


def parse_console(output):
    # OpenTofu can put provider warnings before or after the result.
    for line in output.splitlines():
        try:
            value = json.loads(line.strip())
            if isinstance(value, str):
                value = json.loads(value)
            if isinstance(value, dict) and 'fabric' in value and 'leaves' in value:
                return value
        except (ValueError, TypeError):
            continue
    raise ValueError('No inventory JSON found in tofu console output. Run tofu '
                     '-chdir=roots/fabric-spines console and enter '
                     "jsonencode({fabric = var.fabric, leaves = local.leaves}) "
                     'to inspect the diagnostic. No imports were attempted.')


def current_resources(root):
    try:
        return set(tofu(root, 'state', 'list').splitlines())
    except subprocess.CalledProcessError as error:
        diagnostic = ((error.stderr or '') + (error.stdout or '')).lower()
        if 'no state file was found' in diagnostic or 'no state file found' in diagnostic:
            print('No current state file. Starting with empty state.')
            return set()
        raise


def candidates(fabric, leaves, spine):
    settings = fabric['settings']
    prefix = ipaddress.ip_network(settings['loopback_ipv6_prefix'])
    loopback = str(prefix.network_address + int(str(spine['id']), 16))
    def exact(**fields):
        return lambda row: all(str(row.get(k, '')) == str(v) for k, v in fields.items())
    def address_entry(list_name, address):
        return lambda row: row.get('list') == list_name and same_address(row.get('address', ''), address)
    yield 'routeros_ipv6_firewall_addr_list.BGP-LOOPBACKS', 'ipv6/firewall/address-list', address_entry('BGP-LOOPBACKS', loopback)
    yield 'routeros_ipv6_firewall_addr_list.fabric_loopbacks_ipv6', 'ipv6/firewall/address-list', address_entry('fabric_loopbacks_ipv6', str(prefix))
    yield 'routeros_routing_bgp_instance.main', 'routing/bgp/instance', exact(name='default')
    yield 'routeros_routing_bgp_template.underlay', 'routing/bgp/template', exact(name='SPINE-eBGP-v6-LL')
    yield 'routeros_routing_bgp_template.overlay', 'routing/bgp/template', exact(name='SPINE-iBGP-EVPN')
    yield 'routeros_routing_filter_rule.evpn_chain', 'routing/filter/rule', exact(chain='EVPN-IN', rule='set scope-target 40; accept;')
    yield 'routeros_routing_bfd_configuration.bfd_to_overlay', 'routing/bfd/configuration', exact(**{'address-list': 'fabric_loopbacks_ipv6'})
    interfaces = {leaf.get('spine_uplink') or f"ether{leaf['id']}" for leaf in leaves.values()}
    def bfd_leaves(row):
        value = row.get('interfaces', '')
        return set(value if isinstance(value, list) else value.split(',')) == interfaces
    yield 'routeros_routing_bfd_configuration.bfd_to_leaves', 'routing/bfd/configuration', bfd_leaves
    for key, leaf in leaves.items():
        index = json.dumps(key)
        for kind in ('underlay', 'overlay'):
            yield f'routeros_routing_bgp_connection.{kind}[{index}]', 'routing/bgp/connection', exact(name=f"{kind}-leaf-{leaf['id']}")
        interface = leaf.get('spine_uplink') or f"ether{leaf['id']}"
        yield f'routeros_ipv6_nd_prefix.test[{index}]', 'ipv6/nd/prefix', exact(interface=interface, prefix='none')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--root', default='roots/fabric-spines')
    parser.add_argument('--spine', action='append', help='Limit to this inventory key; repeat for more')
    parser.add_argument('--user', default='admin')
    parser.add_argument('--import', dest='execute', action='store_true')
    args = parser.parse_args()
    root = str(Path(args.root).resolve())
    expression = 'jsonencode({fabric = var.fabric, leaves = local.leaves})\n'
    # Console returns an HCL quoted string, containing JSON.
    config = parse_console(tofu(root, 'console', '-no-color', input=expression))
    fabric, leaves = config['fabric'], config['leaves']
    spines = fabric['spines']
    selected = args.spine or list(spines)
    unknown = set(selected) - set(spines)
    if unknown:
        parser.error(f'Unknown spine keys: {sorted(unknown)}')
    state = current_resources(root)
    password = getpass.getpass(f'RouterOS REST password for {args.user}: ')
    authorization = 'Basic ' + base64.b64encode(f'{args.user}:{password}'.encode()).decode()
    # Do not forward credentials through redirects or environment HTTP proxies.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    pending, unresolved = [], 0
    for name in selected:
        spine = spines[name]
        host = spine['management_ip'].rstrip('/')
        base = host if '://' in host else 'http://' + host
        cache = {}
        for suffix, endpoint, match in candidates(fabric, leaves, spine):
            address = f'module.spines[{json.dumps(name)}].{suffix}'
            if address in state:
                print(f'IN STATE  {address}')
                continue
            if endpoint not in cache:
                request = urllib.request.Request(f'{base}/rest/{endpoint}', headers={'Authorization': authorization})
                with opener.open(request, timeout=20) as response:
                    cache[endpoint] = json.load(response)
                if not isinstance(cache[endpoint], list):
                    raise ValueError(f'{name}: unexpected REST response for {endpoint}')
            matches = [row for row in cache[endpoint] if match(row) and str(row.get('dynamic', 'false')).lower() != 'true']
            if len(matches) != 1 or not matches[0].get('.id'):
                print(f'UNRESOLVED ({len(matches)} matches)  {address}')
                unresolved += 1
                continue
            object_id = matches[0]['.id']
            print(f'MATCH {object_id:>6}  {address}')
            pending.append((address, object_id))
    print(f'\n{len(pending)} imports ready; {unresolved} unresolved.')
    if not args.execute:
        print('Preview only. Run again with --import to import the matches.')
        return 0
    if pending:
        # Save a private backup outside the root module; never overwrite one.
        existing = tofu(root, 'state', 'pull') if state else None
        if existing:
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
            backup = Path(root) / f'spine-state-before-import-{stamp}.json'
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as output:
                output.write(existing)
            print(f'State backup: {backup} (keep private; state can contain secrets)')
        for address, object_id in pending:
            print(f'IMPORT {address}', flush=True)
            subprocess.run(['tofu', f'-chdir={root}', 'import', '-no-color', address, object_id], check=True)
    print('Imports complete. Review: tofu -chdir=roots/fabric-spines plan')
    return 1 if unresolved else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, urllib.error.URLError) as error:
        print(f'Error: {error}', file=sys.stderr)
        sys.exit(1)
