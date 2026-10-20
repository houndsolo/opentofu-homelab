# Example inventory

These are standalone, commented examples using the current variable names.
They are not auto-loaded by the real roots and are not a complete replacement
for your working inventory.

| File in auto.tfvars/ | Shows |
| --- | --- |
| nodes.auto.tfvars | Cluster/standalone hosts and stable IDs |
| fabric-vms.auto.tfvars | Fabric VM names, OOB addresses and bridge order |
| vm-config.auto.tfvars | Shared VM defaults and existing image/snippet paths |
| vms.auto.tfvars | Two DNS VMs, a DHCP HA pair and an optional workload |
| vnis.auto.tfvars | Two L3VNIs with reciprocal DVNI imports, DHCP pools and static VLANs |
| dns-records.auto.tfvars | A/AAAA, CNAME, MX, TXT, SRV, NS and multiple A values |
| passwords.example.auto.tfvars | Placeholder credentials; use the ignored secrets path |

Read an example, then merge the entries you want into the matching
`inventory/auto.tfvars/` file. Change host names, storage IDs, images, IPs and
route targets to match your lab. Do not copy the whole directory into a root:
roots already link to their inventory, and extra files can override whole maps
or lists. OpenTofu does not merge a `vms` map across tfvars files.

The VM example selects `laptop` and `desktop`. Define those in
`inventory/ssh_pubkeys.tf` first:

```hcl
locals {
  ssh_pubkeys = {
    laptop  = "ssh-ed25519 REPLACE_WITH_LAPTOP_PUBLIC_KEY"
    desktop = "ssh-ed25519 REPLACE_WITH_DESKTOP_PUBLIC_KEY"
  }
}
```

`.tfvars` contain literal values; reference keys by name, not `local.*` or `var.*`.
VyOS uses its existing bootstrap snippet for API access. The HA example includes
VLAN 6 because `services-config` currently peers on `10.6.67.0/24`.

Review plans with `tooling/walk-roots.sh`. See [inventory](../inventory/README.md)
for shared secrets and [roots](../roots/README.md) for deployment order.
