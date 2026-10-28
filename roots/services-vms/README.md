# Service VMs

Creates VMs with `owner = "services-vms"`: `role = "dns"`, `role = "dhcp"`, or no
role for other service VMs. Images/snippets must already exist; optional Debian downloads
live in `proxmox-download-files`. Configure guest services with `services-config`.

Edit `inventory/auto.tfvars/vms.auto.tfvars`. Management is net0 on vmbr0 with no
OOB gateway. DNS VMs use explicit ordered `network_devices`, for example:

```hcl
dns01 = {
  owner              = "services-vms"
  role               = "dns"
  node               = "venom"
  vm_id              = 5301
  image              = "debian13"
  management_address = "10.20.53.1/16"
  network_devices = [{
    bridge       = "vmbr4000"
    vlan_id      = 8
    ipv4_address = "10.8.53.1/16"
  }]
  config = {
    ssh_username = "debian"
    ssh_pubkeys  = ["laptop", "desktop"]
  }
}
```

Define named public keys in `inventory/ssh_pubkeys.tf` (`local.ssh_pubkeys`).
Selected keys authorize the configured user. Unknown names fail planning.
Cloud-init applies addresses/keys at first boot; existing guests may need manual
changes or recreation. Custom user-data snippets cannot also use generated keys.

DHCP VMs get one data NIC on vmbr4000 (the DHCP MAC module's `bridge`) per
DHCP-enabled L2VNI, sorted by VLAN.
This replaces their explicit data-NIC list. Cloud-init only configures management;
VyOS configuration supplies data IPs. Static MACs are shared with the DHCP module:
`02:00:00:67:<vm_id % 100>:<VLAN>` using decimal-looking octets (VLANs 1..99).
Adding/removing VLANs can shift ethN indices; review both service roots together.

PVE applies VLAN tags; guests use ordinary interfaces. Ensure bridges carry the
selected VLANs and configure a data gateway if off-subnet access is needed.

```sh
tooling/walk-roots.sh services-vms services-config
```
