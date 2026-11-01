# services-config

This root sets up the software on the VMs that
[services-vms](../services-vms/README.md) created: BIND 9 on the DNS VMs, the
DNS records, and the DHCP high-availability pair.

| File | What it does |
| --- | --- |
| `main.tf` | Deploys BIND 9 on each DNS VM over SSH (Podman + Quadlet), and generates the TSIG key |
| `dns-records.tf` | Builds the generated record names (taking the leaf list from `modules/fabric/leaves`), and manages records in `lylat.space` with signed RFC 2136 dynamic updates (the `hashicorp/dns` provider) |
| `dhcp.tf` | Works out the DHCP HA pair and calls [modules/services/dhcp](../../modules/README.md#servicesdhcp) for each DHCP VM (VyOS API) |
| `variables.tf` | This root's own settings (see [Inputs](#inputs)) |
| `providers.tf` | Provider requirements: `vyoscmd` (built locally), `hashicorp/dns`, `hashicorp/random` |
| `templates/` | `named.conf`, the seed zone, the TSIG key file, the Quadlet unit and the deploy script |
| `tests/` | A `tofu test` suite with mocked providers |

## Contents

- [Requirements](#requirements)
- [Inputs](#inputs)
- [First deployment: bootstrap first](#first-deployment-bootstrap-first)
- [How BIND is deployed](#how-bind-is-deployed)
- [DNS records](#dns-records)
- [The TSIG key](#the-tsig-key)
- [DHCP](#dhcp)
- [Checking that it works](#checking-that-it-works)
- [Tests](#tests)

## Requirements

**On the DNS VMs:**

- Podman with Quadlet support, and systemd
- SSH login as `config.ssh_username` with the key in `ssh_private_key_path`,
  and **passwordless sudo** for that user (the deploy runs `sudo -n`)
- Access to `docker.io`, to pull the BIND image

**On the DHCP VMs:** the VyOS HTTPS API on the management address, using the
key in `vyos_api_key`.

**From the machine running OpenTofu:**

| To | Port | Why |
| --- | --- | --- |
| DNS VMs' management addresses (`10.20.53.1`, `.2`) | TCP 22 | SSH, to deploy BIND |
| Primary DNS service address (`10.8.53.1`) | TCP 53 | RFC 2136 record updates (the provider uses TCP) |
| DHCP VMs' management addresses (`10.20.67.1`, `.2`) | TCP 443 | VyOS HTTPS API |
| The OpenTofu registry | TCP 443 | `tofu init` downloads `hashicorp/dns` and `hashicorp/random` |

**Between the DNS VMs:** TCP and UDP 53, for change notifications and zone
transfers.

## Inputs

| Variable | Default | What it does |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Private key used to SSH into the DNS VMs |
| `vyos_api_key` | `null` (then `VYOS_API_KEY` is used) | API key for the DHCP VMs |
| `dns_primary` | `dns01` | Which DNS VM is the writable primary. The others are secondaries. |
| `dns_allowed_clients` | `["127.0.0.1/32", "10.0.0.0/8"]` | Networks allowed to query and to use recursion |
| `bind9_image` | `docker.io/internetsystemsconsortium/bind9:9.20` | Container image. Pin a digest (`...@sha256:...`) for repeatable deployments. |
| `dns_deploy_revision` | `"1"` | Change it to force a redeploy, for example after rebuilding a DNS VM that kept its address and ID |
| `dns_tsig_secret` | `null` (generate one) | Supply an existing TSIG key; see [The TSIG key](#the-tsig-key) |
| `dhcp_ha_prefix` | `"10.6.67.0/24"` | Where the DHCP HA pair talks: the lower VM ID uses host `.1`, the higher `.2`. See [The HA pair](#the-ha-pair). |
| `dns_hosts`, `dns_records` | empty | Your records, from [`dns-records.auto.tfvars`](../../inventory/auto.tfvars/dns-records.auto.tfvars) |

The root also reads `vms`, `vnis`, `nodes` and `fabric` from the inventory.

## First deployment: bootstrap first

**Why a bootstrap is needed.** The DNS provider signs every update with the
TSIG key and sends it to BIND on the primary. On a brand-new deployment, neither
exists yet: the key is generated in this same root, and BIND isn't running. So
the very first run is a *targeted* apply. It only generates the key and deploys
BIND (`-target=terraform_data.bind9`). After that, a normal apply can manage the
records and DHCP.

With the guided runner:

```sh
TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519 tooling/walk-roots.sh services-config
#   choose  b   -> bootstrap: plans only terraform_data.bind9 and its key; type "yes" to apply
#   choose  a   -> normal plan and apply: DNS records and DHCP; type "yes" to apply
```

By hand:

```sh
tooling/with-secrets tofu -chdir=roots/services-config init
tooling/with-secrets tofu -chdir=roots/services-config apply -target=terraform_data.bind9   # bootstrap
tooling/with-secrets tofu -chdir=roots/services-config apply                                # everything else
```

OpenTofu warns that `-target` is meant for exceptional cases. That's expected
here. After the first deployment, normal applies are all you need.

## How BIND is deployed

There's one `terraform_data.bind9` resource per DNS VM (every `vms` entry with
`role = "dns"`). It connects over SSH,
uploads a generated `deploy.sh` into a private `/tmp/tofu-bind9-<id>/`
directory, runs it with `sudo -n`, and then deletes the directory. The script
(`templates/deploy.sh.tftpl`) does this:

1. Checks that Podman is installed, and unpacks the embedded files into a private
   temporary directory: `named.conf`, the seed zone, the TSIG key and the Quadlet
   unit.
2. Pulls the BIND image.
3. **Validates** `named.conf` (`named-checkconf`) and the seed zone
   (`named-checkzone`) in throwaway containers that have no network. A broken
   config never reaches the running server.
4. Looks up the `bind` user's UID and GID inside the image, and creates the
   directories with the right ownership.
5. **On the primary only**, installs the seed zone, but only if no zone file
   exists yet. A zone that has already received RFC 2136 updates, and its
   journal, are never overwritten.
6. Installs `named.conf`, the key file (mode `0640`, `root:bind`) and the Quadlet
   unit, reloads systemd, restarts `bind9.service`, and checks that it's active.

What ends up on each DNS VM:

| Path on the VM | Seen inside the container as | What it is |
| --- | --- | --- |
| `/etc/bind9-container/named.conf` | `/etc/bind/named.conf` (read-only) | The BIND config |
| `/etc/bind9-container/tsig.key` | `/etc/bind/tsig.key` (read-only) | The TSIG key |
| `/var/lib/bind9-container/primary/` | `/var/lib/bind/primary/` | The zone file and its journal (primary) |
| `/var/lib/bind9-container/secondary/` | `/var/lib/bind/secondary/` | The transferred copy (secondary) |
| `/etc/containers/systemd/bind9.container` | | The Quadlet unit |

**What's Quadlet?** It's Podman's systemd integration. You drop a `.container`
file into `/etc/containers/systemd/`, and systemd turns it into a normal service.
Here, that's `bind9.service`. It uses host networking, restarts on failure, and
starts at boot. BIND runs in the foreground (`-g`), so its logs go to the journal.

**When it redeploys.** The script runs again whenever any of these change:

- a rendered file (`named.conf`, seed zone, key, unit) or the image
- the VM's management address, VM ID or `ssh_username`
- `dns_deploy_revision`

Editing DNS records never redeploys or restarts BIND.

### What BIND is set up to do

From `templates/named.conf.tftpl`:

- **Listening.** BIND listens only on the DNS service address, on port 53 over
  IPv4. That's each DNS VM's one NIC with an `ipv4_address`: `10.8.53.1` and
  `10.8.53.2`. IPv6 is off.
- **Who may use it.** Queries and recursion are allowed from
  `dns_allowed_clients` and from the DNS servers themselves. Anyone presenting
  the TSIG key may also query.
- **Recursion.** Everything outside its own zones is forwarded to `1.1.1.1` and
  `1.0.0.1` (forward only), with DNSSEC validation on (`auto`).
- **`lylat.space`.** `dns01` is the primary. It accepts updates signed with the
  key, and notifies the secondaries using the key. `dns02` is a secondary and
  transfers the zone from the primary using the key. Zone transfers always
  require the key.
- **`haylett.lan`.** This zone is forwarded to `10.0.1.110`. That address is
  hard-coded in the template.
- **The local zone hides the public one.** Because these servers are
  authoritative for `lylat.space`, any name that exists only in a public
  `lylat.space` zone gets "no such name" here.

## DNS records

### Generated records

These are created automatically from the inventory. You don't need to list them:

| Name | Points to | Example |
| --- | --- | --- |
| each Proxmox host (cluster and standalone) | `cidrhost(nodes.management_prefix, ID)` | `venom.lylat.space` → `10.20.7.17` |
| `leaf-<ID>`, for every physical leaf and every Proxmox host | `cidrhost(fabric.settings.management_prefix, ID)` | `leaf-17` → `10.20.10.17`, `leaf-20` → `10.20.10.20` |
| `spine-<ID>` | the spine's `management_ip` | `spine-1` → `10.20.0.5` |
| each DHCP VM (`role = "dhcp"`) | its management address | `dhcp01` → `10.20.67.1` |
| `dns01`, `dns02`, plus the SOA and apex NS records | the DNS service address | created by the seed zone (bootstrap), not by the DNS provider |

### Your records

Put them in [`inventory/auto.tfvars/dns-records.auto.tfvars`](../../inventory/auto.tfvars/dns-records.auto.tfvars).
Names are relative to `lylat.space`.

```hcl
# dns_hosts: owner => { TYPE = "value" }. One value per type, TTL 300.
dns_hosts = {
  torrent     = { A = "10.8.7.7" }
  www         = { CNAME = "torrent.lylat.space." }     # absolute names end with a dot
  "@"         = { TXT = "v=spf1 -all",                 # "@" is the zone apex, lylat.space itself
                  MX  = "10 mail.lylat.space." }       # MX:  "<preference> <mail server>."
  "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }  # SRV: "<priority> <weight> <port> <target>."
}

# dns_records: a list, for several values of one type or a custom TTL.
dns_records = [
  { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  { name = "app", type = "A", data = "10.8.10.2", ttl = 60 }, # same owner and type -> one set with two addresses
]
```

The format rules, all checked during `plan`:

- **Types.** `A`, `AAAA`, `CNAME`, `TXT`, `MX`, `NS`, `PTR` or `SRV`, in
  uppercase.
- **Names.** Relative names, with `@` for the apex.
- **Values.** One line each, not empty. TXT is plain text with no quotes. MX and
  SRV use the space-separated formats shown above, and their targets end with a
  dot.
- **TTL.** All values for one owner and type share one TTL. Generated records
  and `dns_hosts` use 300, so a `dns_records` entry that adds to them must use
  300 too. A CNAME or PTR has exactly one target.
- **Reserved.** You can't create NS records at the apex, or A records for the DNS
  VMs' own names. The bootstrap owns those.

### When your names match generated ones

A `dns_hosts` entry **replaces everything generated for that name**, not just
the record types it lists. For example, `greatfox` is generated with an A record:

```hcl
# Replaces the generated record: greatfox now has ONLY this AAAA, and no A.
dns_hosts = { greatfox = { AAAA = "fd69:20::20" } }

# Keeps an A and adds the AAAA, because the entry lists both.
dns_hosts = { greatfox = { A = "10.20.7.20", AAAA = "fd69:20::20" } }

# Or leave dns_hosts alone, and add to the generated record with dns_records:
dns_records = [
  { name = "greatfox", type = "AAAA", data = "fd69:20::20" }, # TTL defaults to 300
]
```

`dns_records` never replaces anything. Its values are added to whatever set
already exists for that name and type.

### How records are applied

- **One resource per RRset.** Each owner + type pair becomes one resource
  managing one record set, for example `dns_a_record_set.records["app|A"]`.
- **OpenTofu owns the whole set.** Values you add to a managed set by hand are
  removed on the next apply. Removing a set from the inventory deletes it from
  DNS.
- **Updates go to the primary.** They're sent over TCP to the primary
  (`10.8.53.1`) and signed with the TSIG key. The primary notifies `dns02`, which
  then transfers the change.
- **No reverse zones.** Reverse DNS needs a reverse zone (`in-addr.arpa`), and
  this root doesn't create one. A `PTR` record created here lives in
  `lylat.space`.

To **adopt records that already exist**, import each record set before the first
apply. The import ID is the full name with a trailing dot:

```sh
tooling/with-secrets tofu -chdir=roots/services-config import \
  'dns_a_record_set.records["torrent|A"]' torrent.lylat.space.
```

## The TSIG key

The key is called `tofu-lylat` and uses HMAC-SHA256. It signs the record
updates, the change notifications and the zone transfers between `dns01` and
`dns02`.

- **By default, it's generated once:** 32 random bytes (`random_bytes.dns_tsig`),
  kept in this root's state. That means **the state contains the key**, so back
  up the state. Also back up `/var/lib/bind9-container` on the primary, which
  holds the live zone and its journal.
- **To use your own key,** set `dns_tsig_secret` to the base64 form of 32 random
  bytes, for example the output of `openssl rand -base64 32`.
- **To rotate the key,** BIND has to receive the new key before the DNS provider
  starts using it. Otherwise the provider's refresh of the existing records fails.
  So run a bootstrap apply first (`b` in the runner, or
  `apply -target=terraform_data.bind9`), then a normal apply.

## DHCP

### The HA pair

- **Roles come from VM IDs.** The two DHCP VMs are sorted by VM ID; the names
  don't matter. The lower ID (`dhcp01`, 6701) is the **primary** in slot 1, and
  the higher (`dhcp02`, 6702) is the **secondary** in slot 2.
- **Mode.** The pair runs **active-passive**.
- **HA link.** The two servers talk over `dhcp_ha_prefix` (default
  `10.6.67.0/24`) using its `.1` and `.2`, here `10.6.67.1` and `10.6.67.2` on
  VLAN 6. Those must be the DHCP VMs' own addresses on a DHCP-enabled VLAN, so
  with the default, VLAN 6 must stay DHCP-enabled.
- **Only pairs.** Nothing is configured unless there are exactly two DHCP VMs.

### What each DHCP VM gets

Each DHCP VM gets one `vyoscmd_commands` resource (`<name>-dhcp`), with
`save = true`, so the config is written to the boot config:

1. **System.** The hostname, and `set system ip disable-forwarding`, because
   this is a server, not a router.
2. **Interfaces.** Each data NIC is bound to its MAC (from the same calculator as
   services-vms) and gets the address `10.<VLAN>.67.<slot>/<VLAN prefix length>`.
3. **HA.** The settings described above.
4. **Listening.** The server listens on every data interface. Management (`eth0`)
   is never touched.
5. **Pools.** One pool for each VLAN with a `dhcp.scope`. Each pool sets the
   default router (the anycast gateway), domain name, search list, name servers
   (the DNS service addresses), lease time, ranges and `subnet-id` (the VNI). By
   default it also marks the pool authoritative. The defaults are listed in
   [inventory](../../inventory/README.md#vnisautotfvars-vrfs-vlans-and-dhcp-scopes).

For VLAN 8 on `dhcp01`, that comes out as (excerpt):

```text
set interfaces ethernet eth3 hw-id 02:00:00:67:01:08
set interfaces ethernet eth3 address '10.8.67.1/16'
set service dhcp-server high-availability mode 'active-passive'
set service dhcp-server high-availability source-address '10.6.67.1'
set service dhcp-server high-availability remote '10.6.67.2'
set service dhcp-server high-availability status 'primary'
set service dhcp-server listen-interface 'eth3'
set service dhcp-server shared-network-name l2vni9008 authoritative
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 option default-router '10.8.0.5'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 option name-server '10.8.53.1'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 option name-server '10.8.53.2'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 range 0 start '10.8.5.1'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 range 0 stop '10.8.5.99'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 subnet-id '9008'
```

`tests/fixtures/dhcp-pools.set` has the full list of pool and listen commands
for today's inventory.

### Things to know

- **`set` commands don't remove old values.** If you renumber VLANs or change a
  VM ID, old addresses can stay on the interfaces. Check with
  `show configuration commands | match address`, and delete leftovers by hand.
- **Keep the DHCP VM IDs stable.** They decide the MACs, the HA roles and the
  addresses.
- **Subnets must fit the address scheme.** Every DHCP VLAN's subnet must contain
  `10.<VLAN>.67.1` and `.2`.

## Checking that it works

From a machine inside `dns_allowed_clients`:

```sh
# Both servers should answer, with the same address.
dig @10.8.53.1 venom.lylat.space A +short
dig @10.8.53.2 venom.lylat.space A +short

# The SOA serial goes up with every update. Both servers should show the same number.
dig @10.8.53.1 lylat.space SOA +short
dig @10.8.53.2 lylat.space SOA +short

# Recursion through the forwarders:
dig @10.8.53.1 debian.org A +short
```

On a DNS VM:

```sh
systemctl status bind9.service     # is the service running?
journalctl -u bind9.service -f     # follow BIND's log
sudo podman ps                     # the bind9 container
```

On a DHCP VM (VyOS operational mode):

```text
show dhcp server leases
show configuration commands | match dhcp-server
```

## Tests

`tests/dns.tftest.hcl` mocks the `vyoscmd`, `dns` and `random` providers, so it
never contacts the VMs. `tofu init` still needs all three providers installed,
though: `vyoscmd` from the local mirror, the other two from the registry.

```sh
tofu -chdir=roots/services-config init
tofu -chdir=roots/services-config test
```
