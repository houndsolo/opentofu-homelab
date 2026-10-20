# Service VMs

This root manages `services-vms-dns` and `services-vms-dhcp` owners, plus the
legacy `services-vms` owner. They retain `module.vm["<name>"]` state addresses.
The customized Debian QCOW2 and VyOS image/snippets must already exist in PVE;
this root no longer downloads or customizes the Debian image. Downloads are
managed separately in `roots/proxmox-download-files`.

## DHCP VM interfaces

A VM owned by `services-vms-dhcp` gets its management NIC (`net0`) from its VM
inventory settings, followed by one NIC per L2VNI with a non-null `dhcp` block
in `inventory/auto.tfvars/vnis.auto.tfvars`. Omit the block to disable DHCP
participation. Each generated data NIC uses `vmbr4000` and the L2VNI's `vlan_id`.
The list is ordered numerically by VLAN ID, across all VRFs. Both DHCP VMs get
the same data NIC list. Their explicit `network_devices` settings are replaced
by this generated list; DNS VMs retain their explicit settings.

Currently DHCP VLANs are 2, 6, 8, 9, 10 and 12, so each DHCP VM has seven NICs
including management. Adding or removing a selected VLAN can shift subsequent
guest NIC indices; review the plan and VyOS interface bindings before applying.
This configures virtual NICs only, without assigning data-plane IPs, routes,
DHCP scopes or HA settings inside VyOS. Ensure vmbr4000 carries these VLANs on
each host. Management addressing remains unchanged.

DHCP VMs explicitly disable cloud-init IP configuration for all data NICs;
only their management NIC receives an `ip_config` block. Set up all data NIC
addressing through VyOS configuration.

## Static addresses and SSH keys

Edit `inventory/auto.tfvars/vms.auto.tfvars`. The management NIC is always first
(`net0`); `network_devices` adds NICs in list order (`net1`, `net2`, ...).
Each additional NIC supports `ipv4_address` and optional `ipv4_gateway`.
For example (replace the example addresses and public key strings):

```hcl
dns01 = {
  owner              = "services-vms"
  node               = "venom"
  vm_id              = 5301
  image              = "debian13"
  bridge             = "vmbr0"
  management_address = "10.20.7.111/24"
  network_devices = [{
    bridge       = "vmbr4000"
    vlan_id      = 8
    ipv4_address = "10.8.53.1/16"
  }]
  config = {
    ssh_username = "debian"
    ssh_pubkeys = ["laptop", "desktop"]
  }
}
```

Use the same structure for dns02, with its own node, VM ID and unique addresses.
Define keys once in `inventory/ssh_pubkeys.tf`:

```hcl
locals {
  ssh_pubkey = {
    laptop  = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY laptop"
    desktop = "ssh-ed25519 REPLACE_WITH_PUBLIC_KEY desktop"
  }
}
```

Each VM selects names with `config.ssh_pubkeys = ["laptop", "desktop"]`.
All selected keys authorize `ssh_username` (default `debian`). Unknown names
fail during planning. Public keys are stored in Git and state; never add private
keys. Key names identify keys, not separate login users. The registry is shared
by symlink with the service, workload and fabric VM roots. `.tfvars` cannot
reference locals or variables directly; the root passes `local.ssh_pubkey` to
the VM module, which resolves each selected name.

PVE applies VLAN 8 on the second virtual NIC; the guest uses a regular interface,
without an additional VLAN subinterface. Ensure vmbr4000 supports VLAN 8 on each
host. Normally configure a default gateway only on the management NIC to avoid
competing default routes. This example has two static addresses total, one per
NIC. Multiple addresses on a single NIC require custom cloud-init network data.

SSH keys use Proxmox-generated cloud-init user data and cannot be combined with
a custom `user_data_file_id`. User accounts are now reconciled so key changes
appear in plans. Cloud-init settings are intended for first boot; changing keys
or addresses on an already initialized guest may require guest-side changes or
recreation. Review the plan before applying.

The DNS inventory uses `10.8.53.1/16` and `10.8.53.2/16` on VLAN 8.
OOB management uses `10.20.53.1/16` and `10.20.53.2/16` on vmbr0.
Leave `gateway` unset for OOB. No default gateway is
configured on VLAN 8 either; add `ipv4_gateway` there if off-subnet access
(such as fetching Debian packages) requires it.

DHCP data NICs now use `modules/services/dhcp/macs` for static MACs, shared with
services-config's VyOS hw-id bindings. VM 6701 uses `02:00:00:67:01:<VLAN>` and
VM 6702 uses `02:00:00:67:02:<VLAN>`. The sorted DHCP VLAN list and management
NIC separation are unchanged. This format requires VLANs in 1..99. Review both
roots before migrating existing NIC MACs; management MACs are untouched.
