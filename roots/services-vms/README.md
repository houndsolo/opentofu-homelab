# services-vms

Builds the service VMs (hardware, disks, NICs, cloud-init, Proxmox HA): every
[`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars) entry with
`owner = "services-vms"`, through the shared [VM module](../../modules/README.md#proxmoxvm). The
software comes from [services-config](../services-config/README.md) (DNS, DHCP, NetBox, Valkey,
dark-triage, proxy) and [monitoring-config](../monitoring-config/README.md) (monitoring, Grafana,
Loki, Mimir, Postgres). `role` is one of `dns`, `dhcp`, `monitoring`, `grafana`, `logging`,
`metrics`, `postgres`, `ticketing`, `netbox`, `valkey`, `proxy`, or unset.

## The VMs

VLAN = tag on `vmbr4000` unless a bridge is named. Zone VLANs: 1201 lylat-app, 1301 lylat-dns, 1401
lylat-obs, 1601 lylat-data, 1501 lylat-telemetry; 10aa = the service's HA segment.

| VM | Role | Node | VM ID | Image | Management (eth0) | Data NICs |
| --- | --- | --- | --- | --- | --- | --- |
| `dns01` | `dns` | venom | 5301 | `debian13` | `10.20.53.1/16` | eth1: VLAN 8 `10.8.53.1/16`, gateway `10.8.0.1`; eth2: VLAN 1301 `10.53.53.51/16`; eth3: VLAN 1053 `10.50.53.51/24`; eth4: VLAN 1501 `10.55.53.51/16` |
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
| `proxy01`, `proxy02` | `proxy` | macbeth, fichina | 1150, 1151 | `debian13` | `10.20.11.50`, `.51/16` | eth1: VLAN 2 `10.2.11.50`/`.51/16`, gateway `10.2.0.1`; eth2: VLAN 1201 `10.52.10.50`/`.51/16`; eth3: VLAN 1010 `10.50.10.50`/`.51/24`; eth4: VLAN 1501 `10.55.10.50`/`.51/16` |

Sizes (`config`): 2 cores everywhere except Valkey (1 core, 1024 MB) and mon/Loki/Mimir (4 cores,
8192 MB); memory 2048 MB (DHCP, proxy, triage), 3072 (DNS), 4096 (Grafana, NetBox, Postgres);
disks 200 GB mon, 60 GB Loki/Mimir, 40 GB Postgres, 20 GB NetBox, otherwise the 10 GB default.

Layout rules (zone design DT-090):

- One NIC in the zone VRF, flat /16, default route via the anycast gateway `10.Z.0.1`; no
  management gateway. DNS keeps VLAN 8 (now lylat-dns) as its service NIC plus 1301; the proxies
  keep VLAN 2 (lylat-edge) plus an upstream NIC in lylat-app.
- A lylat-telemetry NIC (VLAN 1501, 10.55.0.0/16): scrapes and Alloy's log pushes.
- Per HA group a NIC on its L2VNI `ha_<svc>` (VLAN 10aa / VNI 50aa, `10.50.aa.0/24`, see
  [`l2vnis.auto.tfvars`](../../inventory/auto.tfvars/l2vnis.auto.tfvars)): keepalived, gossip,
  Kea HA, Postgres replication, etcd.
- Static IPv6 on zone and telemetry NICs `fd69:<VNI>::<aa>:<host>/64` (graf01 `fd69:5201::11:32`), on
  HA NICs `fd69:50aa::<host>/64` (keepalived VRRPv3 adverts).
- Same host octet on every network: mon .30-.31, graf .32-.33, loki .34-.36, mim .37-.39, pg .40-.42,
  triage .43-.44, netbox .45-.46, valkey .47-.49, proxy .50-.51; VIPs from .100, one octet per
  service = its VRID (DNS .53). VM IDs don't always match the octet.

## DNS VMs

services-config needs exactly one NIC with `ipv4_address` + `ipv4_gateway` (the BIND service
address, VLAN 8; validated), Podman with Quadlet and qemu-guest-agent in the image (the stock Debian
image has neither, see
[proxmox-download-files](../proxmox-download-files/README.md#this-is-the-stock-image)), and
internet through VLAN 8 to pull the BIND image.

## DHCP VMs

Their data NICs are generated (any `network_devices` you write is replaced) by
[modules/services/dhcp/macs](../../modules/services/dhcp/macs/README.md): one NIC per VLAN with a
`dhcp` block in `vnis.auto.tfvars`, sorted by VLAN, on `vmbr4000`, MAC
`02:00:00:67:<VM ID % 100>:<VLAN>`, then the Kea HA NIC last. Today on dhcp01 (dhcp02: `:02:`):

| eth1 | eth2 | eth3 | eth4 | eth5 | eth6 |
| --- | --- | --- | --- | --- | --- |
| VLAN 2 `…:01:02` | 8 `…:01:08` | 9 `…:01:09` | 10 `…:01:10` | 12 `…:01:12` | 1009 `ha_dhcp` `…:01:ff` |

VLAN 11 has no `dhcp` block, so no NIC. Cloud-init configures only eth0; services-config sets the
VLAN addresses (`10.<VLAN>.67.<1|2>`) over the VyOS API. Checked: two DHCP VMs or none, VM IDs
6701–6799 and unique, DHCP VLANs 1–99. **Adding or removing a DHCP VLAN renumbers the `ethN` above
it** (MACs stay): plan services-vms and services-config together, apply one after the other.

## Proxmox HA

Every service VM is an HA resource (`ha = { group = "<role>" }`): app-level HA (keepalived, Patroni,
Kea HA, Sentinel) moves the service in seconds, Proxmox HA restarts the dead member on another node
within minutes (fencing, then a restart from Ceph RBD).

| What | Where | Effect |
|---|---|---|
| `proxmox_haresource` `vm:<id>` | `modules/proxmox/vm/ha.tf` | state `started`, 1 restart / 1 relocation, no home node |
| `proxmox_harule` `spread-<group>` (negative resource-affinity) | `ha.tf` | VMs of one group never share a node |
| `ignore_changes = [node_name]` | `modules/proxmox/vm/main.tf` | inventory `node` only places a new VM; a VM elsewhere is no diff, and changing `node` doesn't move it |
| `migrate = true` for HA VMs | `modules/proxmox/vm/main.tf` | migrate instead of replace if `node_name` ever changes |

Groups (`tofu output ha_groups`): dhcp, dns, grafana, logging, metrics, monitoring, netbox, postgres,
proxy, ticketing, valkey. `ha = {}` = HA without a rule. A rule needs 2..<cluster nodes> VMs (7
today); larger groups get none (PVE drops them as infeasible) and the `ha_group_size` check warns.

- Stop one for longer than a reboot: `ha.state = "stopped"` + apply, or
  `ha-manager set vm:<id> --state stopped` (the next apply restores the inventory value). A plain
  `qm stop` becomes an HA request too.
- Node maintenance: `ha-manager crm-command node-maintenance enable <node>`; VMs stay where HA put
  them afterwards.
- Fencing: a node running HA resources that loses quorum reboots itself before its VMs restart
  elsewhere.
- Never reboot both VMs of a `use_vmac` keepalived pair (DNS, proxy, ...) at once: EVPN
  duplicate-address detection freezes the VMAC.
- HA resources outside this repo (WLC pair vm:20901/20902, ct:660, ct:666, ct:7001, vm:20101, ...)
  keep their hand-made config.

## Cloud-init

- Debian VMs get `nameserver 10.8.53.53` (DNS VIP) and `search lylat.space` (`vm_dns` in
  [`dns.tf`](dns.tf)); without it Proxmox copies the host's resolv.conf (1.1.1.1). The VyOS DHCP VMs
  are left out (`vm_dns_vyos = false`: a new cloud-init instance would re-apply their user-data on
  the live pair).
- SSH keys are picked by name from [`ssh_pubkeys.tf`](../../inventory/ssh_pubkeys.tf) (unknown name
  fails the plan; not combinable with a custom user-data snippet). Only NICs with an address get
  cloud-init config.
- Proxmox derives the instance ID from the cloud-init data. Any `initialization` change (address,
  gateway, DNS, keys, NIC) makes the provider rebuild the drive and reboot the VM; cloud-init then
  runs as a new instance and **regenerates the SSH host keys** (`ssh-keygen -R <ip>`). A rename alone
  takes effect at the next start from Proxmox. Roll such changes one VM per HA pair at a time.

## Running it

```sh
tooling/walk-roots.sh services-vms services-config
```

Output `vms`: ID, node, name and management address per VM. Keep static addresses out of the DHCP
pools (`10.<VLAN>.5.1`–`.5.99`).
