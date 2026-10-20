# BIND9 with the HashiCorp DNS provider

There are two parts:

1. `main.tf` uses SSH to configure Podman/Quadlet, BIND and its TSIG key.
2. `dns-records.tf` uses `hashicorp/dns` to manage records directly over RFC 2136.

`dns01` is the writable primary; `dns02` receives signed zone transfers. Both
answer queries and forward external lookups to 1.1.1.1 and 1.0.0.1. The writable
zone/journal live in `/var/lib/bind9-container` on each VM, outside the container.
Custom records are not written into the seed zone on every deployment.

## Running it

The runner needs OOB SSH access and direct TCP port 53 access to the primary
(10.8.53.1). The VM SSH user needs passwordless sudo; the VMs need Podman with
Quadlet, systemd and registry access. Allow TCP/UDP 53 between DNS VMs for
transfers and notifications. No Python updater or ownership manifest is used.

For a new installation, bootstrap first so the DNS API is available:

```sh
tofu -chdir=roots/services-config init
tofu -chdir=roots/services-config apply \
  -target=terraform_data.bind9 \
  -var='ssh_private_key_path=~/.ssh/id_ed25519'
tofu -chdir=roots/services-config apply \
  -var='ssh_private_key_path=~/.ssh/id_ed25519'
```

Use the normal, untargeted apply for subsequent record changes. The targeted
apply is only a bootstrap/recovery step. Record-only edits do not restart BIND.
Plans read the actual record sets, show drift, and show additions/changes/deletes.
Removing a managed record from inventory deletes that RRset on apply.

The first apply generates a random 32-byte TSIG secret and keeps it in state.
Keep the existing state and back it up: it contains the secret in plaintext.
Do not replace `random_bytes.dns_tsig` casually; that rotates the key. An optional
`dns_tsig_secret` input lets you supply an existing base64 key instead. Switching
between generated and supplied keys also rotates it. Coordinate key changes
with a bootstrap apply before normal provider refreshes.

## Adding records

Edit `inventory/auto.tfvars/dns-records.auto.tfvars`:

```hcl
dns_hosts = {
  greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" }
  www      = { CNAME = "greatfox.lylat.space." }
  "@"      = { TXT = "v=spf1 -all", MX = "10 mail.lylat.space." }
  mail     = { A = "10.8.25.1" }
  "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }
}

dns_records = [
  { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
]
```

Names are relative to `lylat.space`; `@` means the apex. Targets for CNAME, MX,
NS, PTR and SRV should be absolute names ending in a dot. TXT is **plain text**,
without extra BIND zone-file quotes. MX is `preference target.` and SRV is
`priority weight port target.`. Use one TTL per owner/type RRset. CNAME and PTR
support one target per owner with this provider. Reverse DNS needs a separate
reverse zone; a PTR owner here is still relative to lylat.space.

Supported types: **A, AAAA, CNAME, TXT, MX, NS, PTR, SRV**. The provider has no
resource for CAA or generic TYPE records; these inputs are rejected rather than
silently ignored. SOA, apex NS and DNS-server A records stay bootstrap-owned.
The local authoritative zone shadows public lylat.space, including NXDOMAIN
for unknown names.

## Generated host records

The first locals in `dns-records.tf` generate management and leaf records:

```hcl
proxmox_dns_hosts = {
  for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
  name => { A = cidrhost("10.20.7.0/24", node.id) }
}
proxmox_vteps = {
  for name, node in merge(var.nodes.proxmox_cluster, var.nodes.proxmox) :
  "leaf-${name}" => { A = cidrhost("10.20.10.0/24", node.id) }
}
```

`dns_hosts` replaces a generated host's whole type/value map; include A if also
adding AAAA. `dns_records` appends values. The remaining locals group values by
owner/type. Each resource block handles one type, for example:

```hcl
resource "dns_a_record_set" "records" {
  for_each = { for key, record in local.record_sets : key => record if record.type == "A" }
  zone      = "lylat.space."
  name      = each.value.name
  ttl       = each.value.ttl
  addresses = each.value.data
  depends_on = [terraform_data.bind9]
}
```

This creates a resource such as `dns_a_record_set.records["greatfox|A"]`.
OpenTofu owns the whole RRset: another tool should not manage some of its values.
BIND handles SOA serial increments and replication to the secondary.

## Moving from earlier versions

Keep the same state so the random key and VM bootstrap resources are retained.
Back up the zone/journal and state before migrating. Do not delete the persistent
volume. If this is the first dynamic deployment after the static-file version,
bootstrap seeds SOA/NS/DNS-server A records only. Custom records appear during
the following DNS-provider apply, so there is a short migration window.

If you already ran the custom nsupdate implementation, the old
`terraform_data.dns_records` will disappear from state without deleting DNS data.
The updater script and manifest are no longer used. **Import existing RRsets**
into the new resources before applying, for example:

```sh
tofu -chdir=roots/services-config import \
  'dns_a_record_set.records["greatfox|A"]' greatfox.lylat.space.
```

Repeat for existing generated/custom RRsets with the matching resource type and
owner/type key. Do not import records that do not yet exist. New records are
created normally. Convert old TXT input values from quoted zone-file strings
to plain text, and remove unsupported CAA/TYPE inputs before planning.

## Checking it

```sh
dig @10.8.53.1 greatfox.lylat.space A
dig @10.8.53.2 greatfox.lylat.space A
dig @10.8.53.1 lylat.space SOA +short
dig @10.8.53.2 lylat.space SOA +short
tofu -chdir=roots/services-config test
```

After replication, SOA serials should match. Unsigned updates/transfers are
rejected. Queries/recursion default to 10.0.0.0/8; signed authoritative queries
are also permitted for the provider. TSIG authenticates traffic; it does not
encrypt it. Restart/transfer errors appear in `journalctl -u bind9` on each VM.
