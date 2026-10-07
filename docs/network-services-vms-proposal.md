# Network services VM creation proposal

Proposed on `proposal/network-services-vms`, based on `main` at `5c99b2c`.
This is a design proposal. It does not change executable OpenTofu configuration
or create VMs.

Create exactly `dhcp1`, `dhcp2`, `dns1`, and `dns2` in `roots/network-services`,
using the existing `modules/proxmox/vm` module. Keep DHCP/DNS application
configuration for a later step. Cloud-init handles only guest bootstrap: hostname,
SSH access, NIC addressing and, for Debian, the QEMU guest agent.

## Proposed VM inventory

The following defaults come from the reference repositories, not from a live
Proxmox inventory. Confirm the IDs and addresses are available before applying.
All four proposed hosts are in the current `nodes.proxmox_cluster` inventory.

| VM | Proxmox node | VM ID | Image | Management address | Other NICs |
| --- | --- | --- | --- | --- | --- |
| dhcp1 | titania | 771 | Existing VTEP VyOS qcow2 | 10.20.10.251/16 | DHCP-enabled VLANs on vmbr4000 |
| dhcp2 | zoness | 772 | Existing VTEP VyOS qcow2 | 10.20.10.252/16 | Same VLANs on vmbr4000 |
| dns1 | fichina | 5301 | Debian 13 generic amd64 qcow2 | 10.20.53.1/16 | vmbr4000, VLAN 8, 10.8.53.1/16 |
| dns2 | fortuna | 5302 | Same Debian image | 10.20.53.2/16 | vmbr4000, VLAN 8, 10.8.53.2/16 |

Management NICs use `vmbr0`. The DNS service NIC uses gateway `10.8.0.5`, already
present in current VNI inventory. Keep the management NIC gateway unset so each
Debian guest has one default route. Initially use 2 cores/2048 MiB/10 GiB for DNS
and 4 cores/4096 MiB/10 GiB for DHCP; make these shared profile settings editable.
Keep pair members on distinct hypervisors.

## Keep the root small

Add `inventory/schema/network-services.tf` and
`inventory/auto.tfvars/network-services.auto.tfvars`, loaded by relative symlinks.
The input `network_services` has:

- `dhcp`: two VM definitions containing node, VM ID, management CIDR and a stable
  MAC slot (1 or 2).
- `dns`: two VM definitions containing node, VM ID, management CIDR, service CIDR
  and public SSH keys/username for initial login.
- `dhcp_vm_config` and `dns_vm_config`: small, typed profile overrides for hardware,
  disk/storage and startup, rather than duplicating every VM module option.
- `debian_image`: URL, pinned filename, checksum, download node and datastore.

Reuse shared `pve-leaf`, `nodes` and `vnis` inventory through symlinks. DHCP inherits
its VyOS image and disk/CPU defaults from `pve_leaf.vm_config`, with service-profile
overrides for tags and hardware. DNS uses an independent Debian profile and
`["opentofu", "debian", "dns"]` tags. Neither group is assigned the fabric's
spine links, leaf role, VM ID offset or leaf MACs.

Use two clear calls to `modules/proxmox/vm`, `module.dhcp` and `module.dns`. Resolve
`vm_config.import_image` before calling the module: the existing VyOS file ID for
DHCP and the download module's returned file ID for DNS. VM creation therefore
has an implicit dependency on the image download and generated user-data file.
No separate DHCP VM module, Debian VM module, template VM or cloning stage is
needed.

The existing `vms.auto.tfvars` contains an obsolete `dns01`/`pve01` example. Replace
that service example with the dedicated inventory when implementing this root;
leave the unrelated workload VM entry alone. If `dns01` or either reference DNS
VM is already managed or running, reconcile state/imports before adopting the new
names and IDs. Do not blindly recreate it.

## Image download

Add a small `modules/proxmox/download-images` module, modeled on the old repo's
`proxmox_download_files` module. Use **`proxmox_download_file`**, which the pinned
provider supports; the old `proxmox_virtual_environment_download_file` name is
now deprecated. Input is a map of image definitions; output is a map of file IDs.

Download one Debian image on `fichina` into shared `cephfs` with
`content_type = "import"`. Import DNS boot disks into `ceph_rbd`. This assumes
`cephfs` is available on both DNS hosts and permits `import` and `snippets` content;
verify that before applying. If the source datastore is node-local instead,
download/upload once per consuming node rather than reusing a remote local file ID.

The old repo uses Debian's official image:

```text
https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
```

Use that catalog to select a dated Debian 13 generic amd64 image and its published
SHA512 checksum during implementation. Store the immutable URL, filename and
checksum in inventory; do not invent a checksum or silently track `latest`.
Keep TLS verification enabled and default unmanaged overwrite to false. An
existing file should be explicitly adopted/imported or given a unique filename.
The Proxmox download node, not the Codex machine, needs access to the image URL.

