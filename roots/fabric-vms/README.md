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

