# services-vms

This root creates the **DNS and DHCP VMs**. It only builds the VMs (hardware,
disks, NICs, cloud-init). The software inside them is set up afterwards by
[services-config](../services-config/README.md).

## Which VMs

Every entry in [`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars)
with `owner = "services-vms"`. Its `role` says what kind of service VM it is:
`dns`, `dhcp`, `monitoring`, `grafana`, `logging`, `metrics`, or no role at all for any other service
VM. All of them are built with the shared
[VM module](../../modules/README.md#proxmoxvm). Today that's:

| VM | Role | Node | VM ID | Image | Management (eth0) | Data NICs |
| --- | --- | --- | --- | --- | --- | --- |
| `dns01` | `dns` | venom | 5301 | `debian13` | `10.20.53.1/16` | eth1: `vmbr4000` VLAN 8, `10.8.53.1/16`, gateway `10.8.0.5` |
| `dns02` | `dns` | eldarad | 5302 | `debian13` | `10.20.53.2/16` | eth1: `vmbr4000` VLAN 8, `10.8.53.2/16`, gateway `10.8.0.5` |
| `dhcp01` | `dhcp` | venom | 6701 | `vyos` | `10.20.67.1/16` | generated (see below) |
| `dhcp02` | `dhcp` | eldarad | 6702 | `vyos` | `10.20.67.2/16` | generated |
| `mon01` | `monitoring` | zoness | 1130 | `debian13` | `10.20.11.30/16` | eth1: `vmbr4000` VLAN 2, `10.2.11.30/16`, gateway `10.2.0.5`; eth2: `vmbr100` (untagged), `10.5.11.30/16`; eth3: `vmbr4000` VLAN 13, `10.13.11.30/16`; eth4: `vmbr4000` VLAN 215, `10.21.13.30/24` |
| `mon02` | `monitoring` | macbeth | 1136 | `debian13` | `10.20.11.31/16` | same as `mon01` with `.31` |
| `graf01` | `grafana` | venom | 1131 | `debian13` | `10.20.11.32/16` | eth1: `vmbr4000` VLAN 2, `10.2.11.32/16`, gateway `10.2.0.5`; eth2: `vmbr4000` VLAN 13, `10.13.11.32/16`; eth3: VLAN 213 `10.21.11.32/24` |
| `graf02` | `grafana` | eldarad | 1132 | `debian13` | `10.20.11.33/16` | eth1: `vmbr4000` VLAN 2, `10.2.11.33/16`, gateway `10.2.0.5`; eth2: `vmbr4000` VLAN 13, `10.13.11.33/16`; eth3: VLAN 213 `10.21.11.33/24` |
| `loki01`–`loki03` | `logging` | zoness, titania, fortuna | 1133–1135 | `debian13` | `10.20.11.34`–`.36/16` | eth1: VLAN 2 `10.2.11.34`–`.36/16`, gateway `10.2.0.5`; eth2: VLAN 13 `10.13.11.34`–`.36/16`; eth3: `vmbr100` `10.5.11.34`–`.36/16`; eth4: `vmbr27` (Ceph public) `10.27.11.34`–`.36/16`; eth5: VLAN 214 `10.21.12.34`–`.36/24` |
| `mim01`–`mim03` | `metrics` | fichina, venom, eldarad | 1137–1139 | `debian13` | `10.20.11.37`–`.39/16` | eth1: VLAN 2 `10.2.11.37`–`.39/16`, gateway `10.2.0.5`; eth2: VLAN 13 `10.13.11.37`–`.39/16`; eth3: `vmbr27` (Ceph public) `10.27.11.37`–`.39/16`; eth4: VLAN 216 `10.21.14.37`–`.39/24` |

Sizes are set in each VM's `config`: 2 cores and 2048 MB for the DNS, DHCP and
Grafana VMs (Grafana 4096 MB), 4 cores, 8192 MB and a 200 GB disk for `mon01`/`mon02`, and
4 cores, 8192 MB and a 60 GB disk for the Loki and Mimir VMs. Each pair is
split across two hosts, so losing one host doesn't take out DNS, DHCP or
Grafana.

## DNS VMs

- **NICs.** They get exactly the NICs listed in the inventory: the management
  NIC (net0 on `vmbr0`) plus `network_devices`.
- **Cloud-init** sets both addresses at first boot. It also creates
  `config.ssh_username` with the keys selected in `config.ssh_pubkeys`.
- **Routing.** There's no management gateway, so the data NIC's gateway
  (`10.8.0.5`, the anycast gateway on the local leaf) is the VM's only default
  route.

Before `services-config` can set them up, the DNS VMs also need:

- **Exactly one NIC with an `ipv4_address`.** That address becomes the DNS
  service address, and `plan` fails if there are none or several. Today it's the
  VLAN 8 NIC on `vmbr4000`.
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
| eth2 | 6 | `02:00:00:67:01:06` |
| eth3 | 8 | `02:00:00:67:01:08` |
| eth4 | 9 | `02:00:00:67:01:09` |
| eth5 | 10 | `02:00:00:67:01:10` |
| eth6 | 12 | `02:00:00:67:01:12` |

VLAN 11 has no `dhcp` block, so it gets no NIC.

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

## Monitoring, Grafana, Loki and Mimir VMs

`mon01`/`mon02` (`role = "monitoring"`, sized for Prometheus; Grafana's
Postgres runs on `mon01` only), `graf01`/`graf02` (`role = "grafana"`),
`loki01`–`loki03` (`role = "logging"`), `mim01`–`mim03` (`role = "metrics"`) and
`pg01`–`pg03` (`role = "postgres"`: Patroni, Grafana's HA database replacing mon01's) are
created like the DNS VMs:
the NICs listed in the inventory, with addresses, user and keys set by
cloud-init. Their software is deployed by
[monitoring-config](../monitoring-config/README.md). services-config ignores
these roles, apart from their DNS names: like every VM they get `<vm>` (VLAN 2)
and `<vm>.mgmt` records, generated from the inventory. All of them have a NIC on
VLAN 13 (`10.13.0.0/16`, the isolated `lylat_monitor` VRF): Grafana reaches the
datasources (Prometheus, Alertmanager, Loki, Mimir) and Postgres over it. Each HA
group has its own HA L2VNI for keepalived and gossip/memberlist: `ha_grafana`
(213), `ha_logging` (214), `ha_monitor` (215), `ha_mimir` (216), `ha_postgres` (217:
also Postgres replication and etcd). Each VM has the same last octet on every network, grouped by
service: mon .30-.31, graf .32-.33, loki .34-.36, mim .37-.39, pg .40-.42; VIPs from .100
(one octet per service, VRRP router id = that octet). VM IDs stay what they were when
created (1130-1142), so since the re-addressing they no longer match the octet.

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

Groups (`tofu output ha_groups`): dhcp, dns, grafana, logging, metrics, monitoring, postgres, ticketing.
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
