# fabric-spines

This root configures the two MikroTik RouterOS spines through their REST API.
The spines carry the **underlay** (eBGP over IPv6 link-local, one session per
leaf) and act as **EVPN route reflectors** for the overlay (iBGP, one session
per leaf). BFD runs on both kinds of session.

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

[fabric-leaves](../fabric-leaves/README.md) and the DNS records in
services-config use the same list, so the spines, the leaves and DNS always agree
on which leaves exist.

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
| BGP template | `SPINE-eBGP-v6-LL`: AS 810, IPv6, next-hop `force-self`, advertises `BGP-LOOPBACKS` | Shared settings for the underlay sessions |
| BGP connection | `underlay-leaf-<ID>` per leaf: eBGP, bound to the port, BFD on | The underlay session |
| Routing filter | chain `EVPN-IN`: `set scope-target 40; accept;` | Lets RouterOS resolve EVPN next hops (the leaf loopbacks) through the underlay routes |
| BGP template | `SPINE-iBGP-EVPN`: AS 700 (`overlay_as`), EVPN, next-hop `propagate`, input filter `EVPN-IN` | Shared settings for the overlay sessions |
| BGP connection | `overlay-leaf-<ID>` per leaf: role `ibgp-rr`, from `fd69:255:240::1` to the leaf's loopback, BFD on | The overlay session. The spine is the route reflector. |

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

## Credentials

Put the RouterOS login in the
[secrets file](../../inventory/README.md#secrets): `routeros_password`, and
`routeros_username` if it isn't `admin`. The provider connects over plain
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

```sh
tooling/walk-roots.sh fabric-spines
```

## Importing existing spine config

`tooling/routeros-spine-imports.py` finds the spine's existing objects that match
this config exactly, and imports them into state. **It never changes the
router.**

```sh
# Run from the top of the repo, with TF_CLI_CONFIG_FILE set.
tofu -chdir=roots/fabric-spines init

# Preview. Lists MATCH / UNRESOLVED / IN STATE for every resource. Prompts for the REST password.
python3 tooling/routeros-spine-imports.py

# Only one spine (repeatable), or a different REST user:
python3 tooling/routeros-spine-imports.py --spine m326-1 --user admin

# Import the matches into state. Run it through with-secrets, so that each
# `tofu import` it runs gets routeros_password (otherwise OpenTofu asks for the
# password once per import). If roots/fabric-spines links the secrets file,
# plain python3 works too.
tooling/with-secrets python3 tooling/routeros-spine-imports.py --import
```

The script asks for the REST password itself, because it reads the routers
directly. The preview doesn't need the secrets file.

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
