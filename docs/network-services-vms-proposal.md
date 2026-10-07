# Network services VM design

Implemented on `proposal/network-services-vms`. See
[the root's usage instructions](../roots/network-services/README.md).

Use `modules/proxmox/vm` for all four named service VMs:

- `dhcp1`/`dhcp2`: VyOS image shared with VTEP leaves, IDs 6701/6702 on titania/zoness.
- `dns1`/`dns2`: Debian 13 qcow2, IDs 5301/5302 on fichina/fortuna.

A minimal `network-services-vm.auto.tfvars` template supplies the same 2 CPU
cores, 2048 MiB RAM, 10 GiB disk, storage, management bridge and startup settings
to both groups. `network-services.auto.tfvars` contains guest placement/identity
and DNS addressing; image and bootstrap choices remain guest-specific.

DHCP service NICs are deferred. In a future step, attach one NIC per L2VNI with
DHCP enabled and expose a stable interface/MAC mapping for guest configuration.
There is no VNI processing, DHCP MAC calculation or DHCP NIC generation now.

DNS uses `modules/proxmox/download-images` to download a pinned, SHA512-verified
Debian image to shared storage. Minimal cloud-init snippets set hostname and
SSH-key login and install/start the QEMU guest agent. Ordered cloud-init IP
configs match the management and DNS service NICs. The shared VM module keeps
the previous management-only behavior when explicit IP configs are omitted.

The shared Proxmox provider configuration is unchanged. `bind9.tf` now configures
the DNS VMs with a Podman Quadlet and Cloudflare forwarders. `dns.tf` uses
`hashicorp/dns` for the inventory's A records in `lylat.space`. OpenTofu generates
the TSIG key automatically; dns1 accepts authenticated updates, and dns2 receives
signed transfers. Writable persistent storage retains zones and journals.
DHCP application configuration remains outside this root's scope. No live infrastructure was modified during development;
the Debian image URL/checksum are pinned in shared inventory, and Debian's SSH
public key is loaded automatically from the existing `ssh_private_key_path` plus
`.pub`.

References inspected for the original implementation:

- [Old Proxmox DNS VMs](https://github.com/houndsolo/old_proxmox_repo/blob/7147307d5fe140ddb658376dc058f5289f1e0cc9/vm.auto.tfvars).
- [Old image download module](https://github.com/houndsolo/old_proxmox_repo/tree/7147307d5fe140ddb658376dc058f5289f1e0cc9/modules/proxmox_download_files).
- [VyOS DHCP VM creation](https://github.com/houndsolo/vyos_vxlan_homelab/blob/1d9cbdf2a5b2b15d2deac71e2c652f3f136d69e2/create_fabric_vms/main.tf).
