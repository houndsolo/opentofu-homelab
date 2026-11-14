# workloads

This root creates every VM in
[`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars) whose
`owner = "workloads"`, using the shared [VM module](../../modules/README.md#proxmoxvm).
There's nothing special about these VMs. Nothing configures them afterwards, and
they get no generated NICs.

Today there are none (`lab01`, VM 401 on venom, was removed on 2026-11-11). A VM
without a `management_address` gets DHCP on its management NIC (`vmbr0`).

## Adding a workload VM

Add an entry to `vms`:

```hcl
vms = {
  # ...the existing entries stay as they are...

  web01 = {
    owner = "workloads" # required: makes roots/workloads create it
    node  = "fichina"   # Proxmox node to run on
    vm_id = 402         # Proxmox VM ID; must be unique
    image = "debian13"  # a key in vm_images (vm-config.auto.tfvars)

    # Management NIC (eth0 on vmbr0). Leave this line out to use DHCP instead.
    management_address = "10.20.80.2/16"

    # Optional: a NIC on a fabric VLAN. VLAN 9 is in VRF lylat-lan (10.9.0.0/16).
    # Because the fabric stretches the VLAN, this works on any Proxmox host.
    network_devices = [{
      bridge       = "vmbr4000"     # the host's VLAN-aware fabric bridge
      vlan_id      = 9              # Proxmox tags it; the guest sees an untagged eth1
      ipv4_address = "10.9.20.1/16" # outside the DHCP pool, the .67.x DHCP servers and the .0.5 gateway
      ipv4_gateway = "10.9.0.5"     # the anycast gateway on the local leaf
    }]

    # Hardware and other per-VM settings: any vm_config key can be overridden here.
    config = {
      cpu_cores    = 2
      memory_mb    = 2048
      disk_size_gb = 20
      ssh_username = "debian"    # cloud-init creates this user...
      ssh_pubkeys  = ["desktop"] # ...with these keys from inventory/ssh_pubkeys.tf
    }
  }
}
```

Then preview and apply it:

```sh
tooling/walk-roots.sh workloads
```

## Good to know

- **The image must already exist** in Proxmox. `debian13` comes from
  [proxmox-download-files](../proxmox-download-files/README.md), or upload your
  own and add it to `vm_images`.
- **Settings come in layers:** shared `vm_config` defaults, then the image, then
  the VM's own `config` block. See
  [inventory](../../inventory/README.md#vm-configautotfvars-shared-vm-defaults-and-images).
- **Cloud-init only runs at first boot.** If you change the addresses or keys
  later, change them in the guest yourself, or recreate the VM.
- **Pick one default route.** If you add a data NIC with an `ipv4_gateway`, use a
  static management address with no `gateway` (as above). That way the VM
  doesn't end up with two default routes.
