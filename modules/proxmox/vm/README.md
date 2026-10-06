# Proxmox VM module

Creates one image-backed VM with the root's Proxmox provider.

| Input | Purpose |
| --- | --- |
| `name` | VM hostname. |
| `vm` | Node, VM ID, optional management address, ordered extra NICs and overrides. |
| `vm_config` | Shared defaults; requires `datastore_id` and `import_image`. |

Example call from a root under `roots/`:

```hcl
module "vm" {
  source = "../../modules/proxmox/vm"
  name   = "lab01"
  vm = {
    node      = "venom"
    vm_id     = 401
    cores     = 2
    memory_mb = 2048
  }
  vm_config = {
    datastore_id = "ceph_rbd"
    import_image = "cephfs:import/debian.qcow2"
  }
}
```

The management NIC comes first; extra NICs retain list order.
Cloud-init defaults to DHCP. Images and snippets must already exist in storage.
VMs default to stopped. Keep VM IDs unique across roots using the same cluster.

Outputs are `vm_id` and `node_name`.
See [fabric-vms](../../../roots/fabric-vms/README.md) for an implemented caller.
The module's `tests/vm.tftest.hcl` contains mocked plan tests.
