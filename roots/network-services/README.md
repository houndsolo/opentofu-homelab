# Network service VM creation

Creates `dhcp1`/`dhcp2` from the same VyOS image as the VTEP leaves, and
`dns1`/`dns2` from a verified Debian 13 qcow2 image. This root does not configure
DNS or DHCP applications, scopes, HA or guest service addresses on VyOS.

Edit `inventory/auto.tfvars/network-services.auto.tfvars`. It declares the four
VMs and uses the typed profile defaults in `inventory/schema/network-services.tf`.
All inventory is loaded through relative symlinks. Pair members are placed on
separate cluster nodes:

| VM | Node | VM ID | Management address |
| --- | --- | --- | --- |
| dhcp1 | titania | 771 | 10.20.10.251/16 |
| dhcp2 | zoness | 772 | 10.20.10.252/16 |
| dns1 | fichina | 5301 | 10.20.53.1/16 |
| dns2 | fortuna | 5302 | 10.20.53.2/16 |

Verify IDs and addresses are available in the live cluster before applying.
An existing `dns01` or a VM with one of these IDs must be adopted/imported or
migrated in state before creation; the old example entry is removed from general
VM inventory. Other workload definitions remain unchanged.

## Required image and SSH inputs

Supply `debian_image` and `dns_ssh_public_keys` in an ignored private tfvars file
or through `TF_VAR_debian_image` and `TF_VAR_dns_ssh_public_keys` as JSON. Public
keys are for the initial Debian user (`mechanic` by default); no passwords or
private keys are embedded in user-data.

`debian_image` requires:

- `url`: an immutable, dated official Debian 13 generic amd64 qcow2 URL.
- `file_name`: the matching versioned filename.
- `checksum`: the published 128-character SHA512 checksum.
- Optional `node`/`datastore_id`: default `fichina`/`cephfs`.

Select the dated artifact and SHA512 from
<https://cloud.debian.org/images/cloud/trixie/>. `latest` URLs and malformed
checksums are rejected. The cloud environment blocked access to that catalog
during implementation, so no unverified pin is provided. Fixture URLs/checksums
in tests are mock-only and must not be used for deployment.

`modules/proxmox/download-images` downloads the Debian image once into shared
storage using `proxmox_download_file`, with TLS/checksum verification enabled and
unmanaged overwrite disabled. Both DNS disks depend on that returned file ID.
The Proxmox node must reach the download URL. `cephfs` must support `import` and
`snippets` and be available from both DNS hypervisors. `ceph_rbd` stores boot disks
and cloud-init drives. If those assumptions differ, adjust storage or use one
source image per node; a node-local image cannot be shared by file ID alone.

DHCP reuses `pve_leaf.vm_config.import_image` and the existing VyOS bootstrap
snippet. `network_services.dhcp_vm_config` can override hardware, startup/tags and
the snippet ID. The root does not download or take ownership of that VyOS image.

## NICs and bootstrap

Debian guests have management on `vmbr0` and service on `vmbr4000`, VLAN 8.
Cloud-init lists those addresses in the same order: management has no gateway,
service uses `10.8.53.1/16` or `10.8.53.2/16` with gateway `10.8.0.5`. The VM module's
new optional `ip_configs` input validates NIC/address counts and one default
route; callers that omit it retain the previous management-only behavior.

Per-VM DNS snippets set hostname, SSH-key login and install/start only
`qemu-guest-agent`. No DNS/DHCP application package or server configuration is
included. Guest package installation needs working outbound networking.

DHCP service NICs are generated from `vnis[*].l2` entries with a non-null `dhcp`
section, sorted by VNI key. Each uses `vmbr4000` and the declared VLAN. MAC slots
1/2 generate separate stable `02:70:00:<slot>:<VLAN high>:<VLAN low>` addresses.
`dhcp_interfaces` exports VNI/interface/bridge/VLAN/MAC mappings for later guest
configuration. Adding a VNI may shift interface indices; use the exported MACs
to bind guest interfaces later. No guest DHCP service IPs are configured now.

## Run and test

The root uses the existing shared Proxmox provider configuration unchanged.
Supply its existing credentials/SSH prerequisites, activate the local provider
mirror, then run:

```sh
tofu -chdir=roots/network-services init
tofu -chdir=roots/network-services validate
tofu -chdir=roots/network-services plan -var-file=/absolute/path/services.secret.tfvars
```

A real image download, guest boot and cloud-init check require a reviewed apply.
No live apply was performed during implementation.

The root and module tests use mocked providers and fake fixture metadata; no
resources are created:

```sh
tofu -chdir=roots/network-services test
tofu -chdir=modules/proxmox/vm test
tofu -chdir=modules/proxmox/download-images test
```
