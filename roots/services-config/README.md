# DNS and DHCP configuration

This root configures VMs created by `services-vms`:

- `main.tf`: SSH installs BIND configuration and its Podman Quadlet.
- `dns-records.tf`: `hashicorp/dns` manages RFC 2136 record sets.
- `dhcp.tf`: derives DHCP pair identities and calls the VyOS DHCP module.

DNS VMs need Podman/Quadlet, systemd, registry access, and SSH with passwordless
sudo. The runner needs TCP 53 access to the DNS primary and HTTPS access to VyOS
APIs. DNS peers need TCP/UDP 53 connectivity. Set `vyos_api_key` or `VYOS_API_KEY`.

```sh
TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519 tooling/walk-roots.sh services-config
```

On first deployment, select **b** to bootstrap BIND, then **a** for a normal apply.
For direct commands, use `tooling/with-secrets tofu -chdir=roots/services-config`
with `init`, then `apply -target=terraform_data.bind9`, then `apply`.
Subsequent runs use normal apply. Record-only edits do not restart BIND.

## DNS records

`dns01` is primary; `dns02` receives signed transfers. Both serve `lylat.space`
and forward external queries to `1.1.1.1` / `1.0.0.1`. Edit
`inventory/auto.tfvars/dns-records.auto.tfvars`:

```hcl
dns_hosts = {
  greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  www      = { CNAME = "greatfox.lylat.space." }
  "@"      = { TXT = "v=spf1 -all", MX = "10 mail.lylat.space." }
  mail     = { A = "10.8.25.1" }
}
dns_records = [
  { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
]
```

Supported types: A, AAAA, CNAME, TXT, MX, NS, PTR, SRV. Names are zone-relative;
`@` is the apex. Targets end in a dot; TXT is plain text, MX is `priority target.`,
SRV is `priority weight port target.`. Use one TTL per owner/type and one target
for CNAME/PTR. Reverse DNS requires a separate reverse zone.

Locals generate A records for Proxmox hosts (`<node>`), spines (`spine-<id>`),
leaves (`leaf-<id>`) and DHCP VMs (`<vm>`).
`dns_hosts` replaces a generated owner's entire type map; `dns_records` adds
values. OpenTofu owns whole RRsets: removing a managed set deletes it. SOA, apex
NS and DNS-server A records are bootstrap-owned. The local zone shadows public
`lylat.space`, including unknown names.

The generated TSIG key is retained in state; preserve and back up state and
`/var/lib/bind9-container`. `dns_tsig_secret` optionally supplies an existing key.
Coordinate key rotation with a bootstrap apply before normal DNS refreshes.
When adopting existing records, import each RRset first, for example:

```sh
tooling/with-secrets tofu -chdir=roots/services-config import \
  'dns_a_record_set.records["greatfox|A"]' greatfox.lylat.space.
```

## DHCP

DHCP VMs are sorted numerically by VM ID: lower ID is primary/slot 1, higher is
secondary/slot 2. Current HA mode is **active-passive**, peering on `dhcp_ha_prefix`
(default `10.6.67.0/24`).
Data addresses are `10.<VLAN>.67.<slot>` with the L2VNI prefix length.

Edit `inventory/auto.tfvars/vnis.auto.tfvars` for DHCP scopes. Each L2VNI with a
`dhcp` block gets a data NIC; `dhcp.scope` adds a pool. Ranges, gateway, DNS,
domain/search, lease and authoritative settings become commands for both peers.
Listen interfaces use the same ordered MAC mapping as VM creation, excluding eth0.

Implementation lives in `modules/services/dhcp/interfaces.tf` and
`dhcp-commands.tf`. `main.tf` combines interface, HA, listen and pool locals into
one saved command resource per VM. Keep VM IDs stable; VLAN/order changes can
require removing old guest addresses because set commands do not remove them.

## Checks

```sh
dig @10.8.53.1 greatfox.lylat.space A
dig @10.8.53.2 greatfox.lylat.space A
dig @10.8.53.1 lylat.space SOA +short
dig @10.8.53.2 lylat.space SOA +short
```

SOA serials should converge. On a DNS VM, inspect `journalctl -u bind9`.
