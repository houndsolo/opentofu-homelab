# Network service VMs

Creates `dhcp1`/`dhcp2` using the VTEP VyOS image and `dns1`/`dns2` using a verified
Debian 13 qcow2. DNS VMs also run BIND9 in Podman, managed by OpenTofu.
DHCP application configuration remains deferred.

Edit these shared inventory files; the root loads them through relative symlinks:

- `network-services-vm.auto.tfvars`: one hardware/storage template for all four VMs.
- `network-services.auto.tfvars`: VM names, placements, IDs and addresses.
- `records.auto.tfvars`: extra DNS records in `lylat.space`.

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
it. The DNS provider owns the A records after bootstrap. Define additional records
in `records.auto.tfvars`; OpenTofu creates them through the provider.

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

OpenTofu combines all `.tf` files into one dependency graph. The apply order is:

1. Debian image download and cloud-init snippet uploads.
2. `module.dns` VM creation.
3. `terraform_data.bind9` SSH bootstrap and signed zone-readiness checks.
4. All DNS record resources in `dns.tf`.

The TSIG key is generated independently before BIND bootstrap, keeping that path
free of circular dependencies. DHCP VM creation remains independent of DNS.
Dependencies order apply operations; refreshing existing DNS records during a
plan still requires the primary DNS server to be reachable.

Bootstrap also tracks each VM's computed resource ID, so a VM replacement
schedules BIND setup again even when its configured numeric VM ID stays the same.
Bootstrap changes validate staged files with `named-checkconf -z`, restart BIND,
and wait for the zone to load before provider updates. Existing zone files and
journals are never replaced on redeployment. Provisioners do not continuously
reconcile guest changes. After a manual guest change or a rebuild performed
outside OpenTofu, redeploy the bootstrap using:

```sh
tofu -chdir=roots/network-services apply \
  -replace='terraform_data.bind9["dns1"]' \
  -replace='terraform_data.bind9["dns2"]'
```

Removing the bootstrap resource does not uninstall BIND. Destroying a DNS record
resource removes that record through the DNS provider.

## DNS entries

Edit [`inventory/auto.tfvars/records.auto.tfvars`](../../inventory/auto.tfvars/records.auto.tfvars).
Keys are lowercase hostnames relative to `lylat.space`. Supply only the types you
want; omitted fields and `null` are ignored. A hostname can have both A and AAAA,
or a CNAME alone. All records use a 300-second TTL.

```hcl
records = {
  host01 = {
    a    = "10.0.0.1"
    aaaa = "fd69::1"
  }
  app = { cname = "host01.lylat.space." }
}
```

This creates `host01.lylat.space` IPv4/IPv6 records and an `app.lylat.space` alias.
CNAME targets must be fully qualified and end in a dot. Commented examples in
the inventory file can be used as a starting point.

Proxmox A records are automatic: both `nodes.proxmox_cluster` and `nodes.proxmox`
are included, with management addresses `10.20.7.<id>`. For example,
`fichina.lylat.space` resolves to `10.20.7.11`, and `greatfox.lylat.space` to
`10.20.7.20`. Node additions and ID changes flow through on the next apply.
Proxmox names and `dns1`/`dns2` are reserved; do not redefine them in `records`.
Removing a manual entry removes its provider-managed record on the next apply.

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
