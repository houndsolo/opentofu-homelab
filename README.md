# OpenTofu homelab

This repository builds and configures a homelab network with
[OpenTofu](https://opentofu.org/), the open-source fork of Terraform.

You describe the lab once, in [`inventory/`](inventory/README.md): the hosts and
their ID numbers, the VRFs and VLANs, the VMs and the DNS records. A set of small,
independent deployments (called **roots**) then reads those same values and builds
each layer of the lab:

- **Proxmox VE host networking.** NICs, a LACP bond, Linux bridges and VLAN
  interfaces on every cluster node.
- **An EVPN/VXLAN fabric.** One VyOS VM per Proxmox host acts as that host's
  leaf switch (its VTEP). Three physical VyOS leaves join the fabric, and two
  MikroTik RouterOS spines carry the BGP underlay and reflect EVPN routes.
- **Service VMs.** Two DNS servers (BIND 9 in Podman on Debian 13) and two DHCP
  servers (VyOS, as an active/passive HA pair).
- **Workload VMs.** Ordinary VMs built from the same VM module.

## Contents

- [The lab at a glance](#the-lab-at-a-glance)
- [How the repository fits together](#how-the-repository-fits-together)
- [OpenTofu in two minutes](#opentofu-in-two-minutes)
- [Network design](#network-design)
- [Before you start](#before-you-start)
- [Getting started](#getting-started)
- [Deployment order](#deployment-order)
- [Tests](#tests)

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
     dns01       dhcp01      lab01  ...    VMs; each NIC is tagged with a VLAN
```

VMs on a Proxmox host don't connect to the physical network directly. Their NICs
plug into the host's `vmbr4000` bridge with a VLAN tag. The host's leaf VM
(`vtep-<host>`) is the default gateway for those VLANs and carries them across
the fabric as VXLAN.

## How the repository fits together

```text
inventory/   values you edit: hosts, IDs, VRFs, VLANs, VMs, DNS records
    │        (symlinked into every root that needs them)
    ▼
roots/       one folder per layer. You run `tofu` here. Each has its own state.
    │        (roots call modules)
    ▼
modules/     reusable building blocks: a VM, a leaf's VyOS config, DHCP config...
    │        (modules use providers)
    ▼
providers/   source code for the custom Proxmox, VyOS and RouterOS providers
```

| Directory | What's in it |
| --- | --- |
| [inventory/](inventory/README.md) | All the values you edit, plus the shared variable declarations, provider settings and SSH public keys |
| [roots/](roots/README.md) | The deployable configurations, one per layer, each with its own state |
| [modules/](modules/README.md) | Shared logic used by the roots: VMs, host networking, leaf/spine config, DHCP |
| [providers/](providers/README.md) | Git submodules with the source of the three custom providers |
| [tooling/](tooling/README.md) | Scripts to build the providers, load secrets and walk the roots in order |
| [examples/](examples/README.md) | Commented example values. Nothing loads these automatically. |
| `shell.nix` | A Nix shell with the right versions of Go, OpenTofu, Python and git |

## OpenTofu in two minutes

If you're new to OpenTofu (or Terraform), these are the terms used in every
README here:

| Term | What it means in this repo |
| --- | --- |
| **Provider** | A plugin that talks to one API. This repo builds three custom ones: `proxmox` (Proxmox VE API), `vyoscmd` (VyOS HTTPS API) and `routeros` (RouterOS REST API). It also downloads `hashicorp/dns` and `hashicorp/random` from the public registry. |
| **Resource** | One object that a provider manages: a VM, a bridge, a BGP connection, a DNS record set. |
| **Module** | A folder of `.tf` files that you call with inputs, a bit like a function. |
| **Root** | A folder you run `tofu` commands in. Each folder in `roots/` is one. |
| **State** | `terraform.tfstate`, OpenTofu's record of what it has created. Each root keeps its own state file next to its `.tf` files. State is git-ignored and can contain secrets, so back it up. |
| **Variables / tfvars** | Inputs. OpenTofu automatically loads every `*.auto.tfvars` file in the root folder. |
| **`plan` / `apply`** | `plan` is a dry run that lists what would change. `apply` makes the changes, after asking you to confirm. |
| **`import`** | Adopts something that already exists into state, so OpenTofu manages it instead of trying to create a duplicate. |

## Network design

### Underlay and overlay

- **Underlay: getting packets from leaf to leaf.** Each leaf runs eBGP to each
  spine over their point-to-point link, using only IPv6 link-local addresses
  ("BGP unnumbered": FRR's `neighbor eth1 interface v6only`). No IP addresses are
  configured on the links. The only route a leaf advertises into the underlay is
  its own loopback `/128`, which is its VTEP address.
- **Underlay AS numbers.** The spines are AS 810 (`spine_as`). Each leaf appears
  in the underlay as its own AS, 700 + its ID (`leaf_underlay_as_base` + ID), so
  venom (ID 17) is AS 717.
- **Overlay: EVPN.** Leaves and spines run iBGP in AS 700 (`overlay_as`) between
  their loopback addresses, in the L2VPN EVPN address family. The spines are route reflectors,
  so each leaf peers only with the two spines, never with other leaves. BFD runs
  on every BGP session.
- **Data plane.** VXLAN over IPv6, sourced from each leaf's loopback.
  Broadcast/unknown/multicast traffic uses head-end (ingress) replication, so the
  underlay needs no multicast. Each leaf has a single VXLAN device, `vxlan0`, that
  maps VLANs to VNIs.

### VRFs, VLANs and VNIs

- An **L3VNI** is a VRF. Traffic routed between leaves travels in the VRF's L3VNI
  (this is called *symmetric IRB*).
- An **L2VNI** is one VLAN, with its subnet, inside a VRF. It is stretched across
  every leaf that carries that VRF.
- Every L2VNI has a **distributed anycast gateway**: the same gateway IP and MAC
  on every leaf. A VM always uses its local leaf as its gateway, wherever it runs.
- **Leaf roles** decide which leaves get which VRFs. Each L3VNI lists the roles
  that receive it: `proxmox` (the VM leaves), `external_l2` or `external_l3`.
- **Route-targets** decide which VRFs can reach each other. They are written out
  explicitly for each VRF. See [DVNI](#downstream-vni-dvni) below.

The VRFs in the inventory today (the source of truth is
[`vnis.auto.tfvars`](inventory/auto.tfvars/vnis.auto.tfvars)):

| VRF | L3VNI | Leaf roles | L2VNIs (VLAN: subnet, gateway) |
| --- | --- | --- | --- |
| `lylat_service` | 6600 | proxmox | 6: 10.6.0.0/16; 8: 10.8.0.0/16 (gateways .0.5) |
| `lylat_lan` | 6900 | proxmox, external_l2 | 9, 10, 11: 10.9/10.10/10.11.0.0/16 |
| `lylat_infra` | 6200 | proxmox | 2: 10.2.0.0/16 |
| `lylat_ai` | 6700 | proxmox, external_l2 | 12: 10.12.0.0/16 |
| `lylat_external` | 6666 | external_l3 | none (routed only) |

The L2VNI number is 9000 + the VLAN ID by convention (VLAN 8 is L2VNI 9008).
Every anycast gateway is `.0.5` in its subnet (for example `10.8.0.5`).

### MTU

| Where | MTU |
| --- | --- |
| Tenant side: VM NICs, the leaf's access interface, `vxlan0`, the leaf's `br0` bridge and its VLAN interfaces | 9119 (`vxlan_mtu`) |
| Underlay side: leaf-to-spine links and the loopback | 9189 (`outer_mtu`) |

The 70-byte difference is the VXLAN-over-IPv6 overhead: outer IPv6 header
(40 bytes) + UDP (8) + VXLAN header (8) + the inner Ethernet header (14).

### Downstream VNI (DVNI)

Normally, both directions of a routed flow use the VRF's own L3VNI. With
**downstream VNI**, when VRF A imports routes from VRF B, the ingress leaf
encapsulates traffic with the L3VNI that the *destination* VRF advertised (B's).
The egress leaf then drops the packet straight into VRF B. Return traffic uses
A's L3VNI. See
[FRR's DVNI documentation](https://docs.frrouting.org/en/latest/bgp.html#evpn-downstream-vni).

You don't need a special `dvni` variable. Add the other VRF's route-target to
`evpn_rt_imports`, and EVPN supplies the destination VNI. The live inventory
already does this: for example, `lylat_service` (6600) imports `700:6200`,
`700:6900` and `700:6666`. FRR needs a single VXLAN device for this data plane,
which is why the leaf module uses one external-mode `vxlan0` with VLAN-to-VNI
mappings.

[`examples/auto.tfvars/vnis.auto.tfvars`](examples/auto.tfvars/vnis.auto.tfvars)
shows a minimal pair: `services` (L3VNI 10000, on `proxmox` leaves) and `lan`
(L3VNI 20000, on `external_l2` leaves). Each exports its own route-target and
imports the other's. Traffic towards `lan` uses VNI 20000, and the return path
uses VNI 10000.

Things to keep in mind when testing it:

- Importing a route-target doesn't bypass routing policy or firewall rules.
- A route-target only selects routes that some leaf actually advertises; it
  doesn't create routes.
- The leaf export policy deliberately does **not** send type-5 (IP prefix) routes
  for a leaf's own L2VNI subnets to the spines. Hosts in those subnets are
  reachable through type-2 (MAC/IP) routes instead. So when you test cross-VRF
  reachability, look at the EVPN routes that are actually advertised and
  imported.

## Before you start

OpenTofu configures these things, but it doesn't create them. They must already
exist:

- **A Proxmox VE cluster** whose node names match
  [`nodes.auto.tfvars`](inventory/auto.tfvars/nodes.auto.tfvars), plus the
  standalone host `greatfox`.
- **Proxmox storage.** `ceph_rbd` for VM disks, and a CephFS storage called
  `cephfs` that allows the *Import* and *Snippets* content types.
- **A VyOS image and snippet.** A VyOS qcow2 image in `cephfs:import/`, and a
  cloud-init snippet `cephfs:snippets/vyos_api.yml` that turns on the VyOS HTTPS
  API with your API key. The repo references both but creates neither.
- **Proxmox API tokens** for the cluster and for `greatfox`, plus root SSH access
  to the Proxmox nodes with your key. The Proxmox provider uses SSH for some
  operations.
- **Two RouterOS spines** reachable on their management IPs, with the REST API
  enabled, and a RouterOS user that OpenTofu can log in as.
- **A machine to run OpenTofu on** that can reach the management networks:
  Proxmox (`10.20.7.x`), spines (`10.20.0.x`), leaves (`10.20.10.x`) and service
  VMs (`10.20.53.x`, `10.20.67.x`). It also needs TCP port 53 on the primary DNS
  server (`10.8.53.1`).
- **The tools.** Either [Nix](https://nixos.org/download/) (for `nix-shell`), or
  install them yourself: Go ≥ 1.26, OpenTofu ≥ 1.11.6, Python 3 with
  `python-hcl2` ≥ 7.3.1, and git.
- **GitHub SSH access.** The provider submodules use `git@github.com:` URLs, so
  you need an SSH key on GitHub. See [providers/](providers/README.md) for an
  HTTPS alternative.

## Getting started

Run these from the top of the repository:

```sh
# 1. Download the provider source code (the git submodules under providers/).
git submodule update --init --recursive

# 2. Enter the development shell: Go, OpenTofu, Python + python-hcl2, git.
nix-shell

# 3. Build the three custom providers and install them into a local mirror
#    (.tofu-provider-mirror/). This also writes the CLI config used in step 4.
tooling/build-all

# 4. Tell OpenTofu to look for providers in that mirror.
#    Repeat this in every new shell (or add it to your shell profile).
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"

# 5. Put your credentials in the central secrets file. Git ignores it, because it
#    matches *.secret.auto.tfvars. See inventory/README.md#secrets for its format,
#    and for the two ways roots can load it.
$EDITOR inventory/auto.tfvars/passwords.secret.auto.tfvars

# 6. Edit the inventory to match your lab, then walk the roots in order.
#    At each root you choose plan, apply, skip or quit. Nothing changes until
#    you choose apply and then type "yes".
tooling/walk-roots.sh
```

To work on a single root, name it: `tooling/walk-roots.sh services-config`.
You can also run plain `tofu` commands through the secrets wrapper:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
```

Every root keeps its own `terraform.tfstate` file. Back these files up. If you
lose one, OpenTofu forgets what it built for that layer, and you'll need to
import everything again.

## Deployment order

The roots don't read each other's state. The order exists because each layer
needs the real infrastructure from the layers before it to be up and reachable.

1. [proxmox-download-files](roots/proxmox-download-files/README.md): download
   the Debian 13 cloud image (optional).
2. [proxmox-network](roots/proxmox-network/README.md): host NICs, bond, bridges
   and VLANs.
3. [fabric-vms](roots/fabric-vms/README.md): one VyOS leaf VM per Proxmox host.
4. [fabric-spines](roots/fabric-spines/README.md): BGP, BFD and EVPN on the
   RouterOS spines.
5. [fabric-leaves](roots/fabric-leaves/README.md): the EVPN/VXLAN config on
   every leaf.
6. [services-vms](roots/services-vms/README.md): the DNS and DHCP VMs.
7. [services-config](roots/services-config/README.md): BIND, DNS records, and
   DHCP high availability and pools.
8. [workloads](roots/workloads/README.md): ordinary VMs.

[roots/README.md](roots/README.md) has the prerequisites for each step.

## Tests

The modules and the `services-config` root have `tofu test` suites (`*.tftest.hcl`).
The tooling scripts have Python unit tests. None of them touch real
infrastructure. To run them, see [modules/](modules/README.md#tests) and
[tooling/](tooling/README.md#tests).
