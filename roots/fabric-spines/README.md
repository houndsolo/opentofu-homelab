# fabric-spines

The two MikroTik CRS326 spines (`m326-1` = spine-1/switch-5, `m326-2` = spine-2/switch-6) over
the RouterOS REST API: the **underlay** (eBGP over IPv6 link-local, one session per leaf), **EVPN
route reflection** for the overlay (iBGP, one session per leaf), BFD on both, plus NTP client, the
in-memory log and remote syslog. Code: [modules/fabric/spines](../../modules/README.md#fabricspines).
`inventory/provider-config/routeros-provider.tf` creates one provider instance per spine
(`for_each`), each wired to its spine's module call.

The leaves come from `modules/fabric/leaves` (the physical `fabric.leaves` plus one per host in
`nodes.proxmox`, greatfox included), shared with fabric-leaves and the services-config DNS records.
11 leaves today, so each spine has 22 sessions (11 underlay + 11 overlay). Leaf IDs must be unique
(checked at plan).

## What each spine gets (spine 1, ID 1)

| RouterOS object | Name / value | Why |
| --- | --- | --- |
| IPv6 address list | `BGP-LOOPBACKS`: `fd69:255:240::1` | the spine's loopback, advertised to every leaf |
| IPv6 address list | `fabric_loopbacks_ipv6`: `fd69:255:240::/64` | allows BFD for the overlay sessions |
| BFD configuration | address list `fabric_loopbacks_ipv6`; all leaf-facing ports | BFD for overlay; underlay |
| BGP instance | `default`: AS 810 (`spine_as`, or the spine's own `as`), router-id `rid-spine` | `rid-spine` is a `/routing id` entry this module doesn't create |
| IPv6 ND prefix | `none` on every leaf-facing port | links stay link-local only |
| IPv6 neighbor discovery | every leaf-facing port: RA interval `10s-30s`, no DNS | leaves learn the spine's link-local from RAs; the default (3m20s–10m) stalls a booting leaf's underlay. **Required**: a new leaf port needs its entry |
| BGP template + connections | `SPINE-eBGP-v6-LL` (AS 810, ipv6, `force-self`, advertises `BGP-LOOPBACKS`); `underlay-leaf-<ID>` per leaf, bound to the port, BFD | underlay |
| Routing filter | chain `EVPN-IN`: `set scope-target 40; accept;` | resolves EVPN next hops (leaf loopbacks) via the underlay |
| BGP template + connections | `SPINE-iBGP-EVPN` (AS 700 `overlay_as`, evpn, next-hop `propagate`, input `EVPN-IN`); `overlay-leaf-<ID>` per leaf, role `ibgp-rr`, loopback to loopback, BFD | overlay; `propagate` keeps the leaf VTEP as next hop, so traffic goes leaf to leaf |
| BGP timers | `keepalive_time` 1m, `hold_time` 3m on both templates **and** every connection | a connection's own value would otherwise ignore a template change |
| NTP client | unicast, `fabric.settings.ntp_servers` (fw-wan `10.20.10.255`) | only when the list isn't empty; an empty list leaves NTP as it is |
| Logging | built-in `memory` action: 10,000 lines, keeps logging when full | adopted by name, no import needed |
| Logging | built-in `remote` action → `fabric.settings.spine_syslog.host` (`10.5.11.101` = logs-vip, UDP 514, BSD syslog, facility daemon) + one rule per topic (`info`, `warning`, `error`, `critical`) | only when `spine_syslog` is set |

Spine port towards leaf *ID* is `ether<ID>` unless the leaf sets `spine_uplink`: ether11–17 for the
cluster hosts, ether18/19 for `external_l3_01/02`, ether20 for greatfox, ether10 for
`external_l2_01` (42).

## Credentials

`routeros.secret.auto.tfvars` (linked from `inventory/auto.tfvars.secret/`): `routeros_password`,
plus `routeros_username` if not `admin`. The provider uses plain `http://<management_ip>` (REST,
the `www` service), so the password travels unencrypted.

## Running it

```sh
tooling/walk-roots.sh fabric-spines
```

- **Changing BGP connection parameters (e.g. the timers) restarts the sessions.** Do one spine at a
  time with saved targeted plans, never a full apply or the runner:

  ```sh
  tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-1"]' -out=$TMPDIR/spine-1.tfplan
  tofu -chdir=roots/fabric-spines apply $TMPDIR/spine-1.tfplan
  # wait for 22/22 established on spine 1 and the leaves' sessions, then the same for m326-2
  ```

  Check: `/routing bgp session print count-only where established` = 22 on each spine,
  `/routing bgp connection print detail` shows the timers, and on a leaf
  `vtysh -c 'show bgp summary'`. Afterwards run a full plan. Saved plans are plaintext here (this
  root's state isn't encrypted) and contain the password: delete them.
- A spine also carries a corosync ring for every PVE node: never reboot one without the
  one-at-a-time procedure.
- Removing a spine from `fabric.spines`: the provider instance shares the module's `for_each`
  (validate warns), so destroy that spine's module (`-target`) first, then remove it.
- Overrides of the timers: `keepalive_time` / `hold_time` (root variables) via `-var` or a local
  `.auto.tfvars`; keep keepalive at most a third of hold.

## Importing existing spine config

`tooling/routeros-spine-imports.py` finds existing BGP, BFD, address-list and ND-prefix objects that
match this config exactly and imports them. It never changes the router.

```sh
tofu -chdir=roots/fabric-spines init
python3 tooling/routeros-spine-imports.py                               # preview: MATCH / UNRESOLVED / IN STATE (asks for the REST password)
python3 tooling/routeros-spine-imports.py --spine m326-1 --user admin   # one spine, other user
python3 tooling/routeros-spine-imports.py --import                      # tofu import needs the linked secret file
```

It reads `fabric` and the leaves via `tofu console` (`local.leaves`), skips what's in state, and
needs exactly one non-dynamic object per resource (zero or several = `UNRESOLVED`, no guessing;
rename on the router or in the HCL and re-run). `--import` first backs up the state to
`roots/fabric-spines/spine-state-before-import-<timestamp>.json`: not git-ignored, may contain
secrets, don't commit it.
