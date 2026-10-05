# Proxmox VM

Creates one VM from an existing disk image using this repository's local Proxmox
provider. Configure authentication in the root; the module inherits that provider.
The image and optional cloud-init snippet must already exist in Proxmox storage.

Use separate instance maps and configuration variables for leaves and other VMs.
Both calls use exactly the same module:

```hcl
module "pve_leaves" {
  source    = "../../modules/proxmox/vm"
  for_each  = var.pve_leaves
  name      = each.key
  vm        = each.value
  vm_config = var.proxmox_vtep_vm
}

module "vms" {
  source    = "../../modules/proxmox/vm"
  for_each  = var.vms
  name      = each.key
  vm        = each.value
  vm_config = var.proxmox_vm
}
```

Declare these four inputs in the calling root, using the `vm` object type for
instance-map values and the `vm_config` object type for shared configurations.
Existing `owner` fields can still be used to filter `var.vms` before passing it.
For separate states, put the calls in their respective roots and give every VM a
unique cluster-wide ID. Map separation alone does not create separate states.

Example `.auto.tfvars` values:

```hcl
pve_leaves = {
  leaf01 = {
    node               = "venom"
    vm_id              = 711
    management_address = "10.20.7.111/24"
    gateway            = "10.20.7.1"
    network_devices = [
      { bridge = "vmbr4001" },
      { bridge = "vmbr4002" },
      { bridge = "vmbr4000" },
    ]
  }
}

proxmox_vtep_vm = {
  datastore_id            = "ceph_rbd"
  import_image            = "cephfs:import/vyos-1.5-rolling-202608270227-generic-amd64.qcow2"
  cloud_init_datastore_id = "ceph_rbd"
  user_data_file_id       = "cephfs:snippets/vyos_api.yml"
  management_bridge      = "vmbr0"
  cpu_cores              = 4
  memory_mb              = 4096
  disk_size_gb           = 10
}

vms = {
  app01 = {
    node  = "venom"
    vm_id = 401
    cores = 4
  }
}

proxmox_vm = {
  datastore_id = "ceph_rbd"
  import_image = "cephfs:import/debian.qcow2"
  disk_size_gb = 20
}
```

`vm.node` replaces the attached example's `host_node.hypervisor_node`;
`name` supplies the hostname and `vm.vm_id` is explicit. Compute fabric addresses
and IDs in the caller. `vm.cores`, `vm.memory_mb`, and `vm.bridge` override shared
defaults. The management NIC comes first; `vm.network_devices` adds ordered NICs.
Translate the attachment's `default_underlay_bridges` to those NIC objects in the
caller. DNS, fabric settings, and guest-specific cloud-init content stay outside
this module.

Cloud-init defaults to DHCP; a static `management_address` includes the prefix.
Set `cloud_init = false` for images without cloud-init. Set `agent_enabled = false`
if the image does not run a QEMU guest agent. VMs start automatically by default;
set `vm.started = false` to create one stopped. Outputs are `vm_id` and `node_name`.

Existing module callers must now supply `vm_config` with storage and image values.
This module does not change the repository's inventory or wire up the unfinished
fabric VM root. No infrastructure is applied by adding it.
