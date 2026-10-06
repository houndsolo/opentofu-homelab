# Fabric VMs

Creates one VyOS VM per entry in `nodes.proxmox`, using the shared
[VM module](../../modules/proxmox/vm/README.md).

Edit `inventory/auto.tfvars/nodes.auto.tfvars` for node IDs and
`pve-leaf.auto.tfvars` for provider, image, storage and VM settings.
The image and any cloud-init snippet must already exist in Proxmox storage.

Names use `hostname_prefix + node name`; VM IDs use `vm_id_offset + node ID`.
Management addresses use `management_prefix` and `management_cidr`.
The management NIC comes first, followed by `default_underlay_bridges` in list order.
[Shared MAC generation](../../modules/fabric/macs/README.md) keeps VM NICs and VyOS bindings consistent.

Set `PROXMOX_VE_API_TOKEN` or `TF_VAR_pve_api_token`. SSH uses the configured
agent unless `TF_VAR_ssh_private_key_path` supplies a key file.

After [provider setup](../../providers/README.md), run from the repository directory:

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan
```
