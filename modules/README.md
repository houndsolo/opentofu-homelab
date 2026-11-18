# Modules

Shared logic called by the roots. No state of their own; run `tofu` from a
[root](../roots/README.md) (except [tests](#tests)).

## Catalog

| Module | Called by | Creates | Provider |
| --- | --- | --- | --- |
| [proxmox/network](#proxmoxnetwork) | proxmox-network | NIC settings, bonds, bridges, VLANs on one node | proxmox |
| [proxmox/vm](#proxmoxvm) | fabric-vms, services-vms, workloads | One VM (+ HA resource) | proxmox |
| [fabric/leaf](#fabricleaf) | fabric-leaves | One VyOS command list per leaf | vyoscmd |
| [fabric/spines](#fabricspines) | fabric-spines | Loopback, leaf ports, BGP (underlay + EVPN), BFD, NTP, logging on one RouterOS spine | routeros |
| [fabric/leaves](#fabricleaves) | fabric-spines, fabric-leaves, services-config, monitoring-config | Nothing: the shared leaf list | none |
| [fabric/macs](fabric/macs/README.md) | fabric-vms, fabric-leaves | Nothing: leaf VM MAC calculator | none |
| [services/dhcp](#servicesdhcp) | services-config | One VyOS command list per DHCP VM | vyoscmd |
| [services/dhcp/macs](services/dhcp/macs/README.md) | services-vms, services-config | Nothing: DHCP VM NIC/MAC calculator | none |
| [services/monitoring](services/monitoring/README.md) | monitoring-config | Nothing: renders one `deploy.sh` per monitoring, Grafana, logging, Mimir and Patroni VM | none |

## Patterns

1. **Shared declarations.** Modules symlink their input declarations from `inventory/schema/`
   (e.g. `fabric/leaf/vnis.variables.tf` → `inventory/schema/vnis.tf`) and their `versions.tf`
   from `inventory/versions/`: one copy of types and validation, no drift.
2. **VyOS config as command lists.** Each topic file (`bgp.tf`, `vxlan.tf`, ...) builds a list of
   `set` commands in `locals`; `main.tf` joins them into **one `vyoscmd_commands` resource per
   device**: one API call per device, and the plan shows the exact CLI sent.
3. **Calculators.** `fabric/leaves` and the two `macs` modules have only `locals` and outputs.
   They're called by every root that needs the same result (the root that creates VMs and the one
   that configures them; spines, leaves and DNS records), so all sides agree.

## Module details

### proxmox/network

One node's networking from the `pve_network` profile.

- **Inputs:** `node_name`, `node_id`, `pve_network`.
- **Creates:** `proxmox_network_linux_eth`, `_bond`, `_bridge`, `_vlan`, one per map entry
  (`.this["<key>"]`). Addresses: `cidrhost(ipv4.cidrhost_prefix, node_id)/ipv4.cidr`.
- **Order:** bonds and bridges wait for the NICs; VLANs wait for bridges and bonds.

Per-node result: [roots/proxmox-network](../roots/proxmox-network/README.md).

### proxmox/vm

One VM from a cloud image.

- **Inputs:** `name`, `vm` (a `vms` entry or a generated fabric VM), `vm_config`, `vm_images`,
  `ssh_pubkeys` (key registry), `configure_data_ips` (default `true`), `vendor_data_file_id`
  (optional; unused today).
- **Creates:** `proxmox_virtual_environment_vm`, plus `proxmox_haresource` when `vm.ha` is set
  (`ha.tf`).
- **Outputs:** `vm_id`, `node_name`, `name`, `management_address` (null when cloud-init is off),
  `network_devices`, `ha_resource_id` (null without `vm.ha`).

`main.tf`:

- **Settings**: the `defaults/` calculator submodule merges `vm_config`, the image and the VM's
  `config` (later wins); output `config`, tested in `defaults/tests/`.
- **Disk**: imported from `import_image` into `datastore_id` on `virtio0` (10 GB default).
- **Cloud-init** (if enabled) on `scsi0`: net0 address/gateway; each data NIC with an
  `ipv4_address`/`ipv6_address` if `configure_data_ips`; a user with the selected keys if
  `config.ssh_pubkeys` is set; optional `user_data_file_id`. `upgrade = false`.
- **NICs**: net0 on `management_bridge`, then `network_devices` in order. Data NIC MTU defaults to
  `1` (= bridge MTU).
- **Extras**: serial console (default on), OS type `l26`, std VGA.
- **Check**: `ssh_pubkeys` needs cloud-init and can't be combined with a custom user-data snippet
  (Proxmox would ignore the generated keys).

### fabric/leaf

One leaf's full VyOS configuration.

- **Inputs:** `name`, `leaf` (`role`, `id`, `access_interface`, `standalone`), `fabric`, `vnis`,
  `l2vnis`, `fabric_macs`, `router_advert_routes` (default `["fd69::/16"]`).
- **Creates:** one `vyoscmd_commands` named `<name>-system` at `https://<management IP>`,
  `save = true` (survives a reboot). Precondition: `l2vnis` don't reuse a VNI/VLAN from `vnis`.

| File | Builds |
| --- | --- |
| `addressing.tf` | Router-ID, VTEP IPv6 and VTEP MAC from the leaf ID |
| `vnis.tf` | Which VRFs/VLANs this leaf gets, by role |
| `interface.tf` | `hw-id` bindings, spine links, loopback, access port |
| `bgp.tf` | Global BGP (`log-neighbor-changes`), EVPN, neighbors, peer groups `spine_underlay`/`spine_overlay` |
| `vxlan.tf` | `vxlan0`, `br0`, VLAN-to-VNI mappings, anycast gateways (IPv4; IPv6 + RAs where set), standalone HA L2VNIs |
| `vrf.tf` | VRF tables/VNIs, per-VRF BGP (IPv4 and IPv6), route-targets |
| `policy.tf` | Prefix lists and route-maps (default-route deny, no type-5 for own L2VNI subnets to the spines) |
| `system.tf` | Hostname `LEAF-<ID>`, domain, multipath, NTP |
| `monitoring.tf` | node-/frr-exporter when `fabric.settings.leaf_prometheus_exporters` is set |
| `logging.tf` | Remote syslog when `fabric.settings.leaf_syslog` is set |
| `external.tf` | `external_l3` leaves: VLAN sub-interface + unnumbered BGP to the external router for VRFs with `ext_l3_peer` |
| `main.tf` | The one resource |

A role with no VRFs gets only the `hw-id` bindings, system settings, exporters and syslog.

**NTP**: one `set service ntp server` per `ntp_servers` entry. With a non-empty list it also
deletes VyOS's default servers not in the list and sets the client VRF from `leaf_ntp_vrf`. An
empty list skips NTP (doesn't remove anything). Leaves send no RAs on spine links; they peer on the
spines' RAs. Generated commands: [roots/fabric-leaves](../roots/fabric-leaves/README.md).

### fabric/spines

One RouterOS spine: one eBGP session per leaf carrying the underlay (ipv6) and EVPN.

- **Inputs:** `spine` (`management_ip`, `id`, `uplink_interface`, optional `as`), `fabric`,
  `leaves` (map of `id`, `spine_uplink`; unique IDs: one connection per leaf), `keepalive_time`
  (`"1m"`) and `hold_time` (`"3m"`) on the template and every connection (keep keepalive <= hold/3),
  `port_mtu` (10000), `port_l2mtu` (10218), `switch_name` (`switch1`).
- **Creates** (see [roots/fabric-spines](../roots/fabric-spines/README.md)):
  - `loopback.tf`: routing id, `lo` addresses (IPv4 router id, IPv6 loopback), `FABRIC-LOOPBACK` list
  - `ports.tf`: leaf-port MTU, RAs + `none` ND prefix per port, the disabled `interface=all` ND entry
    and `switch1` L3 offload (both imported by the root), BFD on the leaf ports
  - `bgp.tf`: instance `fabric`, input chain `LEAF-IN`, template `LEAF`, connection `leaf-<ID>` per
    leaf (remote AS `underlay_as_base + ID`)
  - `system.tf`: NTP client (when `ntp_servers` is non-empty); built-in `memory` logging action,
    10,000 lines
  - `syslog.tf`: built-in `remote` action to `spine_syslog.host` (UDP, BSD syslog) + one rule per
    topic (when `spine_syslog` is set)

AS: `underlay_as_base + ID` (m326-1 701, m326-2 702).

### fabric/leaves

- **Inputs:** `fabric`, `nodes`.
- **Output:** `leaves` = `fabric.leaves` (physical, `standalone = false`) merged with one generated
  leaf per `nodes.proxmox` host: `{ role = "proxmox", standalone = <node flag>, id = <node ID>,
  access_interface = "eth<spines + 1>", spine_uplink = null }`.
- **Used for:** spine sessions per leaf, leaf config, `leaf-<ID>` DNS records, scrape targets.

### fabric/macs

Fixed MACs for the leaf VMs' data NICs: [README](fabric/macs/README.md).

### services/dhcp

One DHCP VM's VyOS configuration.

- **Inputs:** `name`, `management_ip`, `interface_macs` (ethN → MAC), `interface_addresses`
  (ethN → CIDR; `eth1`+ only, `eth0` untouchable), `ha` (role, slots, peer), `ha_prefix`,
  `ha_interface`, `vnis`, `default_name_servers`, `default_domain` (`lylat.space`),
  `prometheus_exporters`, `syslog` (optional).
- **Creates:** one `vyoscmd_commands` named `<name>-dhcp`, `save = true`. **Output:** `commands`
  (for tests).

| File | Builds |
| --- | --- |
| `interfaces.tf` | `hw-id` bindings, data interface addresses |
| `dhcp-commands.tf` | HA settings, listen interfaces, one pool per VLAN with `dhcp.scope` |
| `main.tf` | Hostname, `disable-forwarding`, the combined resource |
| `monitoring.tf` | node-/frr-exporter when `prometheus_exporters` is set |
| `logging.tf` | Remote syslog (same commands as the leaves) when `syslog` is set |

### services/dhcp/macs

DHCP VM NICs and fixed MACs: [README](services/dhcp/macs/README.md).

## Tests

| Test file | Needs locally built providers? |
| --- | --- |
| `fabric/macs/tests/macs.tftest.hcl` | no |
| `services/dhcp/macs/tests/macs.tftest.hcl` | no |
| `proxmox/vm/defaults/tests/defaults.tftest.hcl` | no |
| `proxmox/vm/tests/vm.tftest.hcl` | `proxmox` (mocked) |
| `services/dhcp/tests/commands.tftest.hcl` | `vyoscmd` (mocked) |
| `roots/services-config/tests/dns.tftest.hcl` | `vyoscmd` + registry `dns`, `random` (mocked) |
| `roots/monitoring-config/tests/{monitoring,metrics,postgres,rgw}.tftest.hcl` | `proxmox` + registry `random` (mocked) |
| `roots/services-vms/tests/ha.tftest.hcl` | `proxmox` (mocked) |
| `roots/proxmox-settings/tests/settings.tftest.hcl` | `proxmox` (mocked) |

Mocked providers contact nothing, but `tofu init` must still install them: run
`tooling/build-all` and set `TF_CLI_CONFIG_FILE` first ([tooling](../tooling/README.md)).

```sh
tofu -chdir=modules/fabric/macs init    # creates a git-ignored .terraform/ in the module
tofu -chdir=modules/fabric/macs test
```
