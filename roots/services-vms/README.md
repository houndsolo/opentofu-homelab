# Service VMs

Debian service VMs (including dns01 and dns02) receive cloud-init vendor data
that refreshes package metadata, installs `qemu-guest-agent`, and starts it.
Package upgrades remain disabled. The snippet is uploaded to shared `cephfs`,
which must allow `Snippets` content; upload uses the provider's SSH connection.
Vendor data preserves Proxmox-generated user and network configuration.
These installation steps run on first boot. Already initialized guests need
the agent installed and started manually, or must be recreated.

This root makes PVE download the official Debian 13 (Trixie) genericcloud
AMD64 QCOW2 before creating service VMs, including dns01 and dns02:

https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2

The cloud image includes cloud-init. It is an imported disk image, rather than
an installer ISO. The download runs once through a Debian VM's node and is
stored on shared `cephfs` as
`cephfs:import/debian-13-genericcloud-amd64.qcow2`.
Enable the `Import` content type on that storage. The PVE API token needs
`Datastore.AllocateTemplate`, `Sys.Audit`, and `Sys.Modify` for the download API.

`overwrite = false` keeps the downloaded image on subsequent applies, even
when Debian updates the `latest` URL. A missing managed file is downloaded again.
If the image already exists before the first apply, import it into state
instead of downloading it again (use the download node shown in the plan):

```sh
tofu -chdir=roots/services-vms import \
  'proxmox_virtual_environment_download_file.debian13[0]' \
  'eldarad/cephfs:import/debian-13-genericcloud-amd64.qcow2'
```

Review the plan before applying. VyOS images and cloud-init snippets still
need to be present separately.

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
