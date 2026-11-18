# fabric-spines

The two MikroTik CRS326 spines (`m326-1` = spine-1/switch-5, `m326-2` = spine-2/switch-6) over
the RouterOS REST API. Each spine runs **one eBGP session per leaf** on the leaf's port (BGP
unnumbered over IPv6 link-local) that carries both the underlay (the leaves' VTEP loopbacks, ipv6)
and EVPN, with BFD, plus NTP client, the in-memory log and remote syslog. The spine is a plain eBGP
route forwarder: no route reflection, no VXLAN. Code: [modules/fabric/spines](../../modules/README.md#fabricspines).
`providers.tf` creates one provider instance per spine (`for_each`), each wired to its spine's
module call.

The leaves come from `modules/fabric/leaves` (the physical `fabric.leaves` plus one per host in
`nodes.proxmox`, greatfox included), shared with fabric-leaves and the services-config DNS records.
11 leaves today, so each spine has 11 sessions. Leaf IDs must be unique (checked at plan).

## What each spine gets (spine 1, ID 1)

| RouterOS object | Name / value | Why |
| --- | --- | --- |
| Routing ID | `fabric`: `10.255.240.1` (`loopback_ipv4_prefix` + spine ID) | router id of the BGP instance |
| Loopback addresses | `10.255.240.1/32` and `fd69:255:240::1/128` (no RA) on `lo` | router id; the IPv6 one is advertised to the leaves |
| IPv6 address list | `FABRIC-LOOPBACK`: `fd69:255:240::1` | what the sessions originate (`output.network`) |
| Ethernet | every leaf port: `mtu 10000`, `l2mtu 10218`, comment `leaf-<ID>` | room for the leaves' 9189-byte VXLAN packets |
| IPv6 neighbor discovery | every leaf port: RA interval `10s-30s`, no DNS; built-in `interface=all` entry disabled (imported) | leaves learn the spine's link-local from RAs; the default (3m20s–10m) stalls a booting leaf. **Required**: a new leaf port needs its entry. The `all` entry sent 30-minute default routes onto vlan5/bridge/mgmt |
| IPv6 ND prefix | `none` on every leaf port | links stay link-local only |
| BFD configuration | all leaf ports | BFD on every session |
| Switch | `switch1` `l3-hw-offloading=yes` (imported) | the underlay is routed in the switch chip |
| Routing filter | chain `LEAF-IN`: `if (afi evpn) { set scope-target 40; } accept;` | an EVPN next hop (leaf VTEP loopback) is a scope-40 BGP route; without this every EVPN route is unreachable and never passed on. EVPN only: raising the ipv6 routes' target scope too breaks it |
| BGP instance | `fabric`: `underlay_as_base` + spine ID (m326-1 701, m326-2 702), router id `fabric` | unique per spine: leaves ECMP over `701 7xx` / `702 7xx` with `bestpath as-path multipath-relax` (default instance and every VRF) |
| BGP template + connections | `LEAF` (the spine's AS, `ipv6,evpn`, next-hop `propagate`, input `LEAF-IN`, originates `FABRIC-LOOPBACK`, BFD); `leaf-<ID>` per leaf on its port, role `ebgp`, remote AS `underlay_as_base + ID` | `propagate` keeps the originating VTEP for EVPN (traffic goes leaf to leaf) and, for the ipv6 loopback routes, drops the other port's link-local and falls back to the spine's own |
| BGP timers | `keepalive_time` 1m, `hold_time` 3m on the template **and** every connection | a connection's own value wins over the template |
| NTP client | unicast, `fabric.settings.ntp_servers` (fw-wan `10.20.10.255`) | only when the list isn't empty |
| Logging | built-in `memory` action: 10,000 lines | adopted by name |
| Logging | built-in `remote` action → `fabric.settings.spine_syslog.host` (`10.5.11.101`, UDP 514, BSD syslog) + one rule per topic | only when `spine_syslog` is set |

Spine port towards leaf *ID* is `ether<ID>` unless the leaf sets `spine_uplink`: ether11–17 for the
cluster hosts, ether18/19 for `external_l3_01/02`, ether20 for greatfox, ether10 for
`external_l2_01` (42).

**Not managed here:** management/OOB (bridge, `vlan5`, ether21/22/24, the 10.20/10.5 addresses, the
default route), the Proxmox corosync ports ether1–7, system settings (identity, clock, DNS, services,
SNMP). `/interface ethernet switch l3hw-settings set ipv6-hw=yes` has no provider resource: set it by
hand on a new spine.

## Credentials

`routeros.secret.auto.tfvars` (linked from `inventory/auto.tfvars.secret/`): `routeros_password`,
plus `routeros_username` if not `admin`. The provider uses plain `http://<management_ip>` (REST,
the `www` service), so the password travels unencrypted.

## Running it

- **Changing BGP connection parameters restarts the sessions.** One spine at a time with saved
  targeted plans:

  ```sh
  tofu -chdir=roots/fabric-spines plan -target='module.spines["m326-1"]' -out=$TMPDIR/spine-1.tfplan
  tofu -chdir=roots/fabric-spines apply $TMPDIR/spine-1.tfplan
  # wait for one established session per leaf on spine 1, then the same for m326-2
  ```

  Check: `/routing bgp session print count-only where established` = number of leaves,
  `/routing route print count-only where afi=evpn and unreachable` = 0, and on a leaf
  `vtysh -c 'show bgp summary'`. Saved plans are plaintext (this root's state isn't encrypted) and
  contain the password: delete them.
- **(Re)building a spine from scratch:** remove the fabric objects by hand (BGP connections,
  templates except `default`, instance, `LEAF-IN` rule, BFD configuration, routing id, leaf-port ND
  entries and ND prefixes, `FABRIC-LOOPBACK`, the `lo` addresses), re-plan (the refresh drops the
  missing objects from state) and apply. The two singletons (`interface=all` ND entry, `switch1`)
  are adopted by the import blocks in `imports.tf`, which are no-ops once in state.
  Connections reference instance/template/chain by name, so `depends_on` orders them; a full
  redeploy without it fails with "input does not match any value of instance".
- A spine also carries a corosync ring for every PVE node: never reboot one without the
  one-at-a-time procedure.
- Removing a spine from `fabric.spines`: the provider instance shares the module's `for_each`
  (validate warns), so destroy that spine's module (`-target`) first, then remove it.
- Overrides of the timers: `keepalive_time` / `hold_time` (root variables) via `-var` or a local
  `.auto.tfvars`; keep keepalive at most a third of hold.
