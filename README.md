# OpenTofu homelab

Proxmox infrastructure and a VyOS EVPN/VXLAN fabric.

- `inventory/auto.tfvars/`: shared configuration values.
- `inventory/schema/`: variable types and validation.
- `roots/`: separate OpenTofu configurations and state.
- `modules/`: reusable configuration.
- `providers/` and `tooling/`: local provider sources and build scripts.

Start with [provider setup](providers/README.md), then choose a
[root](roots/README.md). Run commands from the repository directory:

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan
```

Edit the shared inventory and keep its relative symlinks.
Each root has its own local state. The repository directory is not a deployment root.
