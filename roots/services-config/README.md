# DNS services: BIND9, Podman and RFC 2136

This experimental `codex-tsig` branch changes the DNS pair to one writable
primary (`dns01`, 10.8.53.1) and one secondary (`dns02`, 10.8.53.2). Both still
provide recursion through 1.1.1.1/1.0.0.1 and serve the local lylat.space zone.

## How it works

- `terraform_data.bind9` bootstraps BIND over OOB SSH with Quadlet and TSIG.
- The primary seeds only SOA/NS/DNS-server A records once. Its zone and journal
  are persistent under `/var/lib/bind9-container/primary` on the host.
- The secondary stores its transferred zone under the same host directory's
  `secondary` subdirectory. Signed NOTIFY and AXFR/IXFR replicate primary changes.
- `terraform_data.dns_records` sends one signed RFC 2136 transaction for the
  desired custom/generated RRsets. It runs `nsupdate` in the primary container
  through SSH; the protocol speaks to the primary on its service address.
- Record-only edits do not change bootstrap files or restart either service.
  BIND increments the SOA serial automatically and notifies the secondary.
- `/var/lib/bind9-tofu-records.json` on the primary tracks owner/type pairs
  managed by this root. Removed records are deleted on the next successful apply;
  unrelated dynamically added RRsets are left alone. Do not edit the same RRset
  from another client: OpenTofu replaces all values for each RRset it owns.
- A rejected update leaves the ownership manifest unchanged. Each transaction
  replaces all desired RRsets, so retrying an interrupted apply is safe.

## First apply / migration from the static-file branch

Back up the existing `/etc/bind9-container` configuration and your OpenTofu state.
For a previous dynamic deployment, also back up the zone, journal and ownership
manifest together. Do not overwrite a live dynamic zone file manually.

The initial migration deliberately seeds a fresh primary zone containing only
bootstrap records; it does not import the old static zone. All desired records
must be present in the inventory before applying. The update phase adds them
immediately after bootstrap; there can be a brief window where they are absent.
The old static file is retained but is no longer loaded. Nothing is applied by
switching branches alone.

The default generates a 32-byte TSIG key automatically using `random_bytes` on
the first apply. The key is retained in OpenTofu state, so subsequent applies
reuse it. No secret file or manual key generation is needed:

```sh
tofu -chdir=roots/services-config init
tofu -chdir=roots/services-config plan -var='ssh_private_key_path=~/.ssh/id_ed25519'
tofu -chdir=roots/services-config apply -var='ssh_private_key_path=~/.ssh/id_ed25519'
```

Back up and protect the state: it contains the generated secret in plaintext.
Losing or replacing the random resource rotates the key. Do not taint/replace
it casually. The generated value is sensitive and is not exposed as an output.
To reuse an existing key instead, set `TF_VAR_dns_tsig_secret` or supply
`dns_tsig_secret` in an ignored `*.secret.auto.tfvars` file. Switching between
an override and generated keys is a key rotation, requiring coordinated rollout.
Protect saved plans and `/etc/bind9-container/tsig.key` on the guests too.
The same HMAC-SHA256 key authenticates updates,
notifications and transfers. It can modify this zone; give it only to trusted
administrators. It grants no authority over other zones. Authentication does
not encrypt DNS traffic. Key rotation restarts the pair and should be planned
as a coordinated operation; separate update/transfer keys can be added later.

Requirements: Podman/Quadlet, systemd and Python 3 on the VMs, passwordless sudo
for their configured SSH user, registry access, and a reachable OOB SSH path.
Allow TCP and UDP 53 between the service addresses for transfers/notifications
and clients. Queries/recursion default to 10.0.0.0/8; adjust
`dns_allowed_clients` as needed. Unsigned updates and transfers are rejected.
The bootstrap still uses SSH; there is no REST management service or external
DNS provider plugin in this implementation.

