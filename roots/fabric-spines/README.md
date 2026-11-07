# Fabric spines

Configures RouterOS BGP, BFD, EVPN route reflection, IPv6 settings, NTP and memory logging through
`modules/fabric/spines`. Inventory is `fabric.auto.tfvars`; provider aliases
select each spine's API. APIs must be reachable before applying. Set
`routeros_password` (and optionally `routeros_username`, default `admin`) in the
[secrets file](../../inventory/README.md#secrets).

Leaves are the physical `fabric.leaves`, every cluster node and greatfox. Leaf IDs
determine default spine ports (`ether<ID>`); `spine_uplink` overrides the port
for physical leaves. Review plans against existing RouterOS configuration.

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `keepalive_time` | `"1m"` | Interval on both BGP templates and every connection |
| `hold_time` | `"3m"` | Hold timer on both templates and every connection |
| `fabric.settings.ntp_servers` | `["0.pool.ntp.org", "1.pool.ntp.org"]` | Shared spine/leaf NTP servers; override in inventory |
| `fabric.settings.leaf_ntp_vrf` | `null` | VRF the leaf NTP client runs in; spines ignore it |

Set root timer overrides in a local `.auto.tfvars` file or with `-var`.
Keep keepalive at most one third of hold time. Explicit connection values
replace the live `3m` overrides that otherwise defeat template changes.
The built-in `memory` logging action is managed with `memory-lines=10000`
and continues logging when full. The provider adopts this action by name and
updates the singleton NTP client directly; neither needs an import for adoption.
NTP defaults require DNS and outbound NTP access. An empty server list skips
management without disabling existing NTP or removing previous servers.

## Rollout

Changing connection parameters restarts BGP sessions. Apply **m326-1
(switch-5) first**, wait for all 22 sessions (11 underlay and 11 overlay) on
that spine to be Established, then apply **m326-2 (switch-6)**. Do not use a
full-root apply or the guided runner for this timer rollout, since those can
change both spines together. The operator runs these commands from the repo root:

```sh
tooling/with-secrets tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-1"]' -out=/tmp/spine-1.tfplan
tooling/with-secrets tofu -chdir=roots/fabric-spines apply /tmp/spine-1.tfplan
# Verify spine-1 and leaf reachability before planning/applying spine-2.
tooling/with-secrets tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-2"]' -out=/tmp/spine-2.tfplan
tooling/with-secrets tofu -chdir=roots/fabric-spines apply /tmp/spine-2.tfplan
```

Review each saved plan before applying; if credentials are linked into the
root, use plain `tofu` instead of the secrets wrapper. Keep saved plans private.
Targeting is for this staged rollout; afterwards review a full-root plan for
remaining changes. Apply `fabric-leaves` afterwards for neighbor-change logging
and NTP. Check NTP synchronization on both device types.

On each spine, check `/routing bgp connection print detail` and
`/routing bgp template print detail` for `keepalive-time=1m hold-time=3m`, and
`/routing bgp session print` for Established sessions with growing uptimes.
On leaves, `vtysh -c 'show bgp neighbors eth1 json'` (and `eth2`) should show
`bgpTimerLastRead` at most about 65 seconds. Observe flat drop counters for at
least one hour on all 22 underlay and 22 overlay sessions across the fabric,
and spine-to-leaf KEEPALIVEs roughly every 60 seconds. See the investigation
report's verification steps for sampler and capture scripts.

## Manual duplicate cleanup

The inventory has 11 unique leaf IDs (greatfox is the sole ID 20); the module
creates one underlay/overlay pair per leaf and two distinct BFD rules: one
matching the overlay address list and one matching leaf interfaces.
`tooling/routeros-spine-imports.py` likewise generates one candidate per object
and refuses ambiguous matches. The reported extra LEAF-20 connections and third
BFD entry have no source here and are treated as unmanaged live leftovers.

On **each spine**, inspect the live entries and compare their `.id` values to
the IDs in the corresponding OpenTofu state resources before removing anything:
`module.spines["<spine>"].routeros_routing_bgp_connection.underlay["greatfox"]`,
`.overlay["greatfox"]`, and `routeros_routing_bfd_configuration.bfd_to_overlay`
or `.bfd_to_leaves` under the same module. Preserve the state-owned entries.
If ownership is ambiguous, resolve it before removal or import. Run this cleanup
separately from the timer change, one spine at a time:

```text
/routing bgp connection print detail where name~"leaf-20"
/routing bfd configuration print detail
# Substitute the verified unmanaged RouterOS .id values below:
/routing bgp connection remove <duplicate-underlay-id>
/routing bgp connection remove <duplicate-overlay-id>
/routing bfd configuration remove <duplicate-bfd-id>
/routing bgp session print where !established
```

The report's connection items 22/23 and BFD item 2 are snapshot positions, not
stable identifiers; do not remove those positions blindly or remove all entries
matching a duplicated name. The LEAF-20 connect/closed loop should stop. Allow
old sessions to age out and investigate any remaining stale sessions separately.
