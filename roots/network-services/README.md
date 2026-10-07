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

## BIND9

`bind9.tf` configures both DNS VMs over their management SSH addresses, using the
existing username and `ssh_private_key_path`. No Ansible or extra provider is
needed. It waits for cloud-init and installs Podman and DNS query tools if missing,
so the same setup works on the existing VMs.

Both servers independently serve the same static `lylat.space` zone:

- `dns1.lylat.space` → `10.8.53.1`
- `dns2.lylat.space` → `10.8.53.2`

The A records and NS records are generated from `network_services.dns`. Other
queries forward only to `1.1.1.1` and `1.0.0.1`. Queries and recursion are allowed
from `10.0.0.0/8` and loopback. Edit `templates/named.conf` to change upstreams or
allowed client networks, and `templates/lylat.space.tftpl` to extend the zone.

OpenTofu writes `/etc/bind9` on each VM; the container mounts it read-only.
BIND runs as the image's `bind` user and writes runtime/cache data to a temporary
writable `/var/cache/bind`. No writable zone files, replication, or dynamic DNS
updates are configured. The Quadlet at `/etc/containers/systemd/bind9.container`
starts at boot, restarts on failure, and publishes TCP/UDP 53 on the service IP
only. `systemctl status bind9` and `journalctl -u bind9` show its status/logs.

Apply from a machine that can SSH to both management addresses. The VMs need
outbound HTTPS for packages/container downloads and TCP/UDP 53 to the upstreams:

```sh
tofu -chdir=roots/network-services plan
tofu -chdir=roots/network-services apply
```

Configuration, inventory address, and installer changes trigger another SSH
deployment. It validates the staged config and zone with `named-checkconf -z`
before installing files, restarts BIND, and checks both local records over UDP/TCP.
Provisioners do not continuously reconcile guest changes. To redeploy after a
manual change or a VM rebuild with the same identity:

```sh
tofu -chdir=roots/network-services apply \
  -replace='terraform_data.bind9["dns1"]' \
  -replace='terraform_data.bind9["dns2"]'
```

Removing the deployment resource does not uninstall the guest service.

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
wiring, generated BIND9 deployments, inventory-driven changes and invalid inputs.
No live apply to Proxmox or SSH to the DNS VMs was performed.