Use the persistent host directories when rebuilding/upgrading containers.
`dns_deploy_revision` forces bootstrap after rebuilding a VM at the same IP/ID.
Do not change `dns_primary` as an automatic failover mechanism: moving primary
ownership requires transferring the latest zone/journal and ownership manifest.
A missing manifest prevents discovery/removal of previously managed records.
The generated key depends on this root's existing state; apply from the checkout
that owns the deployed services-config state.

Deleting/destroying terraform_data does not uninstall containers or erase the
zone. Provisioners do not detect live drift on every plan. To reconcile external
changes, use `-replace=terraform_data.dns_records` on a reviewed apply.

SOA, apex NS and DNS VM A records remain bootstrap-owned; custom records cannot
replace them. All other BIND data types and RFC 3597 records use the same record
inputs below. Protocol meta-types (ANY/AXFR/IXFR/OPT/TSIG/TKEY) are not data RRsets.
All values for an owner/type RRset must use one TTL. Names are zone-relative,
including `@` for the apex; do not supply fully qualified owner names.

The private local zone shadows public lylat.space. Unknown local names return
NXDOMAIN rather than falling back to public DNS.

## Custom zone records

Edit `inventory/auto.tfvars/dns-records.auto.tfvars`, linked into this root.
Owner names are relative to `lylat.space`; `@` means the zone apex. For example:

```hcl
dns_hosts = {
  greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  www      = { CNAME = "greatfox.lylat.space." }
  mail     = { A = "10.8.25.1" }
  "@" = {
    MX  = "10 mail.lylat.space."
    TXT = "\"v=spf1 -all\""
    CAA = "0 issue \"letsencrypt.org\""
  }
  "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
}
```

This interface does not impose a fixed record-type allowlist: use any uppercase
BIND-supported type, with its RDATA as a single-line zone-file string. Domain
name targets need a trailing dot to be absolute. TXT strings need zone-file
quotes (escaped in HCL). For an unrecognized type, use RFC 3597 `TYPE<number>`
with generic wire-format RDATA. BIND validates updates and rejects invalid transactions; not every owner/type combination is legal
(for example, CNAME cannot coexist with A at the same owner).

Use `dns_records` for multiple values of one type or a different TTL:

```hcl
dns_records = [
  { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
  { name = "opaque", type = "TYPE65280", data = "\\# 2 ABCD" },
]
```

Host-map records use TTL 300; list records default to 300 unless overridden.
Both forms add records alongside the built-in DNS server A and apex NS/SOA
records. They do not replace those built-ins. Avoid adding conflicting records.

## Generated Proxmox management records

`dns-records.tf` demonstrates the live loop over both sets of Proxmox hosts:

```hcl
locals {
  proxmox_dns_hosts = {
    for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
    name => { A = cidrhost("10.20.7.0/24", node.id) }
  }
}
```

This generates, for example, `fichina.lylat.space A 10.20.7.11` and
`greatfox.lylat.space A 10.20.7.20`. Custom `dns_hosts` replace the entire
generated record map for a matching owner; include its A record if also adding
an AAAA. `dns_records` appends additional records. Edit the generator if your
management subnet/address convention changes.

## Verification

```sh
dig @10.8.53.1 greatfox.lylat.space A
dig @10.8.53.2 greatfox.lylat.space A
dig @10.8.53.1 lylat.space SOA +short
dig @10.8.53.2 lylat.space SOA +short
```

After NOTIFY/transfer completes, both SOA serials should match. Inspect
`sudo journalctl -u bind9 -e` on each host for update/transfer errors.
`dig @10.8.53.1 lylat.space AXFR` without a key must fail.

Tests:

```sh
tofu -chdir=roots/services-config test
python3 -m unittest discover -s roots/services-config/tests -p 'test_*.py'
```

The plan tests use an explicitly fake or mocked key and make no SSH connections. A local
isolated BIND integration test also verified signed add/delete replication and
rejection of unsigned UPDATE/AXFR during development.
