# fabric-spines

This root configures the two MikroTik RouterOS spines through their REST API.
The spines carry the **underlay** (eBGP over IPv6 link-local, one session per
leaf) and act as **EVPN route reflectors** for the overlay (iBGP, one session
per leaf). BFD runs on both kinds of session. The root also sets the spines'
NTP client and their in-memory log size.

The code is in [modules/fabric/spines](../../modules/README.md#fabricspines).
The provider block in `inventory/provider-config/routeros-provider.tf` uses
`for_each` to create one provider instance per spine, and each spine's module
call is wired to its own instance.

## Which leaves the spines know about

The spines get one underlay session and one overlay session for each leaf in
the shared leaf list from `modules/fabric/leaves`:

- `fabric.leaves`: the physical leaves, and
- one generated leaf for every host in `nodes.proxmox`, including the standalone
  `greatfox`.

That's 11 leaves today, so each spine has 22 BGP sessions: 11 underlay and 11
overlay. [fabric-leaves](../fabric-leaves/README.md) and the DNS records in
services-config use the same list, so the spines, the leaves and DNS always agree
on which leaves exist. Leaf IDs must be unique; the module checks this during
`plan`.

## What each spine gets

Using spine 1 (`m326-1`, ID 1) as the example:

| RouterOS object | Name / value | What it does |
| --- | --- | --- |
| IPv6 address list | `BGP-LOOPBACKS`: `fd69:255:240::1` | The spine's own loopback, which it advertises to every leaf in the underlay |
| IPv6 address list | `fabric_loopbacks_ipv6`: `fd69:255:240::/64` | All fabric loopbacks. Used to allow BFD for the overlay sessions. |
| BFD configuration | address list `fabric_loopbacks_ipv6` | BFD for the loopback-to-loopback (overlay) sessions |
| BFD configuration | every leaf-facing port | BFD for the link-local (underlay) sessions |
| BGP instance | `default`: AS 810 (`spine_as`, or this spine's own `as`), router-id `rid-spine` | `rid-spine` names a `/routing id` entry, which this module doesn't create |
| IPv6 ND prefix | `none`, on every leaf-facing port | No global prefix is advertised on the links, so they stay link-local only |
| IPv6 neighbor discovery | every leaf-facing port: RA interval `10s-30s`, no DNS advertised | Router advertisements are how a leaf learns the spine's link-local address for BGP. RouterOS's default (3m20s–10m) could stall a leaf's underlay peering for minutes after it boots. |
| BGP template | `SPINE-eBGP-v6-LL`: AS 810, IPv6, next-hop `force-self`, advertises `BGP-LOOPBACKS` | Shared settings for the underlay sessions |
| BGP connection | `underlay-leaf-<ID>` per leaf: eBGP, bound to the port, BFD on | The underlay session |
| Routing filter | chain `EVPN-IN`: `set scope-target 40; accept;` | Lets RouterOS resolve EVPN next hops (the leaf loopbacks) through the underlay routes |
| BGP template | `SPINE-iBGP-EVPN`: AS 700 (`overlay_as`), EVPN, next-hop `propagate`, input filter `EVPN-IN` | Shared settings for the overlay sessions |
| BGP connection | `overlay-leaf-<ID>` per leaf: role `ibgp-rr`, from `fd69:255:240::1` to the leaf's loopback, BFD on | The overlay session. The spine is the route reflector. |
| BGP timers | `keepalive-time=1m hold-time=3m` on both templates **and** every connection | Set explicitly everywhere; see [Inputs](#inputs) |
| NTP client | unicast, servers from `fabric.settings.ntp_servers` | Only managed when that list isn't empty |
| Logging action | the built-in `memory` action: 10,000 lines, keeps logging when full | A bigger in-memory log for troubleshooting |

`next-hop propagate` on the overlay means the spines never put themselves in the
data path. Reflected EVPN routes keep the original leaf's VTEP address as the
next hop, so VXLAN traffic goes straight from leaf to leaf.

## Which port faces which leaf

By default, the port towards leaf *ID* is `ether<ID>`. A physical leaf's
`spine_uplink` setting overrides it. With today's inventory:

| Leaf | ID | Spine port |
| --- | --- | --- |
| Cluster hosts fichina … venom | 11–17 | `ether11` – `ether17` |
| `external_l3_01`, `external_l3_02` | 18, 19 | `ether18`, `ether19` |
| `greatfox` (standalone host) | 20 | `ether20` |
| `external_l2_01` | 42 | `ether10` (set with `spine_uplink`) |

## Inputs

| Variable | Default | Purpose |
| --- | --- | --- |
| `keepalive_time` | `"1m"` | BGP keepalive interval on both templates and every connection |
| `hold_time` | `"3m"` | BGP hold time on both templates and every connection |
| `fabric.settings.ntp_servers` | `["0.pool.ntp.org", "1.pool.ntp.org"]` | NTP servers shared by spines and leaves. The inventory sets fw-wan, `10.20.10.255`. |
| `fabric.settings.leaf_ntp_vrf` | `null` | The VRF the leaves' NTP client runs in. The spines ignore it. |

- **Setting the timers.** `keepalive_time` and `hold_time` are variables of this
  root. Override them in a local `.auto.tfvars` file in this folder, or with
  `-var`, and keep the keepalive at most one third of the hold time.
- **Why every connection gets the timers.** The values are written on every
  connection as well as on the templates. A live connection with its own `3m`
  override would otherwise ignore a change to the template.
- **No imports needed.** The provider adopts the built-in `memory` logging action
  by name, and updates the single NTP client directly.
- **NTP needs a reachable server.** The public defaults need working DNS and
  outbound NTP. An empty server list skips NTP management, without disabling
  NTP or removing servers that are already configured.

## Credentials

Link `inventory/auto.tfvars.secret/routeros.secret.auto.tfvars` into this root.
It holds `routeros_password`, plus `routeros_username` if it isn't `admin`. See
[Secrets](../../inventory/README.md#secrets). The provider connects over plain
`http://<management_ip>`, so the password travels unencrypted.

## Renamed resources

Two resources in `modules/fabric/spines` were renamed:
`routeros_ipv6_firewall_addr_list.BGP-LOOPBACKS` became `.bgp_loopbacks`, and
`routeros_ipv6_nd_prefix.test` became `.leaf_uplinks`. The module has `moved`
blocks for both, so on your next plan OpenTofu just updates the addresses in
state. It reports them as "moved", not as destroy-and-create. The RouterOS
object names (`BGP-LOOPBACKS` and so on) didn't change.

## Before you run it

- Both spines must be reachable on their `management_ip`, with the REST API
  (the `www` service) enabled.
- If the spines already have BGP config, import it first (see below). Then read
  the plan carefully against what's on the router.
- **Changing BGP connection parameters restarts the sessions.** For changes like
  that, use the one-spine-at-a-time rollout below, not a full apply.

```sh
tooling/walk-roots.sh fabric-spines
```

## Rolling out timer changes, one spine at a time

Changing connection parameters, such as the timers, restarts BGP sessions. So
change one spine, check it, then do the other:

1. Apply **m326-1 (switch-5)** first.
2. Wait until all 22 of its sessions (11 underlay, 11 overlay) are Established.
3. Then apply **m326-2 (switch-6)**.

Don't use a full-root apply or the guided runner for this, because those can
change both spines at once. Run these from the top of the repo:

```sh
# Spine 1 only: save a plan, read it, then apply exactly that plan.
tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-1"]' -out=/tmp/spine-1.tfplan
tofu -chdir=roots/fabric-spines apply /tmp/spine-1.tfplan

# Check spine 1 and leaf reachability (see below) before you touch spine 2.
tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-2"]' -out=/tmp/spine-2.tfplan
tofu -chdir=roots/fabric-spines apply /tmp/spine-2.tfplan
```

- **Read each saved plan before you apply it.** The commands assume the RouterOS
  secret file is linked into the root. With the single-file setup, put
  `tooling/with-secrets` in front of each command.
- **Keep saved plans private.** They can contain secrets.
- **Afterwards, run a full plan.** `-target` is only for this staged rollout, so
  review a plan of the whole root for any remaining changes.
- **Then apply `fabric-leaves`,** for neighbor-change logging and NTP on the
  leaves, and check NTP synchronization on both kinds of device.

How to check it worked:

- **On each spine:**
  - `/routing bgp connection print detail` and
    `/routing bgp template print detail` should show
    `keepalive-time=1m hold-time=3m`.
  - `/routing bgp session print` should show Established sessions, with
    uptimes that keep growing.
- **On the leaves:** `vtysh -c 'show bgp neighbors eth1 json'` (and `eth2`)
  should show `bgpTimerLastRead` at no more than about 65 seconds.
- **Across the fabric, for at least an hour:** the drop counters should stay
  flat on all 22 underlay and 22 overlay sessions, and the spines should send
  each leaf a KEEPALIVE roughly every 60 seconds.

The sampler and capture scripts are in the investigation report's verification
steps; that report isn't in this repo.

## Cleaning up duplicate entries by hand

The inventory has 11 unique leaf IDs; `greatfox` is the only ID 20. For those,
the module creates one underlay/overlay connection pair per leaf, and two
distinct BFD rules: one matching the overlay address list, one matching the leaf
interfaces. `tooling/routeros-spine-imports.py` likewise generates one candidate
per object and refuses ambiguous matches.

So the extra LEAF-20 connections and the third BFD entry that were reported on
the live spines don't come from this repo. Treat them as unmanaged leftovers.
Before you remove anything, on **each spine**:

1. **List the live entries** and note their `.id` values.
2. **Compare them with the IDs in OpenTofu state**, for these resources under the
   same `module.spines["<spine>"]`:
   - `routeros_routing_bgp_connection.underlay["greatfox"]`
   - `routeros_routing_bgp_connection.overlay["greatfox"]`
   - `routeros_routing_bfd_configuration.bfd_to_overlay`
   - `routeros_routing_bfd_configuration.bfd_to_leaves`
3. **Keep the entries that state owns.** If it's unclear which entry is which,
   work that out before you remove or import anything.

Do this separately from the timer change, and one spine at a time:

```text
/routing bgp connection print detail where name~"leaf-20"
/routing bfd configuration print detail
# Substitute the verified unmanaged RouterOS .id values below:
/routing bgp connection remove <duplicate-underlay-id>
/routing bgp connection remove <duplicate-overlay-id>
/routing bfd configuration remove <duplicate-bfd-id>
/routing bgp session print where !established
```

The report's connection items 22/23 and BFD item 2 are positions in a snapshot,
not stable identifiers. Don't remove those positions blindly, and don't remove
every entry with a duplicated name. Once the leftovers are gone, the LEAF-20
connect/closed loop should stop. Let old sessions age out, and investigate any
stale sessions that remain separately.

## Importing existing spine config

`tooling/routeros-spine-imports.py` finds the spine's existing BGP, BFD,
address-list and ND-prefix objects that match this config exactly, and imports
them into state. **It never changes the router.**

```sh
# Run from the top of the repo, inside nix-shell (or with TF_CLI_CONFIG_FILE set).
tofu -chdir=roots/fabric-spines init

# Preview. Lists MATCH / UNRESOLVED / IN STATE for every resource. Prompts for the REST password.
python3 tooling/routeros-spine-imports.py

# Only one spine (repeatable), or a different REST user:
python3 tooling/routeros-spine-imports.py --spine m326-1 --user admin

# Import the matches into state. Each `tofu import` it runs needs routeros_password,
# which comes from the linked routeros.secret.auto.tfvars. (With the single-file
# setup, run the script through tooling/with-secrets instead.)
python3 tooling/routeros-spine-imports.py --import
```

The script asks for the REST password itself, because it reads the routers
directly. The preview doesn't need any secret file.

How it works:

1. It reads `fabric` and the leaf list from the root with `tofu console`, and
   skips anything already in state.
2. It reads each RouterOS menu over REST (`http://<management_ip>/rest/...`) and
   looks for **exactly one** non-dynamic object with the configured name or
   values. With zero matches, or more than one, it reports `UNRESOLVED` and
   doesn't guess.
3. With `--import`, it first saves a backup of the current state as
   `roots/fabric-spines/spine-state-before-import-<timestamp>.json`, then runs
   `tofu import` for each match. That backup can contain secrets, and Git does
   **not** ignore it, so keep it private and don't commit it.

If an object exists on the router under a different name than the one in the HCL,
it shows up as unresolved. Rename it on the router, or change the HCL to match,
then run the script again.
