# workloads

Creates every VM in [`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars) with
`owner = "workloads"`, using the shared [VM module](../../modules/README.md#proxmoxvm). Nothing
configures them afterwards and they get no generated NICs. Today there are none.

## Adding a workload VM

```hcl
vms = {
  web01 = {
    owner = "workloads" # makes roots/workloads create it
    node  = "fichina"   # only places a new VM; HA/migrations may move it later without a diff
    vm_id = 402         # must be unique
    image = "debian13"  # a key in vm_images (vm-config.auto.tfvars)

    # Required: static IPv4 CIDR on eth0 (vmbr0). DHCP isn't supported.
    management_address = "10.20.80.2/16"

    # Optional: a NIC on a fabric VLAN (works on any host, the fabric stretches it).
    # VLAN 9 = lylat-lan, 10.9.0.0/16.
    network_devices = [{
      bridge       = "vmbr4000"     # the host's VLAN-aware fabric bridge
      vlan_id      = 9              # Proxmox tags it; the guest sees an untagged eth1
      ipv4_address = "10.9.20.1/16" # outside the DHCP pool (.5.1-.5.99), the .67.x DHCP servers and the .0.1 gateway
      ipv4_gateway = "10.9.0.1"     # the anycast gateway on the local leaf
    }]

    # Any vm_config key can be overridden here.
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

```sh
tooling/walk-roots.sh workloads
```

## Good to know

- The image must already exist: `debian13` comes from
  [proxmox-download-files](../proxmox-download-files/README.md); other images must be uploaded and
  added to `vm_images`.
- Settings layer: `vm_config`, then the image, then the VM's `config`
  ([inventory](../../inventory/README.md#vm-configautotfvars-shared-vm-defaults-and-images)).
- Changing addresses, keys or other cloud-init settings later rebuilds the cloud-init drive and the
  provider reboots the VM; cloud-init then runs as a new instance and regenerates the SSH host keys
  (`ssh-keygen -R <ip>`).
- One default route: with a data NIC that has an `ipv4_gateway`, leave the VM's `gateway` unset (as
  above).
