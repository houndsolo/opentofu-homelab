# services-vms

This root creates the **service VMs**: DNS, DHCP, the monitoring stack, NetBox, Valkey,
dark-triage and the reverse proxy. It only builds the VMs (hardware, disks, NICs, cloud-init).
The software inside them is set up afterwards by
[services-config](../services-config/README.md) and [monitoring-config](../monitoring-config/README.md).

## Which VMs

Every entry in [`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars)
with `owner = "services-vms"`. Its `role` says what kind of service VM it is:
`dns`, `dhcp`, `monitoring`, `grafana`, `logging`, `metrics`, `postgres`, `ticketing`, `netbox`,
`valkey`, `proxy`, or no role at all for any other service
VM. All of them are built with the shared
[VM module](../../modules/README.md#proxmoxvm). Today that's (VLAN = tag on `vmbr4000` unless a bridge
is named; the zone VLANs 1201/1301/1401/1601 are lylat-app/-dns/-obs/-data, 1501 is lylat-telemetry,
10aa the service's HA segment):

| VM | Role | Node | VM ID | Image | Management (eth0) | Data NICs |
| --- | --- | --- | --- | --- | --- | --- |
| `dns01` | `dns` | venom | 5301 | `debian13` | `10.20.53.1/16` | eth1: VLAN 8 `10.8.53.1/16`, gateway `10.8.0.5`; eth2: VLAN 1301 `10.53.53.51/16`; eth3: VLAN 1053 `10.50.53.51/24`; eth4: VLAN 1501 `10.55.53.51/16` |
| `dns02` | `dns` | eldarad | 5302 | `debian13` | `10.20.53.2/16` | same as `dns01` with `10.8.53.2` and `.52` |
| `dhcp01` | `dhcp` | venom | 6701 | `vyos` | `10.20.67.1/16` | generated (see below) |
| `dhcp02` | `dhcp` | eldarad | 6702 | `vyos` | `10.20.67.2/16` | generated |
| `mon01` | `monitoring` | zoness | 1130 | `debian13` | `10.20.11.30/16` | eth1: VLAN 1401 `10.54.16.30/16`, gateway `10.54.0.1`; eth2: `vmbr100` (untagged) `10.5.11.30/16`; eth3: VLAN 1016 `10.50.16.30/24`; eth4: VLAN 1501 `10.55.16.30/16` |
| `mon02` | `monitoring` | macbeth | 1131 | `debian13` | `10.20.11.31/16` | same as `mon01` with `.31` |
| `graf01`, `graf02` | `grafana` | venom, eldarad | 1132, 1133 | `debian13` | `10.20.11.32`, `.33/16` | eth1: VLAN 1201 `10.52.11.32`/`.33/16`, gateway `10.52.0.1`; eth2: VLAN 1011 `10.50.11.32`/`.33/24`; eth3: VLAN 1501 `10.55.11.32`/`.33/16` |
| `loki01`–`loki03` | `logging` | zoness, titania, fortuna | 1134–1136 | `debian13` | `10.20.11.34`–`.36/16` | eth1: VLAN 1401 `10.54.18.34`–`.36/16`, gateway `10.54.0.1`; eth2: `vmbr100` `10.5.11.34`–`.36/16`; eth3: `vmbr27` (Ceph public) `10.27.11.34`–`.36/16`; eth4: VLAN 1018 `10.50.18.34`–`.36/24`; eth5: VLAN 1501 `10.55.18.34`–`.36/16` |
| `mim01`–`mim03` | `metrics` | fichina, venom, eldarad | 1137–1139 | `debian13` | `10.20.11.37`–`.39/16` | eth1: VLAN 1401 `10.54.17.37`–`.39/16`, gateway `10.54.0.1`; eth2: `vmbr27` `10.27.11.37`–`.39/16`; eth3: VLAN 1017 `10.50.17.37`–`.39/24`; eth4: VLAN 1501 `10.55.17.37`–`.39/16` |
| `pg01`–`pg03` | `postgres` | titania, fortuna, venom | 1140–1142 | `debian13` | `10.20.11.40`–`.42/16` | eth1: VLAN 1601 `10.56.14.40`–`.42/16`, gateway `10.56.0.1`; eth2: `vmbr27` `10.27.11.40`–`.42/16`; eth3: VLAN 1014 `10.50.14.40`–`.42/24`; eth4: VLAN 1501 `10.55.14.40`–`.42/16` |
| `triage01`, `triage02` | `ticketing` | fichina, titania | 1143, 1144 | `debian13` | `10.20.11.43`, `.44/16` | eth1: VLAN 1201 `10.52.13.43`/`.44/16`, gateway `10.52.0.1`; eth2: VLAN 1013 `10.50.13.43`/`.44/24`; eth3: VLAN 1501 `10.55.13.43`/`.44/16` |
| `netbox01`, `netbox02` | `netbox` | macbeth, venom | 1145, 1146 | `debian13` | `10.20.11.45`, `.46/16` | eth1: VLAN 1201 `10.52.12.45`/`.46/16`, gateway `10.52.0.1`; eth2: `vmbr27` `10.27.11.45`/`.46/16` (CephFS); eth3: VLAN 1012 `10.50.12.45`/`.46/24`; eth4: VLAN 1501 `10.55.12.45`/`.46/16` |
| `valkey01`–`valkey03` | `valkey` | fichina, titania, fortuna | 1147–1149 | `debian13` | `10.20.11.47`–`.49/16` | eth1: VLAN 1601 `10.56.15.47`–`.49/16`, gateway `10.56.0.1`; eth2: VLAN 1501 `10.55.15.47`–`.49/16` |
| `proxy01`, `proxy02` | `proxy` | macbeth, fichina | 1150, 1151 | `debian13` | `10.20.11.50`, `.51/16` | eth1: VLAN 2 `10.2.11.50`/`.51/16`, gateway `10.2.0.5`; eth2: VLAN 1201 `10.52.10.50`/`.51/16`; eth3: VLAN 1010 `10.50.10.50`/`.51/24`; eth4: VLAN 1501 `10.55.10.50`/`.51/16` |

The zone and telemetry NICs also get a static IPv6 address `fd69:<VNI>::<aa>:<host>/64` (e.g. graf01
`fd69:5201::11:32`), the HA NICs `fd69:50aa::<host>/64` (keepalived's VRRPv3 adverts use them).

Sizes are set in each VM's `config`: 2 cores and 2048 MB for the DHCP, proxy and dark-triage VMs
(DNS 3072 MB; Grafana, NetBox and Postgres 4096 MB), 1 core and 1024 MB for Valkey,
4 cores, 8192 MB and a 200 GB disk for `mon01`/`mon02`, and
4 cores, 8192 MB and a 60 GB disk for the Loki and Mimir VMs. Each pair or trio is
split across hosts (see [Proxmox HA](#proxmox-ha)), so losing one host doesn't take out a service.

## DNS VMs

- **NICs.** They get exactly the NICs listed in the inventory: the management
  NIC (net0 on `vmbr0`) plus `network_devices`.
- **Cloud-init** sets both addresses at first boot. It also creates
  `config.ssh_username` with the keys selected in `config.ssh_pubkeys`.
- **Routing.** There's no management gateway, so the data NIC's gateway
  (`10.8.0.5`, the anycast gateway on the local leaf) is the VM's only default
  route.

Before `services-config` can set them up, the DNS VMs also need:

- **Exactly one NIC with an `ipv4_address` and an `ipv4_gateway`.** That address becomes the DNS
  service address, and `plan` fails if there are none or several. Today it's the
  VLAN 8 NIC on `vmbr4000`. The other NICs (lylat-dns, `ha_dns`, lylat-telemetry) carry no gateway.
- **Podman** (with Quadlet) and **qemu-guest-agent**. The stock Debian cloud
  image includes neither; see
  [proxmox-download-files](../proxmox-download-files/README.md#this-is-the-stock-image).
- **Internet access** through VLAN 8, to pull the BIND container image.

## DHCP VMs

You never list the DHCP VMs' data NICs yourself. This root generates them from
the VLANs, and replaces any `network_devices` you write:

- **One NIC per DHCP-enabled VLAN.** That's every L2VNI with a `dhcp` block in
  `vnis.auto.tfvars`, sorted by VLAN number.
- **On `vmbr4000`**, tagged with the VLAN.
- **With a fixed MAC**, `02:00:00:67:<VM ID % 100>:<VLAN>`, from
  [modules/services/dhcp/macs](../../modules/services/dhcp/macs/README.md).

With today's VLANs, `dhcp01` gets these (`dhcp02` is the same with `:02:` in
place of `:01:`):

| Interface | VLAN | MAC |
| --- | --- | --- |
| eth1 | 2 | `02:00:00:67:01:02` |
| eth2 | 8 | `02:00:00:67:01:08` |
| eth3 | 9 | `02:00:00:67:01:09` |
| eth4 | 10 | `02:00:00:67:01:10` |
| eth5 | 12 | `02:00:00:67:01:12` |
| eth6 | 1009 (`l2vnis.ha_dhcp`, Kea HA) | `02:00:00:67:01:ff` |

VLAN 11 has no `dhcp` block, so it gets no NIC. The Kea HA NIC always comes last.

Cloud-init only configures the management NIC on the DHCP VMs. Their VLAN
addresses (`10.<VLAN>.67.<1|2>`) are set later by `services-config` through
the VyOS API.

Rules that are checked for you:

- Exactly two DHCP VMs, or none.
- Unique VM IDs between 6701 and 6799.
- DHCP VLANs between 1 and 99.

**Adding or removing a DHCP VLAN renumbers the NICs.** Every VLAN keeps its MAC,
but every VLAN numbered above the one you added or removed moves to a different
`ethN`. Plan `services-vms` and `services-config` together, and apply them one
after the other.

## Monitoring, Grafana, Loki, Mimir and Postgres VMs

`mon01`/`mon02` (`role = "monitoring"`, sized for Prometheus), `graf01`/`graf02` (`role = "grafana"`),
`loki01`–`loki03` (`role = "logging"`), `mim01`–`mim03` (`role = "metrics"`) and
`pg01`–`pg03` (`role = "postgres"`: Patroni, the database of Grafana, NetBox and dark-triage) are
created like the DNS VMs:
the NICs listed in the inventory, with addresses, user and keys set by
cloud-init. Their software is deployed by
[monitoring-config](../monitoring-config/README.md). services-config ignores
these roles, apart from their DNS names: like every VM they get `<vm>` (the NIC with the gateway)
and `<vm>.mgmt` records, generated from the inventory.

Network layout of every service VM (zone design, DT-090): one NIC in its zone VRF, a flat /16 with
the default route via the anycast gateway `10.Z.0.1` (lylat-app 1201: Grafana, NetBox, dark-triage;
lylat-obs 1401: mon, Loki, Mimir; lylat-data 1601: Postgres, Valkey; DNS stays on VLAN 8, now in
lylat-dns, plus 1301; the proxies keep VLAN 2, now lylat-edge, plus an upstream NIC in lylat-app), a NIC on
lylat-telemetry (VLAN 1501, 10.55.0.0/16: scrapes and Alloy's log
pushes) and, per HA group, a NIC on its HA L2VNI `ha_<svc>` (VLAN 10aa / VNI 50aa, `10.50.aa.0/24`:
keepalived adverts, gossip/memberlist, Kea HA, Postgres replication and etcd; see
[`l2vnis.auto.tfvars`](../../inventory/auto.tfvars/l2vnis.auto.tfvars)). Each VM has the same host
octet on every network, grouped by service: mon .30-.31, graf .32-.33, loki .34-.36, mim .37-.39,
pg .40-.42, triage .43-.44, netbox .45-.46, valkey .47-.49, proxy .50-.51; VIPs from .100 (one octet
per service, VRRP router id = that octet; DNS uses .53). VM IDs stay what they were when created, so
they don't always match the octet.

## Proxmox HA

Every service VM is an **HA resource** (`ha = { group = "<role>" }` in `inventory/auto.tfvars/vms.auto.tfvars`).
The app-level HA (keepalived VIPs, Patroni, Kea HA) moves the *service* to a surviving member within
seconds; Proxmox HA brings the *dead member* back on another node within a few minutes (fencing,
then a restart from Ceph RBD), so each pair/trio is redundant again without anyone touching it.

| What | Where | Effect |
|---|---|---|
| `proxmox_haresource` `vm:<id>` | `modules/proxmox/vm/ha.tf` | state `started`, 1 restart / 1 relocation, no home node |
| `proxmox_harule` `spread-<group>` (negative resource-affinity) | `ha.tf` | VMs of one group never share a node (no two Patroni members, both DNS servers, ... on one node) |
| `ignore_changes = [node_name]` (every VM of the module) | `modules/proxmox/vm/main.tf` | the inventory `node` only places a new VM; a VM running elsewhere is no plan diff |
| `migrate = true` for HA VMs | `modules/proxmox/vm/main.tf` | kept, in case `node_name` is ever planned to change |

Groups (`tofu output ha_groups`): dhcp, dns, grafana, logging, metrics, monitoring, netbox, postgres, proxy, ticketing, valkey.
`ha = {}` (no `group`) makes a VM a plain HA resource with no affinity rule.
A group needs 2..<cluster node count> VMs (7 today) for a rule: PVE drops a larger negative rule as
infeasible, so tofu doesn't create one either and the `ha_group_size` check warns at plan time.

Operating HA VMs:

- **Stopping one** for longer than a reboot: set `ha.state = "stopped"` and apply, or
  `ha-manager set vm:<id> --state stopped` (the next apply restores the inventory value).
  A plain `qm stop` becomes an HA request too.
- **Node maintenance**: `ha-manager crm-command node-maintenance enable <node>` moves its HA VMs away
  (respecting the spread rules). They stay where HA put them afterwards (no home node).
- **Moving a VM**: migrate it in Proxmox (or let HA). Changing `node` in the inventory no longer
  moves an existing VM: node_name is ignored after creation, for every VM built by this module.
- **Fencing**: every node that runs an HA resource arms its watchdog. A node that loses corosync
  quorum reboots itself before its VMs are restarted elsewhere.
- The WLC pair (vm:20901/20902) and the HA containers/VMs outside this repo (ct:660, ct:666, ct:7001,
  vm:2802, vm:20101) keep their hand-made HA config.

## Good to know

- **Keep static addresses out of the DHCP pools.** Today's pools are
  `10.<VLAN>.5.1`–`10.<VLAN>.5.99` (see `vnis.auto.tfvars`). A VM with a static
  address inside a pool can collide with a lease the DHCP servers hand out.
- **Only NICs with an `ipv4_address` get cloud-init address config.** Others
  are attached but left unconfigured.
- **VLAN tagging is done by Proxmox.** The guest sees ordinary, untagged NICs.
  The bridge just has to carry the VLAN (`vmbr4000` is VLAN-aware on every
  node).
- **Cloud-init DNS** ([`dns.tf`](dns.tf)): every Debian VM here gets `nameserver 10.8.53.53` (the DNS VIP)
  and `search lylat.space` from cloud-init (`vm_dns`). Without it, Proxmox copies the host's resolv.conf
  (1.1.1.1), so lylat.space names don't resolve. The VyOS DHCP VMs are left out (`vm_dns_vyos = false`). Other
  roots see no change: the module renders `initialization.dns` only when `dns_servers`/`dns_domain` is set.
- **SSH keys are selected by name** from
  [`ssh_pubkeys.tf`](../../inventory/ssh_pubkeys.tf). An unknown name fails the
  plan. Keys can't be combined with a custom cloud-init user-data snippet.
- **Cloud-init runs at first boot only**, per instance. Proxmox derives the
  instance ID from the cloud-init user and network data (hostname = VM name,
  addresses, keys), and rebuilds the cloud-init drive on the next start *from
  Proxmox* (`qm start`/`qm reboot`, not a reboot inside the guest). After a rename,
  or a NIC/address/key change, that start makes cloud-init treat the VM as a new
  instance: it applies the new hostname/network/keys and **regenerates the SSH host
  keys** (run `ssh-keygen -R <ip>` afterwards). The provider itself reboots the VM
  when `initialization` changes; a rename alone doesn't reboot.

## Running it

```sh
tooling/walk-roots.sh services-vms services-config
```

The `vms` output lists each VM's ID, node, name and management address.
