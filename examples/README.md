# Examples

Commented, self-contained example values, one file for each inventory file. They
show every field name with typical values, using a simpler addressing plan than
the live lab:

- route-targets in AS 65000
- two cluster nodes, `fichina` and `macbeth`
- a `services` VRF and a `lan` VRF

**Nothing loads these files.** No root links to this folder, so editing them
changes nothing. Use them as a reference when you edit the real files in
[`inventory/auto.tfvars/`](../inventory/README.md).

| Example (in `auto.tfvars/`) | What it shows | Merge it into |
| --- | --- | --- |
| `nodes.auto.tfvars` | The host map: IDs, the management prefix, the cluster API host, and one `standalone` host | `nodes.auto.tfvars` |
| `fabric-vms.auto.tfvars` | Leaf VM naming and bridge order (their addresses come from `fabric.settings`) | `fabric-vms.auto.tfvars` |
| `vm-config.auto.tfvars` | Shared VM defaults and named images | `vm-config.auto.tfvars` |
| `vms.auto.tfvars` | Two DNS VMs and a DHCP HA pair (`owner = "services-vms"` with a `role`), and an ordinary workload VM | `vms.auto.tfvars` |
| `vnis.auto.tfvars` | Two VRFs with reciprocal [DVNI](../README.md#downstream-vni-dvni) imports. Also a DHCP pool, a NIC-only DHCP VLAN, and a VLAN without DHCP. | `vnis.auto.tfvars` |
| `dns-records.auto.tfvars` | A/AAAA, CNAME, MX, TXT, SRV and NS records, plus several A values for one name | `dns-records.auto.tfvars` |
| `passwords.example.auto.tfvars` | Every credential variable, with placeholder values, in one file | Your per-provider files in `inventory/auto.tfvars.secret/`, or one `passwords.secret.auto.tfvars` (never this file) |

`services-vms.tfvars` is a leftover note from an older layout. Nothing uses it.

## How to use them

1. **Read** the example for the thing you want to add.
2. **Copy the entries you need** into the matching file in `inventory/auto.tfvars/`.
3. **Adapt them to your lab:** host names, IDs, storage IDs, image paths, IP
   addresses and route-targets.
4. **Preview the result** with `tooling/walk-roots.sh` (choose `p` for plan).

> **Don't copy whole example files** into `inventory/auto.tfvars/` or into a root.
> OpenTofu doesn't merge a variable across tfvars files. If two files both set
> `vms`, the one loaded last replaces the entire map. Every VM missing from it
> drops out of the configuration, and the plan offers to **destroy** those VMs.

## Things the examples assume

- **Both SSH key names must exist.** The VM examples select the keys `laptop`
  and `desktop`. The real
  [`inventory/ssh_pubkeys.tf`](../inventory/ssh_pubkeys.tf) only defines
  `desktop` (`laptop` is commented out). Either define both, or change the
  lists; otherwise `plan` fails.

  ```hcl
  locals {
    ssh_pubkeys = {
      laptop  = "ssh-ed25519 AAAA...REPLACE_WITH_LAPTOP_PUBLIC_KEY laptop"
      desktop = "ssh-ed25519 AAAA...REPLACE_WITH_DESKTOP_PUBLIC_KEY desktop"
    }
  }
  ```

- **tfvars files hold literal values only.** Refer to keys and images by name,
  as in `ssh_pubkeys = ["laptop"]` or `image = "debian13"`. You can't use
  `local.` or `var.` references in a tfvars file.
- **The DHCP pair needs `l2vnis.ha_dhcp`.** `services-config` and `services-vms`
  peer the DHCP pair over that standalone L2VNI (see `l2vnis.auto.tfvars`): the
  DHCP VMs get one extra NIC on it, after the data NICs, with hosts `.1` and `.2`
  of its `prefix`.
- **The DVNI pair needs an `external_l2` leaf.** The `lan` VRF uses the
  `external_l2` role, so add a leaf with that role in `fabric.auto.tfvars` if you
  want it to actually appear on a device.
- **The VyOS image needs your own snippet.** The image entry expects your own
  cloud-init snippet (`vyos_api.yml`) that enables the VyOS API.
- **A `dns_hosts` entry replaces a generated name entirely.** As the DNS
  example's comment says, if you use a generated name such as `greatfox`, list
  every type you want it to keep (for example, its A record as well as a new
  AAAA). Otherwise, add to it with `dns_records`. See
  [services-config](../roots/services-config/README.md#when-your-names-match-generated-ones).
- **Real credentials never go in the examples.** The passwords example shows
  every variable in one file, which is the format the single-file `with-secrets`
  setup uses. The lab splits the same variables into per-provider files in
  `inventory/auto.tfvars.secret/`; see
  [Secrets](../inventory/README.md#secrets). Git ignores both of those. The
  example file **is** tracked by Git, so never put real values in it.
- **Some values differ from the live lab on purpose.** For example, the gateways
  here are `.0.1` (the lab uses `.0.5`), and the route-targets use AS 65000. Use
  whatever fits your network.
