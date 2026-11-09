# Inventory

This folder is the single source of truth for the lab. You edit values here, and
every root reads them. If you want to add a VM, a VLAN or a DNS record, this is
where you do it.

## Contents

- [How roots use these files](#how-roots-use-these-files)
- [What's in this folder](#whats-in-this-folder)
- [The value files](#the-value-files), one section per file
- [How IDs become names and addresses](#how-ids-become-names-and-addresses)
- [Secrets](#secrets)
- [Naming conventions](#naming-conventions)
- [Renamed inputs](#renamed-inputs)
- [Fields that aren't used yet](#fields-that-arent-used-yet)

## How roots use these files

Each root links to the inventory files it needs with relative symlinks:

```text
$ ls -l roots/fabric-leaves
fabric.auto.tfvars      -> ../../inventory/auto.tfvars/fabric.auto.tfvars
fabric.variables.tf     -> ../../inventory/schema/fabric.tf
vnis.auto.tfvars        -> ../../inventory/auto.tfvars/vnis.auto.tfvars
vnis.variables.tf       -> ../../inventory/schema/vnis.tf
vyoscmd-provider.tf     -> ../../inventory/provider-config/vyoscmd-provider.tf
versions.tf             -> ../../inventory/versions/vyos-versions.tf
main.tf                 (the root's own code)
...
```

OpenTofu automatically loads every `*.auto.tfvars` file in the folder it runs
in, so each root picks up these values without any extra flags. Edit the files
here in `inventory/`, not the links. Never replace a link with a copy, or that
root will silently stop seeing your changes.

## What's in this folder

| Path | What's in it |
| --- | --- |
| `auto.tfvars/` | **The values.** These are the files you edit. |
| `auto.tfvars.secret/` | Your credentials, one file per provider. Git-ignored, and only on the machine that runs OpenTofu; see [Secrets](#secrets). |
| `schema/` | Variable declarations: the type of every value, its defaults and its validation rules |
| `provider-config/` | Provider blocks (API endpoints, credentials) and the credential variables |
| `versions/` | OpenTofu and provider version pins |
| `ssh_pubkeys.tf` | Named SSH public keys that VMs can select |

## The value files

| File | Variable | Describes | Read by these roots |
| --- | --- | --- | --- |
| `nodes.auto.tfvars` | `nodes` | Proxmox hosts, their IDs, and how to reach them | all roots |
| `fabric.auto.tfvars` | `fabric` | AS numbers, addressing, physical leaves, spines | fabric-vms, fabric-spines, fabric-leaves, services-config |
| `fabric-vms.auto.tfvars` | `fabric_vms` | Naming and NICs of the leaf VMs | fabric-vms, fabric-leaves |
| `pve-network.auto.tfvars` | `pve_network` | Host NICs, bond, bridges, VLAN interfaces | proxmox-network |
| `vm-config.auto.tfvars` | `vm_config`, `vm_images` | Shared VM defaults and named images | fabric-vms, services-vms, workloads |
| `vms.auto.tfvars` | `vms` | Every individual VM: owner, role, placement, NICs, overrides | proxmox-download-files, fabric-vms, services-vms, services-config, workloads |
| `vnis.auto.tfvars` | `vnis` | VRFs (L3VNIs), VLANs (L2VNIs), route-targets, DHCP scopes | fabric-leaves, services-vms, services-config |
| `dns-records.auto.tfvars` | `dns_hosts`, `dns_records` | Your own DNS records in `lylat.space` | services-config |


### nodes.auto.tfvars: Proxmox hosts

```hcl
nodes = {
  management_prefix = "10.20.7.0/24" # each host's management IP is .<ID> in this range
  cluster_api_node  = "fichina"      # the cluster provider talks to this host's API: https://10.20.7.11:8006

  proxmox = {
    venom    = { id = 17 }                    # the key must be the real PVE node name
    # ... fichina = 11, macbeth = 12, titania = 13, zoness = 14, fortuna = 15, eldarad = 16
    greatfox = { id = 20, standalone = true } # not in the cluster: managed through the proxmox.greatfox provider
  }
}
```

- **The `id` drives almost everything.** It sets the host's addresses, its leaf
  VM's ID, its MACs, its BGP AS and its DNS names; see
  [How IDs become names and addresses](#how-ids-become-names-and-addresses).
  Keep IDs stable: changing one changes all of those, and OpenTofu will rebuild
  things.
- **Checked automatically:**
  - IDs are unique.
  - At most one host is `standalone`.
  - `cluster_api_node` names a cluster (non-standalone) host.
- **Not checked, but required:**
  - IDs must be 1–99, because they're written into a MAC address octet
    ([modules/fabric/macs](../modules/fabric/macs/README.md) checks this when a
    root uses it).
  - The standalone host must be named `greatfox`, because
    `provider-config/proxmox-providers.tf` looks up that name for the
    `proxmox.greatfox` endpoint.
- **Keep `management_prefix` in step with host networking.** It's what OpenTofu
  uses to reach the hosts (the API URL, SSH, and the DNS records). The hosts' real
  `vmbr0` addresses come from `pve_network.bridges.0.ipv4`, so the two must
  describe the same addresses.

Which roots act on which hosts:

| Root | Cluster hosts | The standalone host |
| --- | --- | --- |
| proxmox-network | yes | no |
| monitoring-config (metric servers) | yes | yes, through `proxmox.greatfox` |
| fabric-vms | yes, through the cluster provider | yes, through `proxmox.greatfox` |
| fabric-leaves, fabric-spines, services-config (DNS records) | yes | yes |

### fabric.auto.tfvars: AS numbers, addressing, leaves and spines

```hcl
fabric = {
  settings = {
    leaf_underlay_as_base    = 700                 # each leaf's underlay AS = this + its ID -> venom is AS 717
    spine_as                 = 810                 # the spines' underlay AS (one spine can override it with `as`)
    overlay_as               = 700                 # the iBGP EVPN AS, shared by leaves and spines
    loopback_ipv4_prefix     = "10.255.240.0/24"   # router-IDs: 10.255.240.<ID>
    loopback_ipv6_prefix     = "fd69:255:240::/64" # VTEP / loopback addresses: fd69:255:240::<ID>
    loopback_interface       = "dum240"            # VyOS dummy interface that holds both loopbacks
    management_prefix        = "10.20.10.0/24"     # leaf VM eth0 address and leaf API: .<ID> ...
    management_prefix_length = 16                  # ... with this prefix length -> 10.20.10.17/16
    l2_vni_base              = 9000                # not read by any code at the moment
    ntp_servers              = ["10.20.10.255"]    # NTP for spines AND leaves (fw-wan, on the management network)
    leaf_ntp_vrf             = "mgmt"              # the VRF the leaves' NTP client runs in (leave out = default VRF)
    leaf_prometheus_exporters = { vrf = "mgmt" }   # node/frr exporters on each leaf's mgmt address (leave out = unmanaged)
    # vxlan_mtu = 9119                             # default; tenant side: vxlan0, br0 and its VLANs, the access port
    # outer_mtu = 9189                             # default; underlay side: the spine links and the loopback
  }

  # Physical leaves only. One "proxmox" leaf per Proxmox host is generated automatically.
  leaves = {
    external_l2_01 = {
      role             = "external_l2" # proxmox, external_l2 or external_l3
      id               = 42            # unique across all leaves AND spines (they share the loopback prefix)
      access_interface = "eth3"        # the leaf's port towards hosts; it trunks the leaf's VLANs
      spine_uplink     = "ether10"     # spine port for this leaf, if it isn't ether<ID>
    }
  }

  spines = {
    m326-1 = {
      management_ip = "10.20.0.5" # RouterOS REST API, reached at http://<management_ip>
      id            = 1           # spine loopback fd69:255:240::1; leaves reach it on eth1
      # uplink_interface = "eth5" # leaf-side port to this spine, if it isn't eth<ID>
      # as               = 65001  # this spine's underlay AS, if it isn't settings.spine_as
    }
  }
}
```

How the ports line up by default:

- **On a leaf**, the link to spine *N* is `ethN`: `eth1` goes to spine 1 and
  `eth2` to spine 2. Change it per spine with `uplink_interface`.
- **On a spine**, the port towards leaf *ID* is `ether<ID>`. For example,
  `ether17` faces venom. Change it per physical leaf with `spine_uplink`.
- **Generated Proxmox leaves** use `eth<number of spines + 1>` (`eth3`) as their
  access interface.

`management_prefix` and `management_prefix_length` are used for three things:
the leaf VMs' `eth0` addresses (fabric-vms), the API address OpenTofu connects to
(fabric-leaves), and the `leaf-<ID>` DNS records (services-config). Because all
three share one setting, they can't drift apart.

Route-targets in `vnis.auto.tfvars` are written out by hand, so changing an AS
number doesn't rewrite them.

**NTP.** `ntp_servers` is one list of NTP hostnames or addresses, used by both
the spines and the leaves:

- **The default is the public pool.** If you leave it out, it's
  `["0.pool.ntp.org", "1.pool.ntp.org"]`, which needs working DNS and outbound
  NTP from the devices.
- **The lab points at fw-wan instead.** The inventory sets `10.20.10.255`, on the
  management network.
- **`leaf_ntp_vrf = "mgmt"`** runs each leaf's NTP client in its management VRF,
  so it can reach that server. The spines ignore this setting.
- **The leaves drop VyOS's built-in servers.** Any of them that aren't in your
  list (`0/1.pool.ntp.org`, `time1`–`time3.vyos.net`) are deleted, so a leaf
  only polls the servers you configured.
- **An empty list (`[]`) means "don't manage NTP".** It doesn't remove servers
  that are already configured, or turn an existing client off.

`fabric.settings.leaf_prometheus_exporters = { vrf = "mgmt" }` turns on VyOS's
`node-exporter` (port 9100) and `frr-exporter` (port 9342) on every leaf,
listening on its management address inside that VRF. frr-exporter also gets the
`bgp-l2-vpn` collector (the EVPN overlay sessions; IPv6 unicast is always on) and
`bgp peer-hostname` labels. [monitoring-config](../roots/monitoring-config/README.md)
scrapes them (jobs `vyos-node`, `vyos-frr`). Leaving the setting out (null)
means "don't manage the exporters"; it doesn't remove existing configuration.

### fabric-vms.auto.tfvars: the leaf VMs

```hcl
fabric_vms = {
  hostname_prefix  = "vtep-" # VM name = prefix + node name -> vtep-venom
  vm_id_offset     = 700     # VM ID   = node ID + offset   -> 717
  underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"] # become eth1, eth2, eth3
}
```

- **The order of `underlay_bridges` matters.** It must line up with the leaf
  config: `eth1` goes to spine 1 (`vmbr4001`), `eth2` to spine 2 (`vmbr4002`),
  and `eth3` is the access trunk to local VMs (`vmbr4000`).
- The leaf VMs' management addresses come from `fabric.settings` (see above).
- To override one leaf VM (for example, to give it more memory), see
  [fabric-vms](../roots/fabric-vms/README.md#overriding-one-leaf-vm).

### pve-network.auto.tfvars: host networking

One network profile is applied to **every cluster host** (not the standalone
one), so all of them must use the same NIC names. Each map key becomes part of an
interface name:

| Map | Key `7` becomes | Notes |
| --- | --- | --- |
| `eths` | `eth7` | Sets the MTU and comment on a NIC that already exists |
| `bonds` | `bond7` | `slaves`, `bond_mode`, `bond_xmit_hash_policy` |
| `bridges` | `vmbr7` | `ports`, `vlan_aware`, `gateway`, optional `ipv4` |
| `vlans` | `<port>.7` | Uses the parent `port`: key `2` with port `vmbr4000` is `vmbr4000.2` |

The `ipv4` block gives every host its own address, using the node ID as the host
number:

```hcl
bridges = {
  0 = {                                 # -> vmbr0
    mtu         = 9119
    description = "mgmt"
    vlan_aware  = false
    ports       = ["eth0"]
    ipv4 = {
      cidrhost_prefix = "10.20.7.0/24"  # pick the host address in this range: .<node ID> -> 10.20.7.17 on venom
      cidr            = 16              # then configure it with this prefix length -> 10.20.7.17/16
    }
  }
}
```

Note that `cidrhost_prefix` is only used to choose the address. The `cidr`
number is the prefix length the interface actually gets. A `gateway` is shared
by every host. Today the only one is on `vlans.2` (`vmbr4000.2`, gateway
`10.2.0.5`). To see what a whole host ends up with, see
[proxmox-network](../roots/proxmox-network/README.md).

### vm-config.auto.tfvars: shared VM defaults and images

```hcl
vm_config = {                 # defaults for every VM; the full list is in schema/vm-config.tf
  datastore_id = "ceph_rbd"   # where VM disks are created (required)
  import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2" # default disk image (required)
  started      = true         # start VMs after creating them
}

vm_images = {                 # named images; a VM picks one with image = "<name>"
  debian13 = {
    import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2"
    tags         = ["opentofu", "debian"]
  }
  vyos = {
    import_image      = "cephfs:import/vyos-1.5-rolling-202608270227-generic-amd64.qcow2"
    user_data_file_id = "cephfs:snippets/vyos_api.yml" # cloud-init snippet that enables the VyOS API
    tags              = ["opentofu", "vyos"]
  }
}
```

The image files and snippets must already exist in Proxmox. The Debian image
can be downloaded by
[proxmox-download-files](../roots/proxmox-download-files/README.md). The VyOS
image and its snippet are up to you.

A VM's final settings are built in three layers. Each layer overrides the ones
before it:

1. **`vm_config`, the shared defaults.** Anything you don't set falls back to
   the defaults in `schema/vm-config.tf`: 4 cores, 4096 MB of RAM, a 10 GB disk,
   management on `vmbr0`, the QEMU guest agent enabled, and so on.
2. **The selected image from `vm_images`.** Its `import_image` and
   `user_data_file_id` always replace the defaults, so picking `debian13` clears
   a VyOS snippet you might have set in `vm_config`. Its `tags` apply if set.
3. **The VM's own `config = { ... }` block.** It can override any `vm_config`
   key: `cpu_cores`, `memory_mb`, `management_bridge`, `started`, `tags`, and the
   rest.

### vms.auto.tfvars: individual VMs

All VMs live in one `vms` map. Every VM needs an `owner`, which decides which
root creates it. Service VMs also take a `role`:

| `owner` | `role` | Created by | Configured by | Notes |
| --- | --- | --- | --- | --- |
| `services-vms` | `dns` | services-vms | services-config (BIND) | Exactly one NIC with an `ipv4_address`: the DNS service address |
| `services-vms` | `dhcp` | services-vms | services-config (VyOS DHCP) | Define exactly two, or none. VM IDs must be 6701–6799. Data NICs are generated. |
| `services-vms` | `monitoring` | services-vms | (nothing yet) | `mon01`: meant for Prometheus, InfluxDB and Grafana's Postgres |
| `services-vms` | `grafana` | services-vms | (nothing yet) | `graf01`, `graf02` |
| `services-vms` | (none) | services-vms | (nothing) | Any other service VM |
| `workloads` | (none) | workloads | (nothing) | Ordinary VMs |
| `fabric-vms` | (none) | fabric-vms | fabric-leaves | Only for **overrides** of the generated `vtep-<node>` VMs |

An annotated entry (this is the real `dns01`):

```hcl
vms = {
  dns01 = {
    owner = "services-vms" # which root creates it (see the table above)
    role  = "dns"          # services-config deploys BIND on it
    node  = "venom"        # Proxmox node it runs on
    vm_id = 5301           # Proxmox VM ID; must be unique
    image = "debian13"     # a key in vm_images

    # Management address on net0 (eth0 in the guest): a CIDR, or "dhcp" (the
    # default if you leave this out).
    management_address = "10.20.53.1/16"
    # gateway = "10.20.0.1" # optional default gateway on the management NIC (none here)

    # Extra NICs, in order: the first one is eth1, the next eth2, and so on.
    network_devices = [{
      bridge       = "vmbr4000"     # the host's VLAN-aware fabric bridge
      vlan_id      = 8              # Proxmox tags the traffic; the guest sees a plain, untagged NIC
      ipv4_address = "10.8.53.1/16" # set by cloud-init at first boot; BIND listens here
      ipv4_gateway = "10.8.0.5"     # the anycast gateway on the local leaf
      # mac_address, model, mtu and disconnected are also available
    }]

    # Any vm_config key can be overridden here, plus the cloud-init user and keys.
    config = {
      cpu_cores    = 2
      memory_mb    = 2048
      ssh_username = "mechanic"  # cloud-init creates this user
      ssh_pubkeys  = ["desktop"] # key names from ssh_pubkeys.tf
    }
  }
}
```

Rules that are checked for you when you run `plan`:

- `owner` is required and must be `fabric-vms`, `services-vms` or `workloads`.
  `role` is only allowed with `services-vms`, and must be `dns`, `dhcp`,
  `monitoring` or `grafana`.
- Every VM except a `fabric-vms` override needs a `node` and a `vm_id`.
- A `dns` VM needs exactly one NIC with an `ipv4_address`.
- There must be either no `dhcp` VMs or exactly two, with different VM IDs.
- Every name in `config.ssh_pubkeys` must exist in `ssh_pubkeys.tf`.
- `config.ssh_pubkeys` can't be combined with a custom `user_data_file_id`
  snippet, because a custom snippet replaces the user-data that would carry the
  keys.

Cloud-init only configures NICs that have an `ipv4_address`. A NIC without one
is attached, but left unconfigured. Cloud-init also only runs at a VM's first
boot. If you change the addresses or keys of a VM that already exists, you may
have to change them inside the guest yourself, or recreate the VM.

`schema/vm.tf` (one VM, as the VM module sees it) and `schema/vms.tf` (the
inventory map) repeat the same fields, because OpenTofu can't share one object
type between variables. `tooling/tests/test_schemas.py` checks that they, and
`schema/vm-config.tf`, stay in step. If you add a VM setting, add it to all
three.

### vnis.auto.tfvars: VRFs, VLANs and DHCP scopes

`vnis` is a list of VRFs (L3VNIs). Each VRF contains a map of VLANs (L2VNIs).
Here is the real `lylat_service` VRF, trimmed to one VLAN:

```hcl
vnis = [
  {
    # ---- The VRF (L3VNI) ----
    vrf       = "lylat_service" # VRF name on the leaves (unique)
    vrf_table = 1000            # Linux routing table number for the VRF (unique)
    vni       = 6600            # the L3VNI, used for routed traffic between leaves
    vlan_id   = 66              # internal VLAN that carries the L3VNI on each leaf's br0 (unique)
    roles     = ["proxmox"]     # leaf roles that get this VRF

    # Local VRF route leaking inside each leaf (BGP IPv4 VPN). Space-separated strings.
    ipv4_rt_imports = "700:6200 700:6900"
    ipv4_rt_exports = "700:6600"

    # EVPN route-targets between leaves. Import another VRF's RT to reach it (see DVNI).
    evpn_rt_imports = ["700:6600", "700:6200", "700:6900", "700:6666"]
    evpn_rt_exports = ["700:6600"]

    # ---- The VLANs (L2VNIs) inside this VRF ----
    l2 = {
      8 = {                                  # the key is just a label; by convention it's the VLAN number
        vni             = 9008               # L2VNI (unique across every L2 and L3 VNI)
        vlan_id         = 8                  # the VLAN tag VMs use on vmbr4000 (unique)
        anycast_gw_ip   = "10.8.0.5"         # gateway IP, the same on every leaf
        anycast_gw_cidr = 16                 # prefix length (a number) -> subnet 10.8.0.0/16
        anycast_mac     = "02:00:00:00:08:01" # gateway MAC, the same on every leaf
        dhcp = {                             # present -> the DHCP VMs get a NIC on this VLAN
          scope = {                          # present -> the DHCP VMs serve a pool here
            ranges = { 0 = { start = "10.8.5.1", stop = "10.8.5.99" } }
          }
        }
      }
    }
  },
]
```

The live inventory follows a few conventions, which you can see in the example:

- L2VNI = 9000 + VLAN.
- Each gateway is `.0.5` in its subnet.
- Each gateway MAC is `02:00:00:00:<VLAN>:01`, with the VLAN written as decimal
  digits.

Checked automatically: every VRF has at least one valid role (`proxmox`,
`external_l2` or `external_l3`). VNIs are 1–16777215 and unique across both L2
and L3. VRF names, table numbers and VLAN IDs (L2 and L3 together) are unique.
Gateways are valid IPv4 with a prefix length, and MACs have six octets. VRF
names start with a letter and are at most 15 characters (VyOS rejects longer
names at commit). `ipv4_rt_imports` must be set when `import_ipv4_vpn = true`,
and `ipv4_rt_exports` when `export_vpn_ipv4 = true`.

`import_ipv4_vpn` and `export_vpn_ipv4` control the leaf's ipv4-unicast VPN
route leaking for a VRF (`import vpn` / `route-target vpn import`, and
`export vpn` / `rd vpn export` / `route-map vpn export` / `route-target vpn
export`). Set both to `false`, and list only the VRF's own RT in
`evpn_rt_imports`/`evpn_rt_exports`, for an isolated VRF such as
`lylat_monitor`, which shares routes with no other VRF.

Not checked automatically, but required:

- **DHCP VLANs must be 1–99**, because the VLAN number becomes a MAC octet. The
  DHCP MAC calculator rejects anything else during `plan`.
- **DHCP-enabled subnets must contain `10.<VLAN>.67.1` and `.2`.** Those are the
  DHCP VMs' addresses, so follow the `10.<VLAN>.0.0/16` convention.
- **The DHCP HA link must sit on one of those addresses.** The pair talks over
  `dhcp_ha_prefix` in services-config (default `10.6.67.0/24`, on VLAN 6). Its
  `.1` and `.2` must be the DHCP VMs' own addresses on a DHCP-enabled VLAN, so
  with the default, VLAN 6 must stay DHCP-enabled.

The DHCP options and their defaults:

| `dhcp` setting | Effect | Default |
| --- | --- | --- |
| `dhcp = {}` (no `scope`) | The DHCP VMs get a NIC, an address and a listen interface on the VLAN, but serve no pool | |
| `scope.ranges` | Address pools; the map keys become VyOS range IDs | required in a scope |
| `scope.name_servers` | DNS servers handed to clients | the DNS VMs (`10.8.53.1`, `10.8.53.2`) |
| `scope.domain_name` | Domain name option | `lylat.space` |
| `scope.domain_search` | Search list; `[]` sends none | `[domain_name]` |
| `scope.lease_seconds` | Lease time | `86400` (1 day) |
| `scope.authoritative` | Answer as the authoritative server | `true` |

### dns-records.auto.tfvars: your DNS records

```hcl
dns_hosts = {
  torrent = { A = "10.8.7.7" }   # owner (relative to lylat.space) => { type = value }
}
dns_records = [                  # for several values of one type, or a custom TTL
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
]
```

Some names are generated automatically: the Proxmox hosts, `leaf-<ID>`,
`spine-<ID>` and the DHCP VMs. A `dns_hosts` entry with one of those names
**replaces all of that name's generated records**. The format rules are in
[services-config](../roots/services-config/README.md#dns-records).

### ssh_pubkeys.tf: named SSH public keys

```hcl
locals {
  ssh_pubkeys = {
    desktop = "ssh-rsa AAAA... houndsolo@arch"
    # laptop = "ssh-ed25519 AAAA... laptop"
  }
}
```

A VM selects keys by name with `config.ssh_pubkeys = ["desktop"]`, and
cloud-init installs them for `config.ssh_username`. If you use a name that isn't
defined here, `plan` fails. This is a `.tf` file rather than a tfvars file
because it defines a `locals` block; fabric-vms, services-vms and workloads link
to it. **Only put public keys here, never private keys.**

## How IDs become names and addresses

Most addresses aren't typed in anywhere; they're calculated from the node ID.
Here is everything that comes from venom's ID, 17:

| What | Value for venom | Calculated from |
| --- | --- | --- |
| Proxmox management address | `10.20.7.17/16` on `vmbr0` | `pve_network.bridges.0.ipv4` (and `nodes.management_prefix` for reaching it) |
| Host address on VLAN 2 | `10.2.0.17/16` on `vmbr4000.2` | `pve_network.vlans.2.ipv4` |
| Leaf VM name and VM ID | `vtep-venom`, `717` | `fabric_vms.hostname_prefix`, ID + `vm_id_offset` |
| Leaf management (eth0) and API | `10.20.10.17/16`, `https://10.20.10.17` | `fabric.settings.management_prefix` and `_length` |
| Leaf router-ID / IPv4 loopback | `10.255.240.17` | `loopback_ipv4_prefix` |
| VTEP / IPv6 loopback | `fd69:255:240::17` | `loopback_ipv6_prefix` |
| Leaf VXLAN/bridge MAC | `00:13:37:00:00:17` | `modules/fabric/leaf/addressing.tf` |
| Leaf NIC MACs (eth1–eth3) | `02:00:00:17:00:01` – `:03` | [modules/fabric/macs](../modules/fabric/macs/README.md) |
| Leaf underlay AS | `717` | `leaf_underlay_as_base` + ID |
| Spine port facing this leaf | `ether17` | `ether<ID>` |
| Leaf hostname | `LEAF-17` | `modules/fabric/leaf/system.tf` |
| DNS names | `venom.lylat.space` → `10.20.7.17`, `leaf-17.lylat.space` → `10.20.10.17` | `services-config` |

**Why the IPv6 address and MACs read like the decimal ID.** IPv6 addresses and
MACs are written in hex, so ID 17 would normally appear as `11`. The code reads
the decimal digits as if they were hex instead: `parseint("17", 16)` is 23, and
host number 23 in the prefix is written `::17`. That way, every address and MAC
for node 17 visibly contains `17`.

## Secrets

### The per-provider secret files

Credentials live in one small file per provider, in
`inventory/auto.tfvars.secret/`. The directory only needs to exist on the machine
that runs OpenTofu; an editing checkout needs none. Git ignores the whole
directory, and any `*.secret.auto.tfvars` or `*.secret.tfvars` file anywhere.
Keep the directory `chmod 700` and the files `chmod 600`.

| File | Variables | Link it into |
| --- | --- | --- |
| `proxmox.secret.auto.tfvars` | `pve_api_token`, `greatfox_api_token` | proxmox-download-files, proxmox-network, fabric-vms, services-vms, workloads |
| `vyos.secret.auto.tfvars` | `vyos_api_key` | fabric-leaves, services-config |
| `routeros.secret.auto.tfvars` | `routeros_password` (and `routeros_username`, if it isn't `admin`) | fabric-spines |
| `ssh_keys.secret.auto.tfvars` | `ssh_keys` | nothing: no tracked root reads it. Link it only into a custom root that needs it. |

```hcl
# inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars  (never committed)
# Proxmox API tokens, in the form USER@REALM!TOKENID=SECRET.
pve_api_token      = "tofu@pve!infra=00000000-0000-0000-0000-000000000000" # the cluster
greatfox_api_token = "tofu@pve!infra=00000000-0000-0000-0000-000000000000" # the standalone host

# inventory/auto.tfvars.secret/vyos.secret.auto.tfvars
vyos_api_key = "your-vyos-api-key"      # used for the leaves and the DHCP VMs

# inventory/auto.tfvars.secret/routeros.secret.auto.tfvars
routeros_password = "your-routeros-password"
# routeros_username = "admin"           # optional; this is the default
```

**Why one file per provider?** Each root links only the files for the providers
it uses, so it only ever sees variables it declares. That way OpenTofu prints no
"undeclared variable" warnings. Keep the `.secret.auto.tfvars` ending, because
OpenTofu only auto-loads files ending in `.auto.tfvars`.

Setting it up, from the top of the repo:

```sh
mkdir -m 700 inventory/auto.tfvars.secret
$EDITOR inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars    # and vyos..., routeros...
chmod 600 inventory/auto.tfvars.secret/*.secret.auto.tfvars

# Link each file into the roots that use it.
for root in proxmox-download-files proxmox-network fabric-vms services-vms workloads; do
  ln -s ../../inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars roots/$root/
done
for root in fabric-leaves services-config; do
  ln -s ../../inventory/auto.tfvars.secret/vyos.secret.auto.tfvars roots/$root/
done
ln -s ../../inventory/auto.tfvars.secret/routeros.secret.auto.tfvars roots/fabric-spines/

# Plain tofu now loads the right credentials by itself.
tofu -chdir=roots/services-config plan
```

The links are named `*.secret.auto.tfvars` too, so Git ignores them. To see what's
linked where:

```sh
find roots -maxdepth 2 -type l -name '*.secret.auto.tfvars' -printf '%h -> %l\n'
```

Two settings aren't in any secret file:

| Variable | Needed by | Notes |
| --- | --- | --- |
| `ssh_private_key_path` | the Proxmox roots (both providers SSH in as `root`), services-config (SSH to the DNS VMs) | Defaults to `~/.ssh/id_rsa`. If yours is different, `export TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519`. |
| `dns_tsig_secret` | services-config (optional) | Leave it out and a key is generated. See [services-config](../roots/services-config/README.md#the-tsig-key). |

Both Proxmox provider blocks live in one shared file, so every Proxmox root
needs **both** tokens, even if it never touches `greatfox`. If `vyos_api_key` is
unset, the VyOS provider reads the `VYOS_API_KEY` environment variable instead.

A few connection settings are fixed in `provider-config/` rather than set by
variables:

- **RouterOS** uses plain `http://<management_ip>`, so the RouterOS password
  travels unencrypted. Consider enabling `www-ssl` on the spines and switching
  `hosturl` to HTTPS.
- **Proxmox** endpoints are built from `nodes`: the cluster API is
  `cluster_api_node`'s management address, and the standalone provider uses the
  host named `greatfox`. TLS verification is off (`insecure = true`), because the
  hosts use self-signed certificates.

### The alternative: one file and the wrapper

If you'd rather not link anything, put every variable in one file,
`inventory/auto.tfvars/passwords.secret.auto.tfvars` (the format is in
[`examples/auto.tfvars/passwords.example.auto.tfvars`](../examples/auto.tfvars/passwords.example.auto.tfvars)).
Then run commands through `tooling/with-secrets` inside `nix-shell`:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan

# A different secrets file:
tooling/with-secrets --file ~/lab-secrets.tfvars tofu -chdir=roots/workloads plan
```

The wrapper reads the file and runs your command with each value set as an
environment variable, `TF_VAR_<name>`. OpenTofu silently ignores environment
variables it doesn't need, so a single shared file causes **no warnings** this
way. Also:

- The variables only exist for the child process. Nothing leaks into your shell.
- Types are preserved: numbers, booleans, lists and maps arrive intact.
- An entry set to `null` unsets its variable, so the default applies.
- The wrapper never prints secret values, not even when the file has a syntax
  error.
- The usual precedence still applies, so `-var` on the command line wins.
- **It refuses a root that links that same file**, because the root auto-loads
  it anyway. Use plain `tofu` there.

**The guided runner picks per root.** `tooling/walk-roots.sh` runs plain `tofu`
in any root that has a `*.secret.auto.tfvars` file linked in, and prints
`Secrets: auto-loading the per-provider files linked into this root.` Other roots
go through the wrapper when the single central file exists. `--no-secrets` turns
the wrapper off, so you can use credentials you've already exported as
`TF_VAR_*`.

## Naming conventions

- Use `snake_case`, and plural names for collections (`vms`, `vnis`, `leaves`).
- Use familiar network terms: `ip`, `vlan`, `vni`, `mac`. Write `management` in
  full, not `mgmt`.
- A `prefix` is a CIDR string (`"10.20.10.0/24"`). A `prefix_length` is a number
  (`16`).
- Keep provider field names exactly as the provider spells them.

## Renamed inputs

You only need this table if you have **private override files or a secrets file**
written before these renames. Everything tracked in this repo already uses the
new names.

| Old name | New name |
| --- | --- |
| `fabric.settings.vyos_mgmt_prefix` | `management_prefix` |
| `fabric.settings.vyos_mgmt_cidr` | `management_prefix_length` |
| `fabric_vms.management_cidr` | `management_prefix_length` (since removed, see below) |
| `fabric_vms.default_underlay_bridges` | `underlay_bridges` |
| `fabric.spines[*].uplink_if` | `uplink_interface` |
| VNI `border_leaf_ipv4_vpn_import_bool` | `import_ipv4_vpn` |
| VNI `border_leaf_ipv4_vrf_imports` | `import_ipv4_vrfs` |
| VM module `configure_data_nic_ips` | `configure_data_ips` |
| `local.ssh_pubkey` | `local.ssh_pubkeys` |
| `fabric.settings.bgp_system_as` | `fabric.settings.leaf_underlay_as_base` |
| `fabric.overlay_as` | `fabric.settings.overlay_as` |
| `fabric_vms.management_prefix`, `management_prefix_length` | removed; the leaf VMs use `fabric.settings.management_*` |
| `nodes.proxmox_cluster` + `nodes.proxmox` | one `nodes.proxmox` map, with `standalone = true` on `greatfox` |
| hard-coded `10.20.7.0/24` and cluster API URL | `nodes.management_prefix`, `nodes.cluster_api_node` |
| `nodes.*.cpu_cores`, `network_profile` | removed (they were unused) |
| VM shortcuts `cores`, `memory_mb`, `bridge`, `started`, `tags` | `config.cpu_cores`, `memory_mb`, `management_bridge`, `started`, `tags` |
| `owner = "services-vms-dns"` / `"services-vms-dhcp"` | `owner = "services-vms"` with `role = "dns"` / `"dhcp"` |
| `owner` defaulting to `"services-vms"` | `owner` is required |
| `gf_api_token` | `greatfox_api_token` (**rename it in your secrets file**) |
| hard-coded RouterOS `admin` / `admin` | `routeros_username` (default `admin`), `routeros_password` |
| hard-coded DHCP HA subnet `10.6.67.0/24` | services-config `dhcp_ha_prefix` (same default) |
| DHCP module `dhcp_ha_subnet` → `ha_subnet`, `fabric_macs` | `ha_prefix`, `interface_macs` |
| DHCP MAC module input `dhcp_vlans`, output `fabric_macs` | input `vnis` (it picks the DHCP VLANs itself), output `interface_macs` |
| one `passwords.secret.auto.tfvars` linked into roots | per-provider files in `inventory/auto.tfvars.secret/` (the single file still works with `with-secrets`) |

None of these needs a `tofu state mv`. Module labels and inventory keys didn't
change. Two spine resources were renamed (`BGP-LOOPBACKS` → `bgp_loopbacks`,
`test` → `leaf_uplinks`), and `moved` blocks in `modules/fabric/spines` move
their state automatically on the next plan.

## Fields that aren't used yet

These fields are declared in `schema/`, and some appear in the value files, but
no code reads them today. Changing them has no effect:

| File | Fields |
| --- | --- |
| `fabric.settings` | `l2_vni_base` |
| `vnis` (VRF level) | `ext_l3`, `import_ipv4_vrfs`, `redistribute_ipv4`, `anycast_mac` |
| `vnis` (VLAN level) | `advertise_default_gw`, `advertise_svi_ip`, `export_ipv4_unicast` |
| secrets | `ssh_keys` (in `ssh_keys.secret.auto.tfvars`) |
