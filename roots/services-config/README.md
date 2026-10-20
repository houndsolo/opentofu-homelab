# DNS services with Podman

This root deploys BIND9 on VMs owned by `services-vms-dns`. It does not create
VMs or install Podman. Each VM must have Podman with Quadlet support, systemd,
a reachable static OOB management address, and passwordless sudo for its
`config.ssh_username` (currently `mechanic`). The runner needs SSH access to
both OOB addresses with an authorized private key. The VMs need registry access
and outbound TCP/UDP DNS access to Cloudflare.

Both servers run the same stack, listening only on their respective vmbr4000
VLAN 8 IPv4 address, on TCP and UDP port 53. Host networking is used. Port 53
must be free on that address. This root does not change the guest firewall.

- Queries outside `lylat.space` forward only to 1.1.1.1 and 1.0.0.1.
- The authoritative local zone contains dns01.lylat.space = 10.8.53.1 and
  dns02.lylat.space = 10.8.53.2, derived from VM inventory, with both NS records.
- Both servers load the zone independently; no zone transfer or dynamic updates.
- Queries/recursion are allowed from 10.0.0.0/8 and loopback by default. Adjust
  `dns_allowed_clients` if other networks should use these resolvers.
- The local zone shadows the entire public lylat.space zone: unknown local names
  return NXDOMAIN, without forwarding to public DNS. No zone-apex A record or
  reverse zone is created.

Review and apply separately from VM creation:

```sh
tofu -chdir=roots/services-config init
tofu -chdir=roots/services-config plan -var='ssh_private_key_path=~/.ssh/id_ed25519'
tofu -chdir=roots/services-config apply -var='ssh_private_key_path=~/.ssh/id_ed25519'
```

The private key must match one authorized on the guests. `bind9_image` defaults
to `docker.io/internetsystemsconsortium/bind9:9.20`; override with a version or
digest to pin it more tightly. It is pulled on deployment, with no auto-update
service. The image's default bind user runs named inside a rootful container.

OpenTofu uses built-in `terraform_data` SSH provisioners to upload a deployment
script. BIND validates its configuration and zone in a temporary container
before files are installed. Configuration goes in `/etc/bind9-container` and
Quadlet in `/etc/containers/systemd/bind9.container`. systemd starts the generated
`bind9.service`, and Quadlet's Install section starts it on subsequent boots.
Template, inventory connection, or image-reference changes trigger redeployment
and a brief restart. A local zone change redeploys both hosts. If a VM is rebuilt
with the same address and VM ID, change `dns_deploy_revision` or use
`-replace='terraform_data.bind9["dns01"]'` to bootstrap it again.

Provisioners do not continuously detect guest-side drift. Removing a VM from
this root or destroying its terraform_data resource does not uninstall the
container: stop `bind9.service` and remove its Quadlet manually when retiring it.
The first rollout is not an atomic operation across both hosts.

Verify from a permitted client:

```sh
dig @10.8.53.1 dns01.lylat.space A
dig @10.8.53.1 dns02.lylat.space A
dig @10.8.53.2 dns01.lylat.space A
dig @10.8.53.2 dns02.lylat.space A
dig @10.8.53.1 example.org A
dig +tcp @10.8.53.2 example.org A
```

On each VM, inspect `sudo systemctl status bind9` and
`sudo journalctl -u bind9 -e` for runtime errors.