Do not download or take ownership of the existing VyOS image in this root:
`pve_leaf.vm_config.import_image` already refers to the exact VTEP image on
`cephfs`. Its ownership stays with the existing image workflow. Updating that
inventory value deliberately updates both service and leaf image references.

The DNS download resource belongs to this root's state. Do not give another root
ownership of the same physical image file. A future shared image root can be
introduced if other roots actually need that artifact.

## Cloud-init and VM module changes

For Debian, create one `proxmox_virtual_environment_file` user-data snippet per
DNS VM in shared `cephfs`, following the old repo's `source_raw`/`yamlencode`
pattern. Set a hostname and SSH-key user, install and enable `qemu-guest-agent`,
and pass the returned snippet ID through the existing `user_data_file_id` input.
Do not install BIND, Unbound, dnsmasq, Kea or any DNS/DHCP service.

The existing VM module already supports custom user-data and extra NICs, but it
only emits one cloud-init `ip_config` block. Add optional ordered `vm.ip_configs`
entries, defaulting to today's management address/gateway behavior when omitted.
Use a dynamic block for those entries. For DNS the list has management then
service addresses, matching management then service NIC order. Validate that any
explicit list has one entry per NIC. This keeps existing fabric VM calls valid.

The existing module ignores `initialization[0].user_account`. Avoid adding a
native user_account input that would silently ignore later changes: make the
custom snippet authoritative for DNS SSH bootstrap in this iteration.

DHCP reuses the current VyOS image and existing bootstrap snippet, unless a
separate snippet is explicitly supplied in service inventory. That snippet is
not DHCP server configuration. Attach service NICs but leave service IPs, scopes,
HA, VRRP, leases, firewall and VyOS API configuration to the later configuration
step. No `vyoscmd` provider/resources are required by this VM-creation root.

## DHCP NIC layout

Adapt only the creation portion of `vyos_vxlan_homelab`: derive additional NICs
from current `vnis[*].l2` entries with a non-null `dhcp` section, sorted by stable
VNI key. Their bridge is `vmbr4000` and VLAN is the declared L2 VLAN. The current
inventory includes VLANs 6 and 8 with DHCP definitions; inspect the full list,
not only those two. VLAN 6 can later serve the HA link without configuring HA now.

Use the reference's separate DHCP MAC namespace:
`02:70:00:<slot>:<VLAN high byte>:<VLAN low byte>`, with slots 1 and 2. This keeps
both guests' NIC MACs distinct and avoids collisions with VTEP MACs. MAC slots
are VM identity, not active/standby server configuration. Output the ordered
interface/VNI/VLAN/MAC map for the later configuration root; retain that order
when configuring guest interfaces. Adding a new VNI can shift ethN positions,
so future interface configuration should bind by MAC rather than assume order.

## Provider wiring and checks

Restore the provider-version and inventory links expected by this root. Use a
cluster-only Proxmox provider configuration matching the existing shared cluster
endpoint and authentication pattern. The current shared provider file also
requires a Greatfox token/key for an unused alias; the four proposed VMs do not
need that alias or that extra credential. Do not change the other roots' providers
as part of this implementation.

Before applying, validate target nodes, unique VM IDs and addresses, one default
route per Debian guest, image/snippet storage access and explicit NIC/IP list
lengths. Use plan-only mocked tests to confirm exactly four VMs, DHCP's inherited
VyOS image, DNS's downloaded Debian image dependency, correct cloud-init/NIC
ordering and no DNS/DHCP application resources. Check existing fabric module
calls still plan with the backward-compatible IP-config default.

A real plan then needs Proxmox API/SSH access; downloading the image and proving
cloud-init inside the guests require an authorized apply. No live readiness is
claimed by this proposal.

## References inspected

- Current homelab checkout: `5c99b2c` (31 commits pulled before analysis).
- [Old Proxmox DNS VMs](https://github.com/houndsolo/old_proxmox_repo/blob/7147307d5fe140ddb658376dc058f5289f1e0cc9/vm.auto.tfvars): dns1/dns2 placement, Debian image, two NICs and guest bootstrap.
- [Old image download module](https://github.com/houndsolo/old_proxmox_repo/tree/7147307d5fe140ddb658376dc058f5289f1e0cc9/modules/proxmox_download_files).
- [VyOS DHCP VM creation](https://github.com/houndsolo/vyos_vxlan_homelab/blob/1d9cbdf2a5b2b15d2deac71e2c652f3f136d69e2/create_fabric_vms/main.tf): shared VyOS image and ordered VLAN NICs/MACs.
- [VyOS DHCP VM inventory](https://github.com/houndsolo/vyos_vxlan_homelab/blob/1d9cbdf2a5b2b15d2deac71e2c652f3f136d69e2/dhcp.auto.tfvars): target nodes, IDs and management address offsets.
- Local pinned provider documentation: `providers/terraform-provider-proxmox/docs/resources/download_file.md` and `virtual_environment_file.md`.
