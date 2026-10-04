# OpenTofu homelab starter


| Directory | Purpose |
| --- | --- |
| inventory/auto.tfvars/ | Shared example values; edit these files |
| inventory/schema/ | HCL variable types and validation |
| inventory/versions/ | Tofu provider versions |
| examples/auto.tfvars/ | Links to the example inventory values |
| roots/proxmox-network/ | Proxmox networking |
| roots/proxmox-settings/ | Proxmox settings |
| roots/proxmox-virtual-hosts/ | Proxmox VMs/LXCs |
| roots/fabric-vms/ | Fabric VM lifecycle |
| roots/fabric-leaves/ | VyOS leaf configuration |
| roots/fabric-spines/ | RouterOS spine configuration |
| roots/network-services/ | Service VM lifecycle |
| roots/workloads/ | Other VM lifecycle |
| modules/proxmox/network/ | Proxmox networking module - bridges, bonds, subinterfaces |
| modules/proxmox/vm/ | VM |
| modules/proxmox/lxc/ | LXC |
| modules/fabric/leaf/ | leaves |
| modules/fabric/spine/ | spines |
| providers/ | Provider source submodules |
| tooling/ | provider build scripts |
| docs/ | Suggested implementation steps |

```bash
tofu -chdir=roots/proxmox-network init
tofu -chdir=roots/proxmox-network validate
tofu -chdir=roots/proxmox-network plan
```

Run each root separately. Each has independent local state in its directory.
The top level is not a deployment root. Relative symlinks load only the data
and declarations that each root uses. Do not replace those links with copies.
Required OpenTofu version is a compatibility floor, not a release pin.
Use your installed current stable OpenTofu release.
