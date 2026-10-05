# Fabric leaf VMs

Creates exactly one Proxmox leaf VM per entry in `var.nodes.proxmox`, using the
shared `modules/proxmox/vm` module. This root has its own local state.

Edit the shared inventory files:

- `inventory/auto.tfvars/nodes.auto.tfvars`: Proxmox host names and stable IDs.
- `inventory/auto.tfvars/pve-leaf.auto.tfvars`: provider configuration and shared
  leaf VM settings.

The root loads these files through relative symlinks; preserve those links.
`pve_leaf.proxmox` configures the provider. `pve_leaf.vm_config` contains all
shared naming, addressing, networking and resource settings. There is no separate
leaf instance inventory.

The VM module call loops directly over `nodes.proxmox`. Each node's map key supplies
the Proxmox host name; its ID supplies the VM ID, management IP and stable MACs.
For `fichina` with ID `11`, the example shared settings produce:

- Hostname `vtep-fichina`.
- VM ID `711` (`id + vm_id_offset`).
- Management address `10.20.10.11/16`.
- Management NIC on `vmbr0`, followed by `vmbr4001`, `vmbr4002`, `vmbr4000`.
- eth1 MAC `02:07:11:00:11:01`, using the reference repository's MAC formula.

Change `hostname_prefix`, `vm_id_offset`, `management_prefix`, `management_cidr`,
`underlay_local_as_base` and `default_underlay_bridges` inside `vm_config` to change
those shared rules. The remaining `vm_config` settings template the VM resource's
disk, CPU, memory, cloud-init, agent, console, startup and timeouts. Host CPU counts
are inventory metadata; VM CPU counts come from `vm_config.cpu_cores`.

Node IDs must be unique. Derived VM IDs must also be unique across other roots
using the same cluster. Adding or removing a Proxmox node adds or removes its leaf
VM in this root's plan.

Ordered NICs and MACs come from `modules/fabric/macs`, also used by
`fabric-leaves` to configure VyOS `hw-id`. The MAC formula exists only in that
shared inventory module; separate roots calculate the same map from the same
inventory files without reading one another's state.

## Run

Configure `PROXMOX_VE_API_TOKEN` or the sensitive `TF_VAR_pve_api_token` securely.
For image-import SSH, use an agent or set `TF_VAR_ssh_private_key_path` to an
existing key. Credentials are not stored in the inventory. The endpoint must be
reachable and its TLS certificate trusted. The imported image and cloud-init
snippet must already exist in Proxmox storage.

After building/installing the local provider and configuring the CLI mirror:

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan
```

`leaf_vms` outputs each VM's identity and ordered extra NICs. Mocked, plan-only
tests cover the reference layout, shared-setting changes with a different node
inventory, and duplicate-node-ID rejection. They do not establish live API access.
