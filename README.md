# OpenTofu homelab starter

A small starting point for writing your own homelab project.
There are no infrastructure resources yet. Plans show example outputs only.

| Directory | Purpose |
| --- | --- |
| inventory/auto.tfvars/ | Shared example values; edit these files |
| inventory/schema/ | HCL variable types and validation |
| examples/auto.tfvars/ | Links to the example inventory values |
| roots/proxmox/ | Host networking and platform configuration |
| roots/fabric-vms/ | Fabric VM lifecycle |
| roots/fabric-leaves/ | VyOS leaf configuration |
| roots/fabric-spines/ | RouterOS spine configuration |
| roots/network-services/ | Service VM lifecycle |
| roots/workloads/ | Other VM lifecycle |
| modules/proxmox/vm/ | One VM specification example |
| modules/fabric/leaf/ | One leaf specification example |
| providers/ | Future provider source submodules |
| tooling/ | Validation helper |
| docs/ | Suggested implementation steps |

```bash
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan
bash tooling/validate
```

Run each root separately. Each has independent local state in its directory.
The top level is not a deployment root. Relative symlinks load only the data
and declarations that each root uses. Do not replace those links with copies.
Required OpenTofu version is a compatibility floor, not a release pin.
Use your installed current stable OpenTofu release.
