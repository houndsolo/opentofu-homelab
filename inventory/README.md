# Inventory

The single source of truth for the lab: edit values here; every root reads them.

## How roots use these files

Each root symlinks the files it needs (`ls -l roots/<root>/` shows which):

```text
$ ls -l roots/fabric-leaves
fabric.auto.tfvars      -> ../../inventory/auto.tfvars/fabric.auto.tfvars
fabric.variables.tf     -> ../../inventory/schema/fabric.tf
vyoscmd-provider.tf     -> ../../inventory/provider-config/vyoscmd-provider.tf
versions.tf             -> ../../inventory/versions/vyos-versions.tf
vyos.secret.auto.tfvars -> ../../inventory/auto.tfvars.secret/vyos.secret.auto.tfvars
main.tf                 (the root's own code)
```

OpenTofu auto-loads every `*.auto.tfvars` in the root. Edit the files here, not the links; never
replace a link with a copy (that root silently stops seeing changes).

| Path | Contents |
| --- | --- |
| `auto.tfvars/` | The values you edit |
| `auto.tfvars.secret/` | Credentials, one file per provider/service. Git-ignored; see [Secrets](#secrets). |
| `schema/` | Variable declarations: types, defaults, validation. Also `state-encryption.tf` (encryption block + `state_passphrase`). |
| `provider-config/` | Provider blocks and their credential variables |
| `versions/` | OpenTofu and provider version pins |
| `ssh_pubkeys.tf` | Named SSH public keys VMs can select |

## The value files

| File | Variable(s) | Describes | Linked into |
| --- | --- | --- | --- |
| `nodes.auto.tfvars` | `nodes` | Proxmox hosts, IDs, how to reach them | every root except certs |
| `fabric.auto.tfvars` | `fabric` | AS numbers, addressing, physical leaves, spines, NTP/exporters/syslog | fabric-vms, fabric-spines, fabric-leaves, services-config, monitoring-config |
| `fabric-vms.auto.tfvars` | `fabric_vms` | Leaf VM naming and NICs | fabric-vms, fabric-leaves |
| `pve-network.auto.tfvars` | `pve_network` | Host NICs, bond, bridges, VLAN interfaces | proxmox-network, monitoring-config |
| `vm-config.auto.tfvars` | `vm_config`, `vm_images` | Shared VM defaults, named images | fabric-vms, services-vms, workloads |
| `vms.auto.tfvars` | `vms` | Every VM: owner, role, placement, NICs, overrides | proxmox-download-files, fabric-vms, services-vms, certs, services-config, monitoring-config, workloads |
| `vnis.auto.tfvars` | `vnis` | VRFs (L3VNIs), VLANs (L2VNIs), route-targets, DHCP scopes | fabric-leaves, services-vms, services-config |
| `l2vnis.auto.tfvars` | `l2vnis` | Standalone HA peer L2VNIs `ha_<svc>` (no VRF, gateway or DHCP): VLAN 10aa / VNI 50aa / `10.50.aa.0/24` | fabric-leaves, services-vms, services-config |
| `dns-records.auto.tfvars` | `dns_hosts`, `dns_records` | Extra records in `lylat.space` (what isn't generated) | services-config |
| `vips.auto.tfvars` | `vips` | Every keepalived VIP: DNS name, address, VRID, role | services-config, monitoring-config |
| `proxmox-settings.auto.tfvars` | `proxmox_settings` | Datacenter options, DNS, time zone of the hosts | proxmox-settings |
| `software-versions.auto.tfvars` | `containers`, `packages` | Every pinned software version | services-config, monitoring-config |

### nodes.auto.tfvars: Proxmox hosts

```hcl
nodes = {
  management_prefix = "10.20.7.0/24" # host management IP = .<ID>
  cluster_api_node  = "fichina"      # cluster provider endpoint: https://10.20.7.11:8006
  proxmox = {
    venom    = { id = 17 }                    # key = real PVE node name
    # fichina 11, macbeth 12, titania 13, zoness 14, fortuna 15, eldarad 16
    greatfox = { id = 20, standalone = true } # not in the cluster: proxmox.greatfox provider
  }
}
```

- **The ID drives almost everything** (addresses, leaf VM ID, MACs, BGP AS, DNS names; see
  [How IDs become names and addresses](#how-ids-become-names-and-addresses)). Changing one
  rebuilds things.
- **Checked**: IDs unique; at most one `standalone`; `cluster_api_node` is a cluster host.
- **Not checked, but required**: IDs 1-99 (they become a MAC octet; enforced only where
  [modules/fabric/macs](../modules/fabric/macs/README.md) runs); the standalone host must be named
  `greatfox` (`provider-config/proxmox-providers.tf` looks that name up).
- `management_prefix` is how OpenTofu reaches the hosts (API, SSH, DNS records). The hosts' real
  `vmbr0` address comes from `pve_network.bridges.0.ipv4`; keep the two describing the same
  addresses.

| Root | Cluster hosts | Standalone host |
| --- | --- | --- |
| proxmox-network | yes | no |
| fabric-vms, monitoring-config (metric servers) | yes | yes, via `proxmox.greatfox` |
| fabric-spines, fabric-leaves, services-config (DNS records) | yes | yes |

### fabric.auto.tfvars: AS numbers, addressing, leaves and spines

```hcl
fabric = {
  settings = {
    underlay_as_base          = 700                 # leaf/spine underlay AS = this + ID -> venom AS 717, m326-1 701
    overlay_as                = 700                 # iBGP EVPN AS, leaves and spines
    loopback_ipv4_prefix      = "10.255.240.0/24"   # router-IDs: .<ID>
    loopback_ipv6_prefix      = "fd69:255:240::/64" # VTEPs: ::<ID>
    loopback_interface        = "dum240"            # VyOS dummy holding both loopbacks
    management_prefix         = "10.20.10.0/24"     # leaf eth0 / API: .<ID> ...
    management_prefix_length  = 16                  # ... with this length -> 10.20.10.17/16
    l2_vni_base               = 9000                # unused
    ntp_servers               = ["10.20.10.255"]    # spines and leaves (fw-wan, mgmt network)
    leaf_ntp_vrf              = "mgmt"
    leaf_prometheus_exporters = { vrf = "mgmt" }
    leaf_syslog  = { hosts = ["10.20.11.34", "10.20.11.35", "10.20.11.36"], vrf = "mgmt" }
    spine_syslog = { host = "10.5.11.101" }
    # vxlan_mtu = 9119   # default; tenant side
    # outer_mtu = 9189   # default; underlay side
  }
  leaves = {           # physical leaves only; one "proxmox" leaf per Proxmox host is generated
    external_l2_01 = {
      role             = "external_l2" # proxmox, external_l2 or external_l3
      id               = 42            # unique across leaves AND spines (shared loopback prefix)
      access_interface = "eth3"        # trunk towards hosts
      spine_uplink     = "ether10"     # spine port, if not ether<ID>
    }
    # external_l3_01 (id 18), external_l3_02 (id 19)
  }
  spines = {
    m326-1 = {
      management_ip = "10.20.0.5" # REST API at http://<management_ip>
      id            = 1           # loopback ::1; leaves reach it on eth1
      # uplink_interface = "eth5" # leaf-side port, if not eth<ID>
    }
    # m326-2: 10.20.0.6, id 2
  }
}
```

Ports by default: on a leaf, spine *N* is `ethN`; on a spine, leaf *ID* is `ether<ID>`
(`ether17` faces venom); generated Proxmox leaves use `eth<spines + 1>` (`eth3`) as access port.

`management_prefix`/`_length` feed the leaf VMs' `eth0` (fabric-vms), the API address
(fabric-leaves) and the `leaf-<ID>` DNS records (services-config), so they can't drift.
Route-targets in `vnis.auto.tfvars` are literal: changing an AS doesn't rewrite them.

Optional settings (null/absent = don't manage; never removes existing config):

| Setting | Effect |
| --- | --- |
| `ntp_servers` | NTP servers for spines and leaves. Default `["0.pool.ntp.org", "1.pool.ntp.org"]`. On leaves, VyOS's built-in servers not in the list (`0/1.pool.ntp.org`, `time1`-`time3.vyos.net`) are deleted. `[]` = don't manage. |
| `leaf_ntp_vrf` | VRF the leaf NTP client runs in (`mgmt`, to reach fw-wan). Spines ignore it. |
| `leaf_prometheus_exporters` | VyOS node-exporter (9100) and frr-exporter (9342, with `bgp-l2-vpn` collector and peer-hostname labels) on each leaf's mgmt address in `vrf`. Scraped by monitoring-config (`vyos-node`, `vyos-frr`). |
| `leaf_syslog` | Leaf syslog (facility `all`, level `info`+) to every host in `hosts` (loki01-03's own mgmt addresses; no VIP on mgmt), from `vrf`. TCP 514, RFC 5424 with timezone, octet-counted framing. Options: `port`, `protocol` (`tcp`/`udp`), `facility`, `level`. The DHCP VMs get the same commands from services-config's `dhcp_syslog`. |
| `spine_syslog` | Spines' built-in `remote` action to the Loki/Alloy VIP (`logs-vip`): UDP 514, BSD syslog (RFC 3164), facility `daemon`, sent from the VLAN 5 address. One logging rule per `topics` entry (default `info`, `warning`, `error`, `critical`). Options: `port`, `facility`, `topics`. |

### fabric-vms.auto.tfvars: the leaf VMs

```hcl
fabric_vms = {
  hostname_prefix  = "vtep-" # VM name = prefix + node -> vtep-venom
  vm_id_offset     = 700     # VM ID = node ID + offset -> 717
  underlay_bridges = ["vmbr4001", "vmbr4002", "vmbr4000"] # -> eth1, eth2, eth3
}
```

The bridge order must match the leaf config: `eth1` spine 1, `eth2` spine 2, `eth3` access trunk.
Management addresses come from `fabric.settings`. Per-VM overrides:
[fabric-vms](../roots/fabric-vms/README.md#overriding-one-leaf-vm).

### pve-network.auto.tfvars: host networking

One profile for **every cluster host** (not the standalone one), so NIC names must match across
hosts. Map keys become interface names:

| Map | Key `7` becomes | Fields |
| --- | --- | --- |
| `eths` | `eth7` | MTU and comment on an existing NIC |
| `bonds` | `bond7` | `slaves`, `bond_mode`, `bond_xmit_hash_policy` |
| `bridges` | `vmbr7` | `ports`, `vlan_aware`, `gateway`, optional `ipv4` |
| `vlans` | `<port>.7` | parent `port`: key `2` on `vmbr4000` = `vmbr4000.2` |

```hcl
bridges = {
  0 = {                                # -> vmbr0
    mtu = 9119, description = "mgmt", vlan_aware = false, ports = ["eth0"]
    ipv4 = {
      cidrhost_prefix = "10.20.7.0/24" # picks the address: .<node ID> -> 10.20.7.17
      cidr            = 16             # prefix length configured -> 10.20.7.17/16
    }
  }
}
```

`gateway` is shared by every host; the only one today is on `vlans.2` (`10.2.0.1`). Per-host
result: [proxmox-network](../roots/proxmox-network/README.md).

### vm-config.auto.tfvars: shared VM defaults and images

```hcl
vm_config = {                 # defaults for every VM; full list in schema/vm-config.tf
  datastore_id = "ceph_rbd"   # required
  import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2" # required
  started      = true
}
vm_images = {                 # a VM picks one with image = "<name>"
  debian13 = { import_image = "cephfs:import/debian-13-genericcloud-amd64.qcow2", tags = ["opentofu", "debian"] }
  vyos = {
    import_image      = "cephfs:import/vyos-1.5-rolling-202611140411-generic-amd64.qcow2"
    user_data_file_id = "cephfs:snippets/vyos_api.yml" # enables the VyOS API
    tags              = ["opentofu", "vyos"]
  }
}
```

Images and snippets must already exist in Proxmox (the Debian image can come from
[proxmox-download-files](../roots/proxmox-download-files/README.md); the VyOS image and snippet are
manual). A VM's settings are merged in three layers, later wins:

1. `vm_config`, falling back to `schema/vm-config.tf` defaults (4 cores, 4096 MB, 10 GB disk,
   management on `vmbr0`, guest agent on, ...).
2. The selected `vm_images` entry: its `import_image` and `user_data_file_id` always replace the
   defaults (so `debian13` clears a VyOS snippet set in `vm_config`); `tags` if set.
3. The VM's own `config = { ... }`: any `vm_config` key.

### vms.auto.tfvars: individual VMs

One `vms` map. `owner` decides which root creates the VM; service VMs also take a `role`:

| `owner` | `role` | Configured by | VMs today / rules |
| --- | --- | --- | --- |
| `services-vms` | `dns` | services-config (BIND) | `dns01`, `dns02`; exactly one NIC with `ipv4_address` + `ipv4_gateway` (the service address) |
| `services-vms` | `dhcp` | services-config (VyOS DHCP) | `dhcp01`, `dhcp02`; exactly two or none; VM IDs 6701-6799; NICs generated |
| `services-vms` | `monitoring` | monitoring-config (Prometheus, Alertmanager, exporters, Telegraf) | `mon01`, `mon02` |
| `services-vms` | `grafana` | monitoring-config | `graf01`, `graf02` |
| `services-vms` | `logging` | monitoring-config (Loki, Alloy) | `loki01`-`loki03` |
| `services-vms` | `metrics` | monitoring-config (Mimir) | `mim01`-`mim03` |
| `services-vms` | `postgres` | monitoring-config (Patroni + etcd + pgBackRest) | `pg01`-`pg03`; odd count >= 3; DB for Grafana, NetBox, dark-triage |
| `services-vms` | `ticketing` | services-config (dark-triage) | `triage01`, `triage02` |
| `services-vms` | `netbox` | services-config | `netbox01`, `netbox02` |
| `services-vms` | `valkey` | services-config (Valkey + Sentinel) | `valkey01`-`valkey03` |
| `services-vms` | `proxy` | certs, services-config (nginx) | `proxy01`, `proxy02` |
| `services-vms` | none | nothing | any other service VM |
| `workloads` | none | nothing | ordinary VMs |
| `fabric-vms` | none | fabric-leaves | only **overrides** of generated `vtep-<node>` VMs |

```hcl
vms = {
  dns01 = {
    owner              = "services-vms"
    role               = "dns"
    ha                 = { group = "dns" } # optional Proxmox HA (services-vms only); a group never shares a node
    node               = "venom"
    vm_id              = 5301              # unique
    image              = "debian13"        # key in vm_images
    management_address = "10.20.53.1/16"   # net0/eth0, static IPv4 CIDR, required (no DHCP)
    # gateway          = "10.20.0.1"       # optional, on the management NIC
    network_devices = [{                   # eth1, eth2, ... in order
      bridge       = "vmbr4000"
      vlan_id      = 8                     # Proxmox tags it; the guest sees an untagged NIC
      ipv4_address = "10.8.53.1/16"        # cloud-init, first boot only
      ipv4_gateway = "10.8.0.1"            # anycast gateway on the local leaf
      # ipv6_address, mac_address, model, mtu, disconnected
    }]                                     # (+ lylat-dns 1301, ha_dns 1053, telemetry 1501 NICs)
    config = {                             # any vm_config key, plus the cloud-init user and keys
      cpu_cores    = 2
      memory_mb    = 3072
      ssh_username = "mechanic"
      ssh_pubkeys  = ["desktop"]           # names from ssh_pubkeys.tf
    }
  }
}
```

Checked at plan:

- `owner` is required: `fabric-vms`, `services-vms` or `workloads`. `role` only with
  `services-vms`, one of the roles above. `ha` only on `services-vms` VMs with a `node`.
- Every VM except a `fabric-vms` override needs `node`, `vm_id` and `management_address`
  (IPv4 CIDR, not `dhcp`).
- `dns`: exactly one NIC with `ipv4_address` and `ipv4_gateway`. `dhcp`: none or exactly two,
  distinct VM IDs.
- `config.ssh_pubkeys` names must exist in `ssh_pubkeys.tf`, and can't be combined with a custom
  `user_data_file_id` (the snippet replaces the user-data that carries the keys).

Cloud-init configures only NICs with an address, and only at first boot: changing addresses or
keys on an existing VM means changing them in the guest or recreating the VM.

`schema/vm.tf` (one VM, as the module sees it), `schema/vms.tf` (the map) and
`schema/vm-config.tf` repeat the same fields (OpenTofu can't share object types);
`tooling/tests/test_schemas.py` keeps them in step. Add a VM setting to all three.

### vnis.auto.tfvars: VRFs, VLANs and DHCP scopes

A list of VRFs (L3VNIs), each with a map of VLANs (L2VNIs). The real `lylat-dns`, trimmed to VLAN 8:

```hcl
vnis = [
  {
    vrf       = "lylat-dns" # unique, starts with a letter, <= 15 chars (VyOS)
    vrf_table = 5300        # unique
    vni       = 5300        # L3VNI
    vlan_id   = 1300        # internal VLAN carrying the L3VNI on br0 (unique)
    roles     = ["proxmox"] # leaf roles that get this VRF

    # Local route leaking inside each leaf (BGP VPN). Space-separated strings.
    ipv4_rt_imports = "700:5100 700:5200 700:5400 700:5600 700:6900 700:6700 700:6666"
    ipv4_rt_exports = "700:5300"
    import_ipv4_vpn = true
    export_vpn_ipv4 = true

    # EVPN route-targets between leaves (import another VRF's RT to reach it: DVNI).
    evpn_rt_imports = ["700:5300", "700:5100", "700:5200", "700:5400", "700:5600", "700:6900", "700:6700", "700:6666"]
    evpn_rt_exports = ["700:5300"]

    l2 = {
      8 = {                                   # label; by convention the VLAN number
        vni             = 9008                # unique across all L2 and L3 VNIs
        vlan_id         = 8                   # tag on vmbr4000 (unique)
        anycast_gw_ip   = "10.8.0.1"
        anycast_gw_cidr = 16                  # number -> 10.8.0.0/16
        anycast_mac     = "02:00:00:00:08:01"
        anycast_gw_ipv6 = "fd69:9008::1/64"   # optional
        # router_advert = true                # RAs on the IPv6 gateway (no SLAAC)
        dhcp = {                              # present -> DHCP VMs get a NIC here
          scope = {                           # present -> DHCP VMs serve a pool here
            ranges = { 0 = { start = "10.8.5.1", stop = "10.8.5.99" } }
          }
        }
      }
    }
  },
]
```

Conventions in the live file:

- **Legacy VLANs** (2, 8-12): L2VNI 9000 + VLAN, gateway `.0.1`, MAC `02:00:00:00:<VLAN>:01`
  (VLAN as decimal digits).
- **Zone VRFs** (DT-090, Z = 51 edge, 52 app, 53 dns, 54 obs, 55 telemetry, 56 data): L3VNI and
  table `Z00`, L3 VLAN `Z00 - 4000`, one segment L2VNI `Z01` / VLAN `Z01 - 4000` / `10.Z.0.0/16`,
  gateway `10.Z.0.1` and `fd69:Z01::1/64`. `router_advert = true` (RAs without SLAAC, router
  lifetime 0, route `fd69::/16`) on all but lylat-telemetry. lylat-edge has no segment (it holds
  VLAN 2; 10.51.0.0/16 reserved); lylat-dns also holds VLAN 8.
- **Default route**: only `lylat-external` sends 0.0.0.0/0 into EVPN; every other VRF denies it
  (`PL-DEFAULT-ROUTE` in the leaf route-maps).
- **Isolated VRF** (`lylat-telemetry`): `import_ipv4_vpn = export_vpn_ipv4 = false`, and only its
  own RT in `evpn_rt_imports`/`evpn_rt_exports`.

`import_ipv4_vpn` / `export_vpn_ipv4` drive the leaf's VPN leaking (`import vpn` /
`route-target vpn import`; `export vpn` / `rd vpn export` / `route-map vpn export` /
`route-target vpn export`).

Checked: valid roles; VNIs 1-16777215 and unique across L2 and L3; VRF names, tables and VLAN IDs
(L2 + L3) unique; gateways valid IPv4 with prefix length; six-octet MACs; `ipv4_rt_imports` set
when `import_ipv4_vpn`, `ipv4_rt_exports` when `export_vpn_ipv4`; `ext_l3_peer` needs `ext_l3 =
true` and the `external_l3` role. Standalone `l2vnis` must not reuse a VNI/VLAN from `vnis`
(checked in the leaf module).

Not checked, but required:

- **DHCP VLANs must be 1-99** (the VLAN becomes a MAC octet; the DHCP MAC calculator fails the plan).
- **DHCP subnets must contain `10.<VLAN>.67.1` and `.2`** (the DHCP VMs' addresses): keep the
  `10.<VLAN>.0.0/16` convention.
- **The DHCP HA link** is `l2vnis.ha_dhcp` (VNI 5009 / VLAN 1009, `10.50.9.0/24`, `.1`/`.2`),
  not a DHCP VLAN.

| `dhcp` setting | Effect | Default |
| --- | --- | --- |
| `dhcp = {}` (no `scope`) | DHCP VMs get a NIC, address and listen interface, no pool | |
| `scope.ranges` | Pools; map keys become VyOS range IDs | required in a scope |
| `scope.name_servers` | DNS servers for clients | DNS VIP `10.8.53.53` (DNS VMs `.1`, `.2` if services-config `dns_vrrp` is null) |
| `scope.domain_name` | Domain name | `lylat.space` |
| `scope.domain_search` | Search list; `[]` sends none | `[domain_name]` |
| `scope.lease_seconds` | Lease time | `86400` |
| `scope.authoritative` | Authoritative server | `true` |

### l2vnis.auto.tfvars: HA peer segments

```hcl
l2vnis = {
  ha_dhcp = { vni = 5009, vlan_id = 1009, prefix = "10.50.9.0/24", description = "DHCP Kea HA heartbeat (dhcp01 .1, dhcp02 .2)" }
  # roles = ["proxmox"] (default), on_standalone = false (default: not on greatfox's leaf)
}
```

Unicast peer traffic only (keepalived adverts, Kea HA, memberlist/gRPC, gossip, Postgres
replication, etcd); VIPs stay on the client-facing NICs. `prefix` isn't configured on the fabric:
it is the source of truth for host addresses (host octet = the VM's host octet).

### dns-records.auto.tfvars: your DNS records

```hcl
dns_hosts = {
  torrent = { A = "10.8.7.7" }   # owner (relative to lylat.space) => { type = value }
}
dns_records = [                  # several values of one type, or a custom TTL
  # { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
]
```

Generated, so don't list them: every VM as `<vm>` (service NIC) and `<vm>.mgmt`, every VIP, the
Proxmox hosts, `leaf-<ID>`, `spine-<ID>` (each also `<name>.mgmt`). A `dns_hosts` entry may add
other types to a generated name; redefining a generated type fails the plan. Format rules:
[services-config](../roots/services-config/README.md#dns-records).

### vips.auto.tfvars: keepalived VIPs

```hcl
vips = {
  netbox-vip = { address = "10.52.12.106/16", vrid = 106, role = "netbox" } # key = DNS name
}
```

services-config publishes A/PTR records; services-config and monitoring-config check each service's
own VIP setting (`netbox.vip`, `grafana_vrrp`, `postgres_settings.vip`, ...) against it. Addresses
are unique; a VRID belongs to one role (it is the VMAC's last byte, `00:00:5e:00:01:<vrid>`), so
one role may reuse its VRID across networks (e.g. `logs-vip`, `loki-vip`, `loki-telemetry-vip` = 101).

### software-versions.auto.tfvars: pinned versions

```hcl
containers = {
  grafana = { image = "docker.io/grafana/grafana", version = "<tag>" }
  bind9   = { image = "docker.io/internetsystemsconsortium/bind9", version = "9.20", digest = "sha256:..." }
}
packages = {
  postgresql = "<version>" # Patroni stack on pg01-03: postgresql, patroni, etcd, pgbackrest
}
```

Bump one entry, plan the root(s) named in the file's section comments, apply. `version` is a tag
(or `sha256:` digest); `digest` pins a moving tag. Package versions are the upstream version
(any Debian revision) or a full Debian version; a Postgres **major** change builds a new cluster
(see the file comments). Not covered: dark-triage (git commit, `var.ticketing.commit`), the PVE
nodes' Alloy `.deb` (pinned in `roots/monitoring-config/log-senders/pve-alloy-install.sh`; keep it
in step with `containers.alloy`), the OpenTofu providers (`versions/`).

### ssh_pubkeys.tf: named SSH public keys

```hcl
locals {
  ssh_pubkeys = {
    desktop = "ssh-rsa AAAA... houndsolo@arch"
    # laptop = "ssh-ed25519 AAAA... laptop"
  }
}
```

VMs select keys with `config.ssh_pubkeys = ["desktop"]`; cloud-init installs them for
`config.ssh_username`. Unknown names fail the plan. A `.tf` file (a `locals` block), linked into
fabric-vms, services-vms and workloads. **Public keys only.**

## How IDs become names and addresses

Everything derived from venom's ID, 17:

| What | Value | From |
| --- | --- | --- |
| Proxmox management | `10.20.7.17/16` on `vmbr0` | `pve_network.bridges.0.ipv4` (`nodes.management_prefix` to reach it) |
| Host address on VLAN 2 | `10.2.0.17/16` on `vmbr4000.2` | `pve_network.vlans.2.ipv4` |
| Leaf VM name / ID | `vtep-venom`, `717` | `fabric_vms.hostname_prefix`, ID + `vm_id_offset` |
| Leaf management / API | `10.20.10.17/16`, `https://10.20.10.17` | `fabric.settings.management_prefix`, `_length` |
| Router-ID / IPv4 loopback | `10.255.240.17` | `loopback_ipv4_prefix` |
| VTEP / IPv6 loopback | `fd69:255:240::17` | `loopback_ipv6_prefix` |
| Leaf VXLAN/bridge MAC | `00:13:37:00:00:17` | `modules/fabric/leaf/addressing.tf` |
| Leaf NIC MACs (eth1-eth3) | `02:00:00:17:00:01`-`:03` | [modules/fabric/macs](../modules/fabric/macs/README.md) |
| Leaf underlay AS | `717` | `underlay_as_base` + ID |
| Spine port facing the leaf | `ether17` | `ether<ID>` |
| Leaf hostname | `LEAF-17` | `modules/fabric/leaf/system.tf` |
| DNS | `venom.lylat.space` → `10.20.7.17`, `leaf-17.lylat.space` → `10.20.10.17` | services-config |

IPv6 addresses and MACs read the decimal ID as hex digits (`parseint("17", 16)`), so everything
for node 17 visibly contains `17`.

## Secrets

### The per-provider secret files

One small file per provider/service in `inventory/auto.tfvars.secret/`, needed only on the
machine that runs OpenTofu. Git ignores the directory and any `*.secret.auto.tfvars` /
`*.secret.tfvars`. Keep the directory `700`, the files `600`.

| File | Variables | Linked into |
| --- | --- | --- |
| `proxmox.secret.auto.tfvars` | `pve_api_token`, `greatfox_api_token` | proxmox-download-files, proxmox-network, proxmox-settings, fabric-vms, services-vms, monitoring-config, workloads |
| `vyos.secret.auto.tfvars` | `vyos_api_key` | fabric-leaves, services-config |
| `routeros.secret.auto.tfvars` | `routeros_password` (`routeros_username` if not `admin`) | fabric-spines |
| `monitoring.secret.auto.tfvars` | `grafana_admin_password` (optional; else generated) and other optional monitoring-config secrets | monitoring-config |
| `logging.secret.auto.tfvars` | `loki_s3` (RGW user) | monitoring-config |
| `metrics.secret.auto.tfvars` | `mimir_s3` (RGW user) | monitoring-config |
| `postgres.secret.auto.tfvars` | `postgres_s3` (RGW user for pgBackRest) | monitoring-config |
| `app-db.secret.auto.tfvars` | `app_db_passwords` (app database passwords) | services-config, monitoring-config |
| `netbox.secret.auto.tfvars` | `netbox_cephfs_key` (CephFS key for the media mount) | services-config |
| `gitea.secret.auto.tfvars` | `gitea_cephfs_key` (CephFS key of client.gitea, `/gitea`) | services-config |
| `cloudflare.secret.auto.tfvars` | `cloudflare` (API token per zone, DNS-01) | certs |
| `state.secret.auto.tfvars` | `state_passphrase` (state/plan encryption, >= 32 chars) | certs, services-config |
| `ssh_keys.secret.auto.tfvars` | `ssh_keys` | nothing (no root reads it) |

```hcl
# proxmox.secret.auto.tfvars: tokens as USER@REALM!TOKENID=SECRET
pve_api_token      = "tofu@pve!infra=00000000-0000-0000-0000-000000000000" # cluster
greatfox_api_token = "tofu@pve!infra=00000000-0000-0000-0000-000000000000" # standalone host
# vyos.secret.auto.tfvars
vyos_api_key = "your-vyos-api-key"   # leaves and DHCP VMs
# routeros.secret.auto.tfvars
routeros_password = "your-routeros-password"
```

One file per provider means each root only sees variables it declares (no "undeclared variable"
warnings). Keep the `.secret.auto.tfvars` suffix (auto-load + git-ignore). Linking:

```sh
for root in proxmox-download-files proxmox-network proxmox-settings fabric-vms services-vms monitoring-config workloads; do
  ln -s ../../inventory/auto.tfvars.secret/proxmox.secret.auto.tfvars roots/$root/
done
for root in fabric-leaves services-config; do
  ln -s ../../inventory/auto.tfvars.secret/vyos.secret.auto.tfvars roots/$root/
done
ln -s ../../inventory/auto.tfvars.secret/routeros.secret.auto.tfvars roots/fabric-spines/
for f in monitoring logging metrics postgres app-db; do
  ln -s ../../inventory/auto.tfvars.secret/$f.secret.auto.tfvars roots/monitoring-config/
done
for f in netbox app-db state; do
  ln -s ../../inventory/auto.tfvars.secret/$f.secret.auto.tfvars roots/services-config/
done
for f in cloudflare state; do
  ln -s ../../inventory/auto.tfvars.secret/$f.secret.auto.tfvars roots/certs/
done

find roots -maxdepth 2 -type l -name '*.secret.auto.tfvars' -printf '%h -> %l\n'   # what's linked where
```

Not in any secret file:

| Variable | Used by | Notes |
| --- | --- | --- |
| `ssh_private_key_path` | Proxmox roots (providers SSH as `root`), certs, services-config, monitoring-config | Default `~/.ssh/id_rsa`; else `export TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519` |
| `dns_tsig_secret` | services-config (optional) | Generated if unset; see [services-config](../roots/services-config/README.md#the-tsig-key) |

Gotchas:

- Both Proxmox provider blocks are in one shared file, so every Proxmox root needs **both**
  tokens, even if it never touches greatfox.
- `vyos_api_key` unset → the provider reads `VYOS_API_KEY`.
- RouterOS is plain `http://<management_ip>`: the password travels unencrypted (consider
  `www-ssl` and an HTTPS `hosturl`).
- Proxmox endpoints come from `nodes` (`cluster_api_node`, and the host named `greatfox`); TLS
  verification is off (`insecure = true`, self-signed certs).

### The alternative: one file and the wrapper

Put every variable in `inventory/auto.tfvars/passwords.secret.auto.tfvars` (format:
[`examples/auto.tfvars/passwords.example.auto.tfvars`](../examples/auto.tfvars/passwords.example.auto.tfvars))
and run through `tooling/with-secrets`:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
tooling/with-secrets --file ~/lab-secrets.tfvars tofu -chdir=roots/workloads plan
```

It sets each value as `TF_VAR_<name>` for the child process only (types preserved, `null` unsets,
values never printed, `-var` still wins). OpenTofu ignores unused `TF_VAR_*`, so no warnings. It
refuses a root that links that same file. `walk-roots.sh` runs plain `tofu` in roots with a linked
`*.secret.auto.tfvars` and uses the wrapper elsewhere when the central file exists. Details:
[tooling](../tooling/README.md#with-secrets).

## Naming conventions

- `snake_case`; plural names for collections (`vms`, `vnis`, `leaves`).
- Network terms: `ip`, `vlan`, `vni`, `mac`; write `management`, not `mgmt`.
- `prefix` = CIDR string (`"10.20.10.0/24"`); `prefix_length` = number (`16`).
- Provider field names as the provider spells them.

## Fields that aren't used yet

Declared in `schema/` (some set in the value files) but read by no code:

| File | Fields |
| --- | --- |
| `fabric.settings` | `l2_vni_base` |
| `vnis` (VRF level) | `import_ipv4_vrfs`, `redistribute_ipv4`, `anycast_mac` |
| `vnis` (VLAN level) | `advertise_default_gw`, `advertise_svi_ip`, `export_ipv4_unicast` |
| secrets | `ssh_keys` |
