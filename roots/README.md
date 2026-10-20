# Roots

Each directory is a separate OpenTofu configuration with its own local state.
Run commands from the repository directory.

| Root | Purpose | Status |
| --- | --- | --- |
| proxmox-download-files | PVE cloud image downloads | Implemented; apply separately |
| proxmox-network | Host interfaces, bonds, bridges and VLANs | Implemented |
| fabric-vms | VyOS VM creation | Implemented |
| fabric-leaves | VyOS BGP, VXLAN, VRFs and policies | Implemented |
| fabric-spines | RouterOS spine configuration | Placeholder |
| proxmox-settings | Proxmox settings | Incomplete |
| proxmox-virtual-hosts | General VM/container configuration | Placeholder |
| services-vms | Service VM creation and cloud-init | Implemented; requires VM settings |
| services-config | Podman BIND9 deployment over SSH | Implemented |
| workloads | Other VMs | Incomplete |

## Examples

```sh
tofu -chdir=roots/proxmox-network init
tofu -chdir=roots/proxmox-network validate
tofu -chdir=roots/proxmox-network plan
```

```sh
tofu -chdir=roots/fabric-leaves init
tofu -chdir=roots/fabric-leaves plan
tofu -chdir=roots/fabric-leaves apply
```

For new fabric guests, create the VMs first. Enable and check their VyOS APIs
before applying leaf configuration.

Roots load shared inventory through relative symlinks. Keep those links.
