# fabric-leaves

Pushes the EVPN/VXLAN config to every leaf through the VyOS HTTPS API.
[modules/fabric/leaf](../../modules/README.md#fabricleaf) renders plain VyOS `set` commands from
the inventory, sent as one `vyoscmd_commands` resource per leaf (`<leaf>-system`, `save = true`:
written to `/config/config.boot`, so a reboot keeps it). The plan shows the exact CLI. The excerpts
below are from the leaf on venom (ID 17), 748 commands in total.

## Which leaves

| Leaves | From | Role | Access interface |
| --- | --- | --- | --- |
| `external_l2_01` (42), `external_l3_01` (18), `external_l3_02` (19) | `fabric.leaves` (physical) | as configured | as configured |
| one per host in `nodes.proxmox`: IDs 11–17 and standalone greatfox (20) | `modules/fabric/leaves` | `proxmox` | `eth3` (spines + 1) |

`modules/fabric/leaves` is shared with fabric-spines, the services-config DNS records and
monitoring-config's scrape targets, so they all see the same leaves. API endpoint: host *ID* in
`fabric.settings.management_prefix` (`https://10.20.10.17`), key from `vyos_api_key` or
`VYOS_API_KEY` (linked `vyos.secret.auto.tfvars`), TLS unverified (self-signed).

## Which VRFs each leaf gets

Every VRF (L3VNI) whose `roles` include the leaf's role, with all its VLANs (L2VNIs), from
[`vnis.auto.tfvars`](../../inventory/auto.tfvars/vnis.auto.tfvars):

| Role | VRFs (L3VNI) | VLANs |
| --- | --- | --- |
| `proxmox` | `lylat-edge` (5100), `lylat-app` (5200), `lylat-dns` (5300), `lylat-obs` (5400), `lylat-telemetry` (5500), `lylat-data` (5600), `lylat-lan` (6900), `lylat-ai` (6700) | 2, 8, 9, 10, 11, 12, 1201, 1301, 1401, 1501, 1601 |
| `external_l2` | `lylat-lan`, `lylat-ai` | 9, 10, 11, 12 |
| `external_l3` | `lylat-external` (6666) | none (routed only) |

The `proxmox` leaves also get the HA L2VNIs from
[`l2vnis.auto.tfvars`](../../inventory/auto.tfvars/l2vnis.auto.tfvars) (VLAN 10aa / VNI 50aa,
bridged only, no VRF, no gateway); greatfox's leaf only those with `on_standalone` (none today).

## What gets configured

### Interfaces

```text
# Generated proxmox leaves only: bind names to the MACs fabric-vms gave the NICs (modules/fabric/macs).
set interfaces ethernet eth1 hw-id 02:00:00:17:00:01
# Spine links: MTU, no addresses. BGP "interface" peering learns the spine's link-local from the
# spine's RAs (every 10-30 s); the leaf sends none.
set interfaces ethernet eth1 description 'p2p-spine-1'
set interfaces ethernet eth1 mtu '9189'
# Loopback: VTEP (IPv6) and router-ID (IPv4).
set interfaces dummy dum240 address 'fd69:255:240::17/128'
set interfaces dummy dum240 address '10.255.240.17/32'
# Access trunk to the host's VMs (joins vmbr4000).
set interfaces ethernet eth3 description 'link to tenant VLANs'
set interfaces ethernet eth3 mtu '9119'
```

### BGP: underlay and overlay

```text
set protocols bgp system-as 700
set protocols bgp parameters router-id 10.255.240.17
set protocols bgp address-family ipv6-unicast network fd69:255:240::17/128   # the only underlay route it sends
set protocols bgp address-family l2vpn-evpn advertise-all-vni
set protocols bgp address-family l2vpn-evpn flooding head-end-replication     # no multicast
set protocols bgp neighbor eth1 interface v6only peer-group 'spine_underlay'  # one per spine port
set protocols bgp neighbor fd69:255:240::1 peer-group 'spine_overlay'         # one per spine loopback
# Underlay: eBGP, seen by the spine as AS 717 (leaf_underlay_as_base 700 + ID); exports only own routes.
set protocols bgp peer-group spine_underlay remote-as 'external'
set protocols bgp peer-group spine_underlay local-as 717 no-prepend replace-as
set protocols bgp peer-group spine_underlay address-family ipv6-unicast route-map export 'local_as_rm'
set protocols bgp peer-group spine_underlay bfd
# Overlay: iBGP to the spines (route reflectors) from the loopback.
set protocols bgp peer-group spine_overlay remote-as 'internal'
set protocols bgp peer-group spine_overlay update-source 'dum240'
set protocols bgp peer-group spine_overlay address-family l2vpn-evpn route-map export 'RM-EVPN-SPINE-EXPORT'
set protocols bgp peer-group spine_overlay bfd
```

`local-as ... replace-as` keeps AS 700 for the overlay while each leaf has its own underlay AS, so
eBGP's AS-path loop check doesn't drop one leaf's loopback at another.

### VXLAN, bridge and anycast gateway

One VXLAN device (`vxlan0`, external/single-device mode) and one VLAN-aware bridge (`br0`); every
VNI is a VLAN on `br0` mapped to its VNI:

```text
set interfaces vxlan vxlan0 parameters external
set interfaces vxlan vxlan0 parameters nolearning          # MACs come from EVPN
set interfaces vxlan vxlan0 source-address 'fd69:255:240::17'
set interfaces bridge br0 member interface vxlan0 disable-learning
set interfaces vxlan vxlan0 vlan-to-vni 1300 vni '5300'    # L3VNI of lylat-dns
set interfaces bridge br0 vif 1300 vrf 'lylat-dns'
set interfaces vxlan vxlan0 vlan-to-vni 8 vni '9008'       # L2VNI (VNI = 9000 + VLAN for the classic VLANs)
set interfaces bridge br0 vif 8 vrf 'lylat-dns'
set interfaces bridge br0 member interface eth3 allowed-vlan '8'
# Anycast gateway: same IP and MAC on every leaf.
set interfaces pseudo-ethernet peth9008 source-interface 'br0.8'
set interfaces pseudo-ethernet peth9008 address '10.8.0.1/16'
set interfaces pseudo-ethernet peth9008 address 'fd69:9008::1/64'   # anycast_gw_ipv6, DAD off
set interfaces pseudo-ethernet peth9008 mac '02:00:00:00:08:01'
set interfaces pseudo-ethernet peth9008 anycast-gateway
```

An L2VNI with `router_advert = true` (the zone segments, e.g. `peth5201`) also sends RAs: no SLAAC
(`no-autonomous-flag`), router lifetime 0, an RFC 4191 route for `fd69::/16`.

### VRFs and route-targets

```text
set vrf name lylat-dns table 5300
set vrf name lylat-dns vni 5300
set vrf name lylat-dns protocols bgp address-family l2vpn-evpn route-target export '700:5300'
set vrf name lylat-dns protocols bgp address-family l2vpn-evpn route-target import '700:5200'   # one line per imported VRF
# Local leaking between VRFs on the leaf (IPv4 VPN; same for ipv6-unicast):
set vrf name lylat-dns protocols bgp address-family ipv4-unicast route-target vpn import '700:5100 700:5200 700:5400 700:5600 700:6900 700:6700 700:6666'
set vrf name lylat-dns protocols bgp address-family ipv4-unicast redistribute connected route-map 'RM-LYLAT-DNS-CONNECTED-TO-BGP'
set vrf name lylat-dns protocols bgp address-family l2vpn-evpn advertise ipv4 unicast route-map 'RM-LYLAT-DNS-BGP-TO-EVPN'
```

Importing another VRF's route-target also enables downstream VNI between them
([DVNI](../../README.md#downstream-vni-dvni)). A VRF with `import_ipv4_vpn`/`export_vpn_ipv4` true
needs `ipv4_rt_imports`/`ipv4_rt_exports`; with both false it gets no VPN lines (isolated, e.g.
`lylat-telemetry`).

### Routing policy

| Policy | Applied to | What it does |
| --- | --- | --- |
| `local_as_rm` (as-path list `local_as_export`, `^$`) | underlay export | only routes the leaf originated (its VTEP); a leaf is never transit |
| `PL-<VRF>-L2VNI-SUBNETS` / `PL6-…` | prefix lists | the VRF's VLAN subnets (lylat-dns: `10.53.0.0/16`, `10.8.0.0/16`) |
| `RM-<VRF>-CONNECTED-TO-BGP` | redistribute connected | only the VLAN subnets; a VRF without VLANs: everything if external, nothing otherwise |
| `RM-<VRF>-BGP-TO-LOCAL-VPN` | VPN export | same filter |
| `RM-<VRF>-BGP-TO-EVPN` | type-5 advertisement | denies `0.0.0.0/0` and `::/0` in every VRF but `lylat-external`, so only the border leaves originate the default |
| `RM-EVPN-SPINE-EXPORT` | EVPN export to the spines | denies type-5 for each VRF's own VLAN subnets (hosts are reachable by type-2, every leaf has the gateway subnet); permits the rest |
| `block_local_as_rm` | nothing | defined, unused |

### System, monitoring, logs

```text
set system host-name 'LEAF-17'
set system ip multipath layer4-hashing
set service ntp server '10.20.10.255'        # fabric.settings.ntp_servers (fw-wan), from VRF mgmt;
set service ntp vrf 'mgmt'                   # the image's time1-3.vyos.net / 0-1.pool.ntp.org are deleted
set service monitoring prometheus node-exporter listen-address '10.20.10.17'   # + frr-exporter, VRF mgmt
set system syslog remote 10.20.11.34 port '514'   # leaf_syslog: loki01-03 mgmt addresses, TCP, RFC 5424
```

## Running it

The leaf VMs must be running ([fabric-vms](../fabric-vms/README.md)) and the physical leaves
reachable on their management addresses.

```sh
tooling/walk-roots.sh fabric-leaves
```

- **`set` never removes.** After removing or renumbering a VLAN/VRF, check the device
  (`show configuration commands | grep <thing>`) that the old config is gone.
- VRF names max 15 characters (VyOS rejects the whole batch with HTTP 400); the `vnis` validation
  catches it at plan.
- A plan right after an apply may show `in_sync = false -> true`: provider bookkeeping, one more
  apply settles it.
- greatfox off: `-exclude='module.leaf["greatfox"]'`, and apply its leaf once it's back, or it keeps
  the old config.

## Checking the fabric

```text
show bgp summary                     # underlay + overlay sessions
show bgp l2vpn evpn summary          # EVPN sessions to both spines
show bgp l2vpn evpn route vni 9008   # EVPN routes of one VNI
show evpn mac vni 9008               # MACs: local, or remote with their VTEP
show vrf vni                         # L3VNI per VRF
show bfd peers
show ip route vrf lylat-dns
```
