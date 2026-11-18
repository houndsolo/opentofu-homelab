# OpenTofu homelab

Builds and configures the lylat.space homelab with [OpenTofu](https://opentofu.org/). The lab is
described once in [`inventory/`](inventory/README.md) (hosts and IDs, VRFs and VLANs, VMs, VIPs,
DNS records, software versions); independent **roots** read it and build one layer each:

- **Proxmox VE hosts**: NICs, LACP bond, bridges, VLAN interfaces; datacenter/DNS/time settings.
- **EVPN/VXLAN fabric**: one VyOS leaf VM (`vtep-<host>`) per Proxmox host, three physical VyOS
  leaves, and two MikroTik RouterOS spines (eBGP: underlay and EVPN on one session per link).
- **Service VMs**: DNS (BIND in Podman), DHCP (VyOS, HA pair), monitoring (Prometheus,
  Alertmanager, Grafana, Loki, Mimir), Patroni Postgres, NetBox, Valkey, dark-triage, nginx
  reverse proxy pair. Configured by `services-config` and `monitoring-config`.
- **Workload VMs**: ordinary VMs from the same VM module.

## The lab at a glance

```text
        ┌─────────────┐                  ┌─────────────┐
        │   spine-1   │                  │   spine-2   │     RouterOS spines
        └──────┬──────┘                  └──────┬──────┘     (m326-1, m326-2)
               │     every leaf has one link to each spine
               └────────────────┬───────────────┘
     ┌─────────────┬────────────┴──┬───────────────┬────────────────┐
 vtep-fichina   vtep-venom        ...           LEAF-42         LEAF-18, LEAF-19
 VyOS VM on     VyOS VM on    (one VM per      physical,       physical,
 host fichina   host venom    Proxmox host)    external_l2     external_l3
                   │ eth3
               vmbr4000        VLAN-aware bridge inside the Proxmox host
                   │
       ┌───────────┼───────────┐
     dns01       dhcp01      pg01   ...    VMs; each NIC is tagged with a VLAN
```

VM NICs plug into the host's `vmbr4000` with a VLAN tag. The host's leaf VM is the anycast
gateway for those VLANs and carries them across the fabric as VXLAN.

## Repository layout

| Directory | Contents |
| --- | --- |
| [inventory/](inventory/README.md) | The values you edit, variable schemas, provider config, version pins, SSH public keys. Symlinked into the roots. |
| [roots/](roots/README.md) | One deployable folder per layer; you run `tofu` here. Each has its own local state. |
| [modules/](modules/README.md) | Shared logic: VM, host networking, leaf/spine config, DHCP, monitoring |
| [providers/](providers/README.md) | Git submodules: source of the custom `proxmox`, `vyoscmd` and `routeros` providers |
| [ansible/](ansible/README.md) | Hand-run Proxmox host chores (bashrc, popup patch, smartd, apt upgrades, rolling reboot); inventory generated from `inventory/auto.tfvars/nodes.auto.tfvars` |
| [tooling/](tooling/README.md) | Provider build, `walk-roots.sh` runner, `with-secrets`, the Proxmox network import helper, tests |
| [examples/](examples/README.md) | Commented example values; nothing loads them |
| `shell.nix`, `.envrc` | Dev shell (OpenTofu, Python + `python-hcl2`, git, Ansible, `TF_CLI_CONFIG_FILE`) via direnv or `nix-shell`. Go for provider builds is in `tooling/build-shell.nix`. |

Registry providers also in use: `hashicorp/dns`, `hashicorp/random` (services-config,
monitoring-config), `vancluever/acme` (certs).

## Network design

### Underlay and overlay

- **One eBGP session per leaf-spine link** over IPv6 link-local only (BGP unnumbered, FRR
  `neighbor ethN interface v6only`); no addresses on the links. It carries both address families;
  BFD on every session. No iBGP, no route reflectors, no loopback sessions.
- **AS numbers**: every leaf and spine is `underlay_as_base` (700) + its ID: spines 701/702, venom
  (17) is AS 717, in the default and every VRF BGP instance.
- **Underlay** (ipv6-unicast): a leaf advertises only its loopback `/128` (its VTEP) and is never
  transit.
- **Overlay** (l2vpn-evpn): the spines pass EVPN routes on with the originating VTEP as next hop,
  so VXLAN goes leaf to leaf. A leaf never sends a spine-learned route back to a spine; it uses both
  spines' paths (`bestpath as-path multipath-relax`). L2VNI route targets are explicit
  `<route_target_as>:<VNI>` (`700:9008`), because FRR would otherwise derive them from each leaf's
  own AS.
- **Data plane**: VXLAN over IPv6 from the leaf loopback, head-end replication (no underlay
  multicast). One external-mode `vxlan0` per leaf with VLAN-to-VNI mappings.

### VRFs, VLANs and VNIs

- **L3VNI** = a VRF; routed traffic between leaves uses it (symmetric IRB).
- **L2VNI** = one VLAN/subnet in a VRF, stretched to every leaf that carries the VRF, with a
  distributed anycast gateway (same IP and MAC on every leaf).
- **Leaf roles** (`proxmox`, `external_l2`, `external_l3`) select which leaves get a VRF.
- **Route-targets** are written out per VRF and decide which VRFs reach each other (see
  [DVNI](#downstream-vni-dvni)).

Source of truth: [`vnis.auto.tfvars`](inventory/auto.tfvars/vnis.auto.tfvars).

| VRF | L3VNI | Leaf roles | L2VNIs (VLAN: subnet) |
| --- | --- | --- | --- |
| `lylat-edge` | 5100 | proxmox | 2: 10.2.0.0/16 (proxy VIP 10.2.11.107) |
| `lylat-app` | 5200 | proxmox | 1201: 10.52.0.0/16 (Grafana, NetBox, dark-triage) |
| `lylat-dns` | 5300 | proxmox | 1301: 10.53.0.0/16; 8: 10.8.0.0/16 (DNS VIP 10.8.53.53, VMs .1/.2) |
| `lylat-obs` | 5400 | proxmox | 1401: 10.54.0.0/16 (Prometheus, Loki, Mimir) |
| `lylat-telemetry` | 5500 | proxmox | 1501: 10.55.0.0/16 (scrapes and log pushes; isolated) |
| `lylat-data` | 5600 | proxmox | 1601: 10.56.0.0/16 (Postgres, Valkey) |
| `lylat-lan` | 6900 | proxmox, external_l2 | 9, 10, 11: 10.9/10.10/10.11.0.0/16 |
| `lylat-ai` | 6700 | proxmox, external_l2 | 12: 10.12.0.0/16 |
| `lylat-external` | 6666 | external_l3 | none (routed only; the only VRF that sends 0.0.0.0/0 into EVPN; fw-wan's VRF has the same name) |

Every gateway is `.0.1`. Numbering:

- **Zone VRFs** (lylat-edge ... lylat-data, zone id Z = 51-56, DT-090): L3VNI Z00, one segment
  L2VNI Z01 on VLAN Z01 - 4000, `10.Z.0.0/16`, IPv6 gateway `fd69:Z01::1/64`.
- **Older VLANs**: L2VNI = 9000 + VLAN (VLAN 8 = 9008).
- **HA peer segments**: standalone L2VNIs without a VRF, VLAN 10aa / VNI 50aa / `10.50.aa.0/24`
  ([`l2vnis.auto.tfvars`](inventory/auto.tfvars/l2vnis.auto.tfvars)).

### MTU

| Where | MTU |
| --- | --- |
| Tenant side: VM NICs, leaf access port, `vxlan0`, `br0` and its VLANs | 9119 (`vxlan_mtu`) |
| Underlay side: leaf-spine links, loopback | 9189 (`outer_mtu`) |

70 bytes = VXLAN-over-IPv6 overhead: IPv6 (40) + UDP (8) + VXLAN (8) + inner Ethernet (14).

### Downstream VNI (DVNI)

When VRF A imports VRF B's route-target, the ingress leaf encapsulates with B's L3VNI and the
egress leaf drops the packet straight into B; return traffic uses A's L3VNI
([FRR docs](https://docs.frrouting.org/en/latest/bgp.html#evpn-downstream-vni)). There is no `dvni`
variable: add the other VRF's RT to `evpn_rt_imports`. Example: `lylat-dns` imports `700:5100`,
`700:5200`, `700:6900`, `700:6666` and the other zones. This data plane needs the single
`vxlan0` device. Minimal pair: [`examples/auto.tfvars/vnis.auto.tfvars`](examples/auto.tfvars/vnis.auto.tfvars)
(`services` 10000 on `proxmox` leaves, `lan` 20000 on `external_l2`, reciprocal imports).

When testing:

- Importing an RT doesn't bypass routing policy or firewalls, and only selects routes some leaf
  actually advertises.
- Leaves deliberately send the spines **no** type-5 routes for their own L2VNI subnets; those
  hosts are reachable via type-2. Check the EVPN routes actually advertised and imported.

## Before you start

OpenTofu configures these but doesn't create them:

- **Proxmox VE cluster** with node names matching
  [`nodes.auto.tfvars`](inventory/auto.tfvars/nodes.auto.tfvars), plus the standalone host
  `greatfox`.
- **Storage**: `ceph_rbd` for VM disks; CephFS storage `cephfs` with the *Import* and *Snippets*
  content types.
- **VyOS image** in `cephfs:import/` and the cloud-init snippet `cephfs:snippets/vyos_api.yml`
  that enables the VyOS HTTPS API with your key.
- **Proxmox API tokens** for the cluster and `greatfox`, and root SSH to the nodes (the provider
  uses SSH for some operations).
- **RouterOS spines** reachable on their management IPs with the REST API enabled.
- **Reachability** from the OpenTofu machine to Proxmox (`10.20.7.x`), spines (`10.20.0.x`),
  leaves (`10.20.10.x`), service VMs (`10.20.11.x`, `10.20.53.x`, `10.20.67.x`), and TCP 53 on
  the primary DNS server (`10.8.53.1`).
- **Tools**: Nix (direnv + nix-direnv, or `nix-shell`), or by hand: OpenTofu >= 1.13.0, Python 3
  with `python-hcl2` >= 7.3.1, git, Go >= 1.26 (provider builds only).
- **GitHub SSH access** for the provider submodules (HTTPS alternative in
  [providers/](providers/README.md)).

## Getting started

```sh
git submodule update --init --recursive      # provider sources
direnv allow                                 # or: nix-shell; sets TF_CLI_CONFIG_FILE to the local mirror
tooling/build-all                            # build + install the custom providers (enters build-shell.nix for Go)
# Without direnv/nix-shell: export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"

# Credentials: one file per provider, linked into the roots that need them (inventory/README.md#secrets)
mkdir -m 700 inventory/auto.tfvars.secret
$EDITOR inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars   # and vyos..., routeros..., ...

tooling/walk-roots.sh                        # every root in order: plan / apply / skip / quit per root
tooling/walk-roots.sh services-config        # one root
tofu -chdir=roots/services-config plan       # plain tofu works too; linked secret files auto-load
```

Each root keeps a local `terraform.tfstate` (git-ignored, may contain secrets). Back them up: a
lost state means re-importing that layer.

## Deployment order

Roots don't read each other's state; the order is real-world readiness. It's the list in
[`tooling/walk-roots.sh`](tooling/walk-roots.sh):

1. [proxmox-download-files](roots/proxmox-download-files/README.md): Debian 13 cloud image (optional)
2. [proxmox-network](roots/proxmox-network/README.md): host NICs, bond, bridges, VLANs
3. [proxmox-settings](roots/proxmox-settings/README.md): datacenter options, DNS, time zone
4. [fabric-vms](roots/fabric-vms/README.md): one VyOS leaf VM per Proxmox host
5. [fabric-spines](roots/fabric-spines/README.md): loopback, leaf ports, one eBGP session per leaf (underlay + EVPN) on the spines
6. [fabric-leaves](roots/fabric-leaves/README.md): EVPN/VXLAN config on every leaf
7. [services-vms](roots/services-vms/README.md): every service VM
8. [certs](roots/certs/README.md): Let's Encrypt wildcard for the proxy VMs
9. [services-config](roots/services-config/README.md): BIND + DNS records, DHCP, NetBox, Valkey, dark-triage, nginx
10. [monitoring-config](roots/monitoring-config/README.md): Prometheus, Alertmanager, Grafana, Loki, Mimir, Patroni Postgres
11. [workloads](roots/workloads/README.md): ordinary VMs

[radius](roots/radius/README.md) (RADIUS users, groups, clients) is run by hand, not by the walk.
Prerequisites per root: [roots/README.md](roots/README.md).

## Tests

`tofu test` suites (`*.tftest.hcl`) in the modules and in `services-vms`, `services-config`,
`monitoring-config`, `radius` and `proxmox-settings`; Python unit tests for the tooling. None touch real
infrastructure. See [modules/](modules/README.md#tests) and [tooling/](tooling/README.md#tests).
