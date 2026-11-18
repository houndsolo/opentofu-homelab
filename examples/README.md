# Examples

Commented example values for most inventory files, with a simpler plan than the live lab
(route-targets in AS 65000, cluster nodes `fichina` and `macbeth` plus standalone `greatfox`, a
`services` and a `lan` VRF). **Nothing loads them**: no root links this folder. Reference only for
editing [`inventory/auto.tfvars/`](../inventory/README.md).

| Example (`auto.tfvars/`) | Shows |
| --- | --- |
| `nodes.auto.tfvars` | Host map: IDs, management prefix, cluster API host, one `standalone` host |
| `fabric-vms.auto.tfvars` | Leaf VM naming and bridge order |
| `vm-config.auto.tfvars` | Shared VM defaults and named images |
| `vms.auto.tfvars` | Two DNS VMs, a DHCP HA pair (`owner = "services-vms"` + `role`), a workload VM |
| `vnis.auto.tfvars` | Two VRFs with reciprocal [DVNI](../README.md#downstream-vni-dvni) imports, a DHCP pool, VLANs without DHCP |
| `l2vnis.auto.tfvars` | The DHCP pair's HA L2VNI (`ha_dhcp`) |
| `dns-records.auto.tfvars` | A/AAAA, CNAME, MX, TXT, SRV, NS, several A values for one name |
| `passwords.example.auto.tfvars` | Provider credentials (Proxmox, VyOS, RouterOS) as placeholders in one file: the single-file `with-secrets` format. Tracked by git: never put real values in it. Service secrets: [Secrets](../inventory/README.md#secrets). |

Copy the **entries** you need into the matching inventory file and adapt names, IDs, storage,
image paths, addresses and route-targets; preview with `tooling/walk-roots.sh` (`p`).

> **Don't copy whole files** into `inventory/auto.tfvars/` or a root. OpenTofu doesn't merge a
> variable across tfvars files: a second file setting `vms` replaces the whole map, and the plan
> offers to **destroy** every VM missing from it.

Assumptions:

- The VM examples select SSH keys `laptop` and `desktop`; the real
  [`inventory/ssh_pubkeys.tf`](../inventory/ssh_pubkeys.tf) only defines `desktop`. Define both or
  change the lists, or `plan` fails.
- tfvars hold literal values only: refer to keys and images by name (`ssh_pubkeys = ["laptop"]`,
  `image = "debian13"`), no `local.`/`var.`.
- The DHCP pair needs `l2vnis.ha_dhcp`: each DHCP VM gets one NIC on it after the data NICs, hosts
  `.1`/`.2` of its `prefix`.
- The `lan` VRF uses the `external_l2` role: it only lands on a device if `fabric.auto.tfvars` has
  a leaf with that role.
- The VyOS image entry expects your own `vyos_api.yml` cloud-init snippet.
- Generated DNS names (VMs, VIPs, hosts, leaves, spines) can get extra types in `dns_hosts` but
  can't be redefined
  ([services-config](../roots/services-config/README.md#when-your-names-match-generated-ones)).
- Some values differ from the lab on purpose: RTs in AS 65000 (lab: 700; set
  `fabric.settings.route_target_as` to the same number, it is the administrator part of the L2VNI
  route targets), HA segment VLAN 211 /
  VNI 9211 / `10.21.67.0/24` (lab: 1009 / 5009 / `10.50.9.0/24`).
