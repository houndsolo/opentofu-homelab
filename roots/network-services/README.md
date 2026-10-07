# Network service VMs

Creates `dhcp1`/`dhcp2` using the VTEP VyOS image and `dns1`/`dns2` using a verified
Debian 13 qcow2. DNS VMs also run BIND9 in Podman, managed by OpenTofu.
DHCP application configuration remains deferred.

Edit these shared inventory files; the root loads them through relative symlinks:

- `network-services-vm.auto.tfvars`: one hardware/storage template for all four VMs.
- `network-services.auto.tfvars`: VM names, placements, IDs and addresses.

The shared template sets **2 CPU cores, 2048 MiB memory and a 10 GiB boot disk**,
plus storage, management bridge and startup. Both module calls use it directly.
Only image, user-data and guest-specific tags/console settings differ. DHCP
references `pve_leaf.vm_config.import_image` without inheriting VTEP hardware.
Its bootstrap snippet defaults to `cephfs:snippets/vyos_api.yml` and can be changed
through `network_services.dhcp_user_data_file_id`.

| VM | Node | VM ID | Management address |
| --- | --- | --- | --- |
| dhcp1 | titania | 6701 | 10.20.10.251/16 |
| dhcp2 | zoness | 6702 | 10.20.10.252/16 |
| dns1 | fichina | 5301 | 10.20.53.1/16 |
| dns2 | fortuna | 5302 | 10.20.53.2/16 |

DHCP currently has **only the management NIC**. Per-L2VNI service NICs, their MACs
and guest interface bindings are deferred. This root does not load VNI inventory
or generate those NICs yet.

DNS keeps its management NIC and a service NIC on `vmbr4000`, VLAN 8, with
`10.8.53.1/16` or `10.8.53.2/16` and gateway `10.8.0.5`. Cloud-init bootstraps a
public-key user and installs `qemu-guest-agent`, `net-tools` and `podman`.

## BIND9 and provider-managed records

`dns.tf` uses the official [`hashicorp/dns`](https://registry.terraform.io/providers/hashicorp/dns/latest/docs)
provider to manage `dns1.lylat.space` and `dns2.lylat.space` A records from
`network_services.dns`. `dns1` is the primary; `dns2` is the secondary and receives
signed zone transfers. Both forward other queries to `1.1.1.1` and `1.0.0.1`.
Queries and recursion are allowed from `10.0.0.0/8` and loopback.

OpenTofu generates a shared HMAC-SHA256 TSIG key using `random_bytes`. No extra
input is needed. The key is retained in sensitive state and installed in a
restricted configuration file on each VM. Keep the same state between applies.

`bind9.tf` handles only server bootstrap over management SSH: Podman, the Quadlet,
forwarders, the TSIG key and zone declarations. Configuration is mounted read-only;
`/var/lib/bind9` is mounted writable for zones/journals. Initial zone data is seeded
once (or migrated from the previous static primary zone); later applies preserve
it. The DNS provider owns the A records after bootstrap. Add future records as
`dns_*_record_set` resources in `dns.tf`, rather than editing zone files.

The Quadlet starts at boot and publishes TCP/UDP 53 on each service IP only.
Use `systemctl status bind9` and `journalctl -u bind9` on the VMs for status/logs.
Edit `templates/named.conf.tftpl` for upstreams or client networks.

Run from a machine that can SSH to both management addresses and reach
`dns1`'s service IP on TCP 53. Both VMs need outbound HTTPS for packages/images,
TCP/UDP 53 for upstream DNS, and connectivity to each other on TCP/UDP 53:

```sh
tofu -chdir=roots/network-services init
tofu -chdir=roots/network-services plan
tofu -chdir=roots/network-services apply
```

One apply generates the key, bootstraps both servers, then creates the DNS records.
Bootstrap changes validate staged files with `named-checkconf -z`, restart BIND,
and wait for the zone to load before provider updates. Existing zone files and
journals are never replaced on redeployment. Provisioners do not continuously
reconcile guest changes. After a manual guest change or VM rebuild with the same
identity, redeploy the bootstrap using:

```sh
tofu -chdir=roots/network-services apply \
  -replace='terraform_data.bind9["dns1"]' \
  -replace='terraform_data.bind9["dns2"]'
```

Removing the bootstrap resource does not uninstall BIND. Destroying a DNS record
resource removes that record through the DNS provider.

## Image and SSH key

`network-services.auto.tfvars` pins Debian 13's `20261001-2618` genericcloud image
and its supplied SHA512 checksum. Downloads verify that checksum. The image upload
node/datastore default to `fichina`/`cephfs`; no separate image inputs are needed.

Debian's `mechanic` user automatically receives the public key from
`"${pathexpand(var.ssh_private_key_path)}.pub"`, using the same key pair as the
Proxmox SSH connection. With the existing default, this reads `~/.ssh/id_rsa.pub`.
The matching public-key file must exist beside the private key on the machine
running OpenTofu. No separate `dns_ssh_public_keys` input is needed.

The existing shared Proxmox provider configuration is unchanged. Shared `cephfs`
must permit `import`/`snippets` and be accessible to both DNS hosts. The Proxmox
node downloads the image; `ceph_rbd` holds disks/cloud-init drives. Verify VM IDs
and IPs are free, or reconcile existing VMs/state before applying.

```sh
tofu -chdir=roots/network-services init
tofu -chdir=roots/network-services validate
tofu -chdir=roots/network-services plan
tofu -chdir=roots/network-services test
```

`vms` outputs each guest's identity and management address. Mocked tests check
both groups share the template, DHCP has no extra NICs, DNS image/cloud-init
wiring, generated BIND9 deployments, provider-managed records and invalid inputs.
An additional plan check uses the real DNS/random providers for first-time key
generation. Local container checks exercised provider updates, signed replication
and persistent journals.
No live apply to Proxmox or SSH to the DNS VMs was performed.
