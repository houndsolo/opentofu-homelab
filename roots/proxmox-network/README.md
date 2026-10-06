# Proxmox networking

Manages Ethernet interfaces, bonds, bridges and VLAN interfaces on each
`nodes.proxmox` node.

Edit `inventory/auto.tfvars/nodes.auto.tfvars` and `pve-network.auto.tfvars`.
Interface map keys supply the numeric suffix; VLAN keys supply the VLAN tag.
For example, VLAN key `22` with parent `bond0` creates `bond0.22`.
Configured address prefixes use each node's ID as the host offset.

Set `TF_VAR_pve_api_token`. The provider derives its endpoint from the cluster's
`endpoint_node` and reads `ssh_private_key_path` (default `~/.ssh/id_rsa`).

After [provider setup](../../providers/README.md), run from the repository directory:

```sh
tofu -chdir=roots/proxmox-network init
tofu -chdir=roots/proxmox-network validate
tofu -chdir=roots/proxmox-network plan
```

Import existing interfaces before managing them to avoid duplicate creation.
