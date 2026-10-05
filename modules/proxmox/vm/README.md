# Proxmox VM

Creates one image-backed VM using `local/mechanic/proxmox`. Resource settings
follow [the reference pve_vm module](https://github.com/houndsolo/vyos_vxlan_homelab/tree/1d9cbdf2a5b2b15d2deac71e2c652f3f136d69e2/create_fabric_vms/pve_vm).
Configure the Proxmox provider in the root; authentication is inherited.

The module takes three inputs:

- `name`: VM hostname.
- `vm`: placement (`node`, `vm_id`), management address/gateway, ordered extra
  NICs, and optional per-VM overrides for CPU, memory, bridge, startup and tags.
- `vm_config`: shared resource settings. Only `datastore_id` and `import_image`
  are required; all remaining settings have typed defaults in `variables.tf`.

`vm_config` exposes the reference's description, tags, startup/lifecycle flags,
keyboard, agent, boot order, disk, cloud-init, network model/MTU, serial console,
CPU, memory, OS, VGA and operation timeouts. `vm.tags = []` explicitly removes
shared tags. Nullable per-VM settings fall back to shared settings.

The management NIC comes first, followed by `vm.network_devices` in list order.
An extra NIC requires `bridge` and can override `vlan_id`, `mac_address`, `model`,
`mtu` and `disconnected`. MTU `1` inherits the bridge MTU, as in the reference.

Cloud-init defaults to DHCP; a static `vm.management_address` includes its prefix.
The image and optional user-data snippet must already exist in Proxmox storage.
Set `cloud_init = false` or `agent_enabled = false` for images without those guest
services. VMs default to stopped; `fabric-vms` explicitly enables startup in its
leaf settings. `on_boot` is an independent setting.

Lifecycle `ignore_changes = [initialization[0].user_account]` remains static to
match the reference. OpenTofu requires literal lifecycle rules, so this rule
cannot be set through a variable.

## Shared module, separate inputs

The fabric root calls the module with `var.pve_leaf.vm_config` and one instance per
`var.nodes.proxmox` entry. See
[the fabric root](../../../roots/fabric-vms/README.md) for the complete inventory.
A different root can use its own variables with the same module:

```hcl
module "vm" {
  source    = "../../modules/proxmox/vm"
  for_each  = var.vms
  name      = each.key
  vm        = each.value
  vm_config = var.proxmox_vm
}
```

For example, a general VM can supply:

```hcl
vm = {
  node               = "venom"
  vm_id              = 401
  management_address = "dhcp"
  cores              = 2
  memory_mb          = 2048
}

vm_config = {
  datastore_id  = "ceph_rbd"
  import_image  = "cephfs:import/debian.qcow2"
  disk_size_gb  = 20
  started       = true
  tags          = ["opentofu", "debian"]
  underlay_mtu  = 0
}
```

Outputs are `vm_id` and `node_name`. Keep VM IDs unique across all roots targeting
one cluster. Separate variable maps allow separate VM groups; separate roots give
those groups independent state. Other unfinished repository roots still need
image/storage inputs before using this module.

`tests/vm.tftest.hcl` uses a mocked provider and plan-only runs to check the leaf
layout, a general VM, and non-default resource settings without creating VMs.
