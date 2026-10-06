# OpenTofu roots

Each root has separate local state and loads shared inventory through symlinks.
Run the commands below from the repository directory, after [provider setup](../providers/README.md).

| Root | Current purpose and status |
| --- | --- |
| [proxmox-network](proxmox-network/README.md) | Ethernet interfaces, bonds, bridges and VLANs. |
| [fabric-vms](fabric-vms/README.md) | One VyOS VM per Proxmox inventory node. |
| [fabric-leaves](fabric-leaves/README.md) | VyOS interfaces, BGP, VXLAN, VRFs and policies. |
| fabric-spines | Placeholder: exposes spine inventory; no RouterOS resources. |
| proxmox-settings | Incomplete: metrics resource needs an `influxdb` variable and input wiring. |
| proxmox-virtual-hosts | Empty placeholder. |
| network-services | Selects VMs with owner `network-services`; required `vm_config` is not wired yet. |
| workloads | Selects VMs with owner `workloads`; required `vm_config` is not wired yet. |

Typical workflow for an implemented root:

```sh
tofu -chdir=roots/proxmox-network init
tofu -chdir=roots/proxmox-network validate
tofu -chdir=roots/proxmox-network plan
# After reviewing the plan:
tofu -chdir=roots/proxmox-network apply
```

For new fabric VMs, create the guests with `fabric-vms`, make their VyOS APIs
reachable, then configure them with `fabric-leaves`.
