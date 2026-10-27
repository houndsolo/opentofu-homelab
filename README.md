# OpenTofu homelab

This repo builds a homelab from shared OpenTofu inventory: Proxmox host
networking and VMs, VyOS EVPN/VXLAN leaves, and RouterOS BGP/EVPN spines.
L3VNIs define VRFs; nested L2VNIs define tenant VLANs and anycast gateways.
Leaf roles select which networks each device receives.

It also provisions Debian DNS and VyOS DHCP VMs. BIND runs under Podman,
replicates between DNS peers, and accepts records through RFC 2136. DHCP NICs,
HA identities and pools are generated from the same VM/VNI inventory. Separate
roots let you update each layer independently.

## Downstream VNI (DVNI)

DVNI lets an ingress VTEP use the destination VRF's advertised L3VNI when routing
across VRFs. Route-target imports select the reachable routes; the destination
VNI comes from EVPN. FRR requires a single VXLAN device for this dataplane;
the leaf module uses external-mode `vxlan0` with VLAN-to-VNI mappings.
See [FRR's DVNI documentation](https://docs.frrouting.org/en/latest/bgp.html#evpn-downstream-vni).

The [VNI example](examples/auto.tfvars/vnis.auto.tfvars) pairs `services`
(L3VNI 10000 on `proxmox` leaves) with `lan` (L3VNI 20000 on `external_l2`
leaves). Each exports its own EVPN route target and imports the other's:
traffic toward LAN uses VNI 20000; the return path uses VNI 10000. Configure
leaves with those roles to try it. No separate `dvni` variable is needed.

Imports do not bypass routing policy or firewall rules. The current leaf export
policy filters Type-5 routes matching its L2 subnet prefixes, so inspect the
advertised/imported EVPN routes when testing reachability; RTs alone do not
originate routes. This example demonstrates the DVNI configuration, not a live
connectivity test.

## Getting started

```sh
git submodule update --init --recursive
nix-shell
tooling/build-all
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
tooling/walk-roots.sh
```

Edit [inventory](inventory/README.md) first. The Bash runner walks the usable
[roots](roots/README.md) in dependency order, offering plan, apply, skip and quit.
It reviews a saved plan before applying it and offers a separate first-time DNS
bootstrap. Each root keeps its own state; retain and back up those state files.

| Directory | Purpose |
| --- | --- |
| [inventory/](inventory/README.md) | Values, schemas, public keys and provider configuration |
| [roots/](roots/README.md) | Deployable configurations, each with separate state |
| [modules/](modules/README.md) | Shared VM, network and service logic |
| providers/ | Provider source submodules |
| [tooling/](tooling/README.md) | Provider builds, secrets wrapper and guided runner |

For a single root: `tooling/walk-roots.sh services-config`.
For direct commands and shared credentials, see [secrets setup](inventory/README.md#secrets).
