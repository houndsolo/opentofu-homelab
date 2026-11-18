# services-config

Software on the VMs from [services-vms](../services-vms/README.md): BIND 9 + keepalived on
dns01/02, the `lylat.space` and `10.in-addr.arpa` records, the Kea DHCP HA pair (dhcp01/02, VyOS),
NetBox (two nodes) with its Valkey/Sentinel trio, the nginx reverse proxy pair, the dark-triage
helpdesk, and node_exporter, role exporters and Alloy on all of them. DNS and DHCP are documented
here; NetBox, Valkey, the proxy and dark-triage in the header comment of their `.tf` file.
State and plans are encrypted (`state_passphrase`).

| File | What |
| --- | --- |
| `main.tf` | BIND 9 on each DNS VM over SSH (Podman Quadlet), the TSIG key |
| `dns-records.tf` | generated record names (leaf list from `modules/fabric/leaves`) and every record in `lylat.space` / `10.in-addr.arpa`, via signed RFC 2136 updates (`hashicorp/dns`) |
| `dns-keepalived.tf` | keepalived on the DNS pair ([The DNS VIP](#the-dns-vip)) |
| `dns-node-exporter.tf`, `dns-bind-exporter.tf` | node_exporter (:9100) and bind_exporter (:9119) on the DNS VMs |
| `dhcp.tf` | the DHCP HA pair, [modules/services/dhcp](../../modules/README.md#servicesdhcp) per VM (VyOS API) |
| `netbox.tf`, `valkey.tf`, `proxy.tf`, `ticketing.tf`, `nextcloud.tf`, `forgejo.tf`, `radius.tf`, `arr.tf`, `openbao.tf` | the services (table below; the newer ones are documented in their file headers) |
| `*-monitoring.tf` (netbox, nextcloud, radius, forgejo, arr, openbao, valkey, proxy, ticketing) | node_exporter, the role's exporters and Alloy, one deployment per VM separate from the service deploy |
| `alloy.tf` | the Alloy install every Linux service VM gets ([Logs to Loki](#logs-to-loki)) |
| `telemetry.tf` | each VM's lylat-telemetry address (`scrape_ip`), where every exporter and Alloy listens |
| `templates/` | `named.conf`, seed zones, TSIG key, Quadlet units, keepalived/nginx/Valkey configs, the few helper scripts the deploys call |
| `tests/dns.tftest.hcl` | `tofu test` with mocked providers: records, DHCP commands (fixture `tests/fixtures/dhcp-pools.set`), VRRP, Alloy, exporters |

| Service | VMs | Address | Notes |
| --- | --- | --- | --- |
| NetBox | netbox01/02 | `netbox-vip` 10.52.12.106 (lylat-app) | netbox + netbox-worker Quadlets, DB on Patroni, cache/queue in Valkey via Sentinel, media on CephFS `/netbox`; canary-first |
| Valkey + Sentinel | valkey01-03 | none: clients ask the Sentinels (:26379) | Debian packages; Sentinels own the topology after the first deploy; nftables limits 6379/26379 |
| nginx proxy | proxy01/02 | `proxy-vip` 10.2.11.107 (VLAN 2) | TLS with the [certs](../certs/README.md) wildcard, forwards to each service's `<name>-vip`; every published name is a generated CNAME to `proxy-vip` |
| dark-triage | triage01/02 | `dark-triage-vip` 10.52.13.105 (lylat-app) | built from a pinned commit, DB on Patroni; canary-first |
| Forgejo | git01/02 | none: the proxy forwards https://git.lylat.space/ and TCP :2222 (git over SSH) to git01, git02 is the nginx backup (`active_passive`) | active/passive (Forgejo has no global lock): DB on Patroni, sessions/cache/queues in Valkey via Sentinel, repositories and data on CephFS `/forgejo`, issue indexer `db`, code search off; git02 runs with every cron task off; canary (git01) first |

Container images and versions (BIND by digest, exporters, Alloy, nginx, NetBox) come from
[`software-versions.auto.tfvars`](../../inventory/auto.tfvars/software-versions.auto.tfvars) (`containers`),
shared with monitoring-config. A bump redeploys every VM running that container: apply pairs with
`-parallelism=1`.

## Requirements

- **DNS VMs:** Podman with Quadlet, systemd; SSH as `config.ssh_username` with `ssh_private_key_path`
  and passwordless sudo (`sudo -n`); internet (docker.io) to pull images.
- **DHCP VMs:** the VyOS HTTPS API on the management address with the key in `vyos_api_key`.
- **From the machine running OpenTofu:** TCP 22 to every deployed VM's management address
  (`10.20.53.1/.2`, `10.20.11.x`), TCP 53 to the primary's service address `10.8.53.1` (record
  updates over TCP), TCP 443 to `10.20.67.1/.2` (VyOS API).
- **Between the DNS VMs:** TCP/UDP 53 (notify, zone transfers).
- Linked secrets: `vyos`, `app-db` (the apps' Postgres passwords), `netbox`, `forgejo`, `nextcloud`,
  `arr` (CephFS keys), `state`; see [Secrets](../../inventory/README.md#secrets).

## Inputs

| Variable | Default | What |
| --- | --- | --- |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | key for every SSH deploy (DNS, NetBox, Valkey, proxy, ticketing) |
| `containers` | `software-versions.auto.tfvars` | images and versions (see above) |
| `vyos_api_key` | `null` → `VYOS_API_KEY` | DHCP VMs' API key |
| `dns_primary` | `dns01` | the writable primary; the others are secondaries |
| `dns_allowed_clients` | `["127.0.0.1/32", "10.0.0.0/8"]` | may query and recurse |
| `dns_deploy_revision` | `"1"` | change to force a redeploy (e.g. a DNS VM rebuilt with the same address and ID) |
| `dns_tsig_secret` | `null` (generated) | bring your own key ([The TSIG key](#the-tsig-key)) |
| `dns_vrrp` | `{ vip = "10.8.53.53/16", zone_vip = "10.53.53.53/16" }`, `router_id` 53, `zone_vlan_id` 1301 | the DNS VIPs ([The DNS VIP](#the-dns-vip)); `null` = none |
| `dns_node_exporter`, `dns_bind_exporter` | `{}` | exporters on the DNS VMs; bind_exporter reads BIND's statistics channel `127.0.0.1:8053` and its deploy fails unless `bind_up 1`. Neither restarts BIND. `null` skips |
| `dhcp_prometheus_exporters` | `{ vrf = "mgmt" }` | VyOS node-exporter (:9100) and frr-exporter (:9342) on the DHCP VMs' mgmt address |
| `dhcp_syslog` | `{ hosts = ["10.20.11.34", "10.20.11.35", "10.20.11.36"], vrf = "mgmt" }` | VyOS remote syslog (TCP 514, RFC 5424) to loki01-03's own mgmt addresses (no VIP on mgmt); also `port`, `protocol`, `facility`, `level` |
| `alloy` | `{}`: port 12345, `loki_url = "http://10.55.18.101:3100"`, `max_age = "12h"` | [Logs to Loki](#logs-to-loki); `null` skips |
| `netbox_monitoring`, `valkey_monitoring`, `proxy_monitoring`, `ticketing_monitoring` | `{}` | node_exporter + role exporters + Alloy on those VMs; `null` skips |
| `netbox`, `valkey`, `proxy`, `ticketing` | see the `.tf` file | the services; `null` = don't deploy |
| `netbox_cephfs_key` | from `netbox.secret.auto.tfvars` | `null` keeps NetBox media local per VM |
| `forgejo`, `forgejo_cephfs_key` | see `forgejo.tf`; key from `forgejo.secret.auto.tfvars` | Forgejo; no key = not deployed (admin password: `tofu output -raw forgejo_admin_password`) |
| `app_db_passwords` | from `app-db.secret.auto.tfvars` | app DB passwords on Patroni, shared with monitoring-config |
| `telemetry_vlan_id` | `1501` | lylat-telemetry VLAN |
| `dns_hosts`, `dns_records` | from `dns-records.auto.tfvars` | your records |

Also read from the inventory: `vms`, `vnis`, `l2vnis`, `vips`, `nodes`, `fabric`.

## First deployment: bootstrap first

The DNS provider signs updates with the TSIG key and sends them to BIND, but on a fresh deployment
the key (generated in this root) and BIND don't exist yet. So the first apply targets only
`terraform_data.bind9` (and its key); after that, normal applies.

```sh
TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519 tooling/walk-roots.sh services-config
#   b -> bootstrap (only terraform_data.bind9 and its key), then  a -> normal plan and apply
# by hand:
tofu -chdir=roots/services-config apply -target=terraform_data.bind9
tofu -chdir=roots/services-config apply
```

## How the VMs are deployed

Every deployment (BIND, keepalived, each exporter and Alloy, every service, each role's monitoring) is one
`terraform_data` per VM that uploads one script to a private `/tmp/tofu-<name>-<id>/`, runs it with
`sudo -n` and deletes it. The script comes from
[modules/services/quadlet-deploy](../../modules/services/quadlet-deploy/README.md): each `.tf` file only
lists the deployment's files (path, mode, numeric owner, the units it belongs to), units, images, packages
and a few service-specific commands. In short: validate the staged files, install what changed, restart a
unit whose unit file changed, reload it (`ExecReload`) when only its config changed, then run the checks
that need more than the container itself. The unit files are literal `templates/<service>.container.tftpl`.

Health: units whose image has a tool for it carry `HealthCmd=` + `Notify=healthy` (node_exporter,
bind_exporter, BIND, nginx, NetBox, the Nextcloud app and web containers), so `systemctl restart` returns
only once the container is healthy. Checks that need a database, Valkey, another container or a peer
(dark-triage `/api/health`, `bind_up 1`, `nginx_up 1`, `redis_up 1`, Alloy `/-/ready`, Nextcloud
`status.php` and sessions, the RADIUS probes, Valkey replication) are `verify` commands in the deploy.
Each deployment's unit-file list is kept in `/var/lib/tofu-deploy/<name>.units` (a unit dropped from the
list is stopped and its file removed on the next deploy).

| Deployment (`name`) | Special steps |
| --- | --- |
| `bind9` | named.conf/key checked (`named-checkconf`), seed zones checked and installed once on the primary only; a config change runs `ExecReload` = `/usr/local/sbin/bind9-reload` (SIGHUP, fails unless named logs `reloading configuration succeeded`) |
| `dns-keepalived`, keepalived in `ticketing`/`netbox`/`proxy` | `keepalived -t` on the staged config; a change reloads keepalived (keeps the VRRP state), so a keepalived-only change never restarts the app |
| `ticketing` | builds the pinned commit once (`localhost/dark-triage:<commit>`) |
| `netbox`, `nextcloud` | CephFS mount up and the data directories made (`post_install`) before the containers restart |
| `nextcloud` | the shared `lylat.config.php` is published atomically to CephFS; first install on the canary; the session check retries (HAProxy's first health checks) |
| `proxy` | certificate present, `nginx -t` on the staged config; before an nginx restart the VIP holder hands the VIP to a healthy peer (`pre_install`, `templates/proxy-vip-handoff.sh.tftpl`); afterwards `/healthz` serves this config's id and every name answers over TLS |
| `valkey` | the managed settings go to `/etc/valkey/tofu/`; `templates/valkey-apply.sh.tftpl` writes the live configs for the primary the Sentinels report (Sentinel owns them after the first start) and restarts only what changed |
| `forgejo` | CephFS mount up (`post_install`); `/api/healthz` (database, Valkey, storage) and the SSH banner checked from the host; the admin user created on the primary (canary) when none exists |
| `radius` | `freeradius -C` on the staged config; schema on the canary; Status-Server and a rejected-and-logged probe afterwards (`templates/radius-db.sh.tftpl`, unpacked with a pgpass for the deploy only) |

## How BIND is deployed

`terraform_data.bind9` per `role = "dns"` VM (the canary-free pair: apply with `-parallelism=1` when the
unit changes, or both restart at once). Seed zones (`lylat.space`, `10.in-addr.arpa`) are installed only if
no zone file exists: zones with RFC 2136 updates and their journals are never overwritten. A new unit or
image restarts BIND; a `named.conf` or key change reloads it (SIGHUP; no rndc channel), so the cache
survives, and the deploy fails if the reload fails (named keeps the old config).

| On the VM | In the container | What |
| --- | --- | --- |
| `/etc/bind9-container/named.conf`, `tsig.key` | `/etc/bind/` (read-only) | config, key |
| `/var/lib/bind9-container/primary/` | `/var/lib/bind/primary/` | zones + journals (primary) |
| `/var/lib/bind9-container/secondary/` | `/var/lib/bind/secondary/` | transferred copies |
| `/etc/containers/systemd/bind9.container` | | Quadlet unit → `bind9.service` (host network, restart on failure, `named -f`, logs to the journal with category/severity) |

Redeploys on a change of any rendered file or the image, the VM's management address, VM ID or
`ssh_username`, or `dns_deploy_revision`. Record edits never touch BIND.

`templates/named.conf.tftpl`:

- Listens on UDP/TCP 53, IPv4 only: the service address (`10.8.53.1`/`.2`, VLAN 8), the VIP
  `10.8.53.53`, and in lylat-dns the VM's own address (`10.53.53.51`/`.52`) and the zone VIP
  `10.53.53.53`.
- Queries and recursion from `dns_allowed_clients`, the DNS servers and TSIG-signed clients.
- Everything else is forwarded (forward only) to `1.1.1.1`/`1.0.0.1`, DNSSEC validation `auto`.
- `lylat.space` and `10.in-addr.arpa`: dns01 primary (accepts signed updates, notifies with the
  key), dns02 secondary; transfers always need the key.
- `haylett.lan` is forwarded to `10.0.1.110` (hard-coded) and exempt from DNSSEC validation.
- Being authoritative for `lylat.space`, the servers answer NXDOMAIN for names that exist only in
  the public `lylat.space` zone.

## DNS records

### Generated records

| Name | Points to | Example |
| --- | --- | --- |
| `<vm>`, every service and workload VM | the NIC with the default gateway (the zone segment for most); no such NIC: the management address | `netbox01` → `10.52.12.45`, `dhcp01` → `10.20.67.1` |
| `<vm>.mgmt` | `management_address` | `netbox01.mgmt` → `10.20.11.45` |
| `<vip>`, every entry in [`vips.auto.tfvars`](../../inventory/auto.tfvars/vips.auto.tfvars) | the VIP | `netbox-vip` → `10.52.12.106`, `postgres-vip` → `10.56.14.104` |
| each Proxmox host and `<host>.mgmt` | `cidrhost(nodes.management_prefix, ID)` | `venom` → `10.20.7.17` |
| `leaf-<ID>`(`.mgmt`), physical leaves and every Proxmox host | `cidrhost(fabric.settings.management_prefix, ID)` | `leaf-20` → `10.20.10.20` |
| `spine-<ID>`(`.mgmt`) | the spine's `management_ip` | `spine-1` → `10.20.0.5` |
| every proxy host name and alias (`var.proxy`) and the landing page | CNAME `proxy-vip.lylat.space.` | `grafana` |
| `dns01`, `dns02`, SOA, apex NS | service address | from the seed zone, not the provider (`dns01.mgmt` is generated) |

- Every management address has a name under `mgmt.lylat.space`, so `search mgmt.lylat.space` on an
  admin box makes `ssh netbox01` reach the management network. Fabric VMs have no `<vm>` name (they
  are `leaf-<ID>`).
- PTRs (`dns_ptr_record.reverse` in `10.in-addr.arpa`) for every `10.x` address in an A record;
  several names on one address: the shortest wins (`venom.lylat.space`, `netbox01.mgmt.lylat.space`).
  A `PTR` you write yourself lands in `lylat.space`, not the reverse zone.
- Checks fail the plan when a proxy name clashes with a generated name (`proxy_names_unique`) or a
  service VIP in this root differs from `vips.auto.tfvars` (`vips_match_services_config`).

### Your records

In [`dns-records.auto.tfvars`](../../inventory/auto.tfvars/dns-records.auto.tfvars), names relative to
`lylat.space`:

```hcl
dns_hosts = {                                           # owner => { TYPE = "value" }, TTL 300
  torrent     = { A = "10.8.7.7" }
  www         = { CNAME = "torrent.lylat.space." }      # absolute names end with a dot
  "@"         = { TXT = "v=spf1 -all",                  # "@" = the apex
                  MX  = "10 mail.lylat.space." }        # "<preference> <server>."
  "_dns._udp" = { SRV = "0 5 53 dns01.lylat.space." }   # "<priority> <weight> <port> <target>."
}
dns_records = [                                         # several values per type, or another TTL
  { name = "app", type = "A", data = "10.8.10.1", ttl = 60 },
  { name = "app", type = "A", data = "10.8.10.2", ttl = 60 },
]
```

Checked at plan: types `A AAAA CNAME TXT MX NS PTR SRV` (uppercase); one-line, non-empty values, TXT
without quotes; one TTL per owner+type (generated and `dns_hosts` use 300); one target for CNAME/PTR;
no apex NS and no A for the DNS VMs' names (the seed zone owns them).

### When your names match generated ones

A `dns_hosts` entry may add other types to a generated name but not redefine a generated type
(`dns_hosts_not_generated` fails the plan; change the inventory instead). `dns_records` only adds
values to a set, never replaces.

```hcl
dns_hosts   = { greatfox = { AAAA = "fd69:20::20" } }   # OK: AAAA next to the generated A
dns_hosts   = { greatfox = { A = "10.20.7.99" } }       # rejected: A is generated
dns_records = [{ name = "greatfox", type = "AAAA", data = "fd69:20::20" }]   # OK, TTL 300
```

### How records are applied

One resource per owner+type set (`dns_a_record_set.records["app|A"]`), owned entirely by OpenTofu:
values added by hand are removed, a set removed from the inventory is deleted. Updates go over TCP
to the primary (`10.8.53.1`), signed; dns02 follows by notify + transfer (can lag ~20 s: compare
SOA serials). Adopt existing records by import (full name, trailing dot):

```sh
tofu -chdir=roots/services-config import 'dns_a_record_set.records["torrent|A"]' torrent.lylat.space.
```

## The TSIG key

`tofu-lylat`, HMAC-SHA256: signs updates, notifies and transfers.

- Generated once by default (`random_bytes.dns_tsig`, 32 bytes) and kept in the (encrypted) state:
  back up the state and the passphrase, and `/var/lib/bind9-container` on the primary (live zones
  and journals).
- Own key: `dns_tsig_secret` = base64 of 32 random bytes (`openssl rand -base64 32`).
- Rotation: BIND must have the new key before the provider uses it, so bootstrap apply first
  (`b`, or `-target=terraform_data.bind9`), then a normal apply.

## DHCP

- **Roles from VM IDs**: sorted by ID, the lower (`dhcp01`, 6701) is primary/slot 1, the higher
  secondary/slot 2. Only exactly two DHCP VMs get any config.
- **Kea HA, active-passive**, over `l2vnis.ha_dhcp` (VNI 5009 / VLAN 1009, `10.50.9.0/24`, `.1`/`.2`):
  the last NIC, MAC `02:00:00:67:<VM ID % 100>:ff`, no client listening. The HA `name` is the
  **peer's real hostname** (Kea matches it; a mismatch puts both into partner-down).
- One `vyoscmd_commands` per VM (`<name>-dhcp`, `save = true`): hostname, `system ip
  disable-forwarding`, each data NIC addressed `10.<VLAN>.67.<slot>/<prefix>` (no `hw-id`: VyOS names NICs by slot, in the Proxmox NIC order), listen on
  every data NIC (eth0 untouched), one pool per VLAN with `dhcp.scope`: default router (anycast
  gateway), domain name/search, name server = the DNS VIP only (the service addresses if `dns_vrrp`
  is null), lease, ranges, `subnet-id` = VNI, authoritative by default (defaults in
  [inventory](../../inventory/README.md#vnisautotfvars-vrfs-vlans-and-dhcp-scopes)), plus the
  exporters and syslog above.

```text
set interfaces ethernet eth2 address '10.8.67.1/16'
set service dhcp-server high-availability mode 'active-passive'
set service dhcp-server high-availability name 'dhcp02'
set service dhcp-server high-availability source-address '10.50.9.1'
set service dhcp-server high-availability remote '10.50.9.2'
set service dhcp-server high-availability status 'primary'
set service dhcp-server listen-interface 'eth2'
set service dhcp-server shared-network-name l2vni9008 authoritative
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 option default-router '10.8.0.1'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 option name-server '10.8.53.53'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 range 0 start '10.8.5.1'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 range 0 stop '10.8.5.99'
set service dhcp-server shared-network-name l2vni9008 subnet 10.8.0.0/16 subnet-id '9008'
```

### Things to know

- `set` commands don't remove old values: after renumbering VLANs or changing a VM ID, check
  `show configuration commands | grep address` and delete leftovers by hand.
- Keep the DHCP VM IDs stable: they decide MACs, HA roles and addresses.
- Every DHCP VLAN's subnet must contain `10.<VLAN>.67.1` and `.2`.
- Rebuilt dhcp01/02 have new SSH host keys (`ssh-keygen -R <ip>`).

## Logs to Loki

- **Linux service VMs** (DNS, NetBox, proxy, Valkey, ticketing): Grafana Alloy ships the journal
  (every Quadlet container included) to Loki with labels `source="journal"`, `host`, `unit`,
  `container`, `app` (syslog identifier: `bind9`, `nginx`, `Keepalived_vrrp`, ...) and `level`, like
  monitoring-config's VMs. [`alloy.tf`](alloy.tf) renders `templates/alloy.*.tftpl`; the DNS VMs get
  it from `terraform_data.dns_alloy`, the others from their `<role>-monitoring.tf`, so it never
  restarts a service. The deploy validates the config in a throwaway container, restarts Alloy on a
  unit change, reloads it (SIGHUP) on a config change, then waits for `/-/ready`.
- Push path: from the lylat-telemetry NIC to Loki's telemetry VIP `10.55.18.101:3100`; the
  `alloy_telemetry_nic` check warns about Alloy VMs without that NIC (lylat-telemetry is isolated, no
  other route). Alloy's `/metrics` is on the telemetry address `:12345` (monitoring-config job `alloy`).
- **DHCP VMs** (`dhcp_syslog`): VyOS remote syslog to loki01-03's mgmt addresses from VRF `mgmt`,
  the same commands as the leaves.

Check from a VM: `systemctl status alloy`, `curl -s http://<telemetry address>:12345/-/ready`,
`logger -t test hello` → Grafana Explore `{host="dns01", source="journal", app="test"}`.

## Checking that it works

```sh
dig @10.8.53.1 venom.lylat.space A +short     # both servers, same answer
dig @10.8.53.2 venom.lylat.space A +short
dig @10.8.53.1 lylat.space SOA +short         # serials equal on both
dig @10.8.53.1 -x 10.20.7.17 +short           # PTR
dig @10.8.53.1 debian.org A +short            # recursion
```

On a DNS VM: `systemctl status bind9.service`, `journalctl -u bind9.service -f`, `sudo podman ps`.
Don't ssh to the service IPs (10.8.53.x); use the management addresses. On a DHCP VM:
`show dhcp server leases`, `show configuration commands | grep dhcp-server`.

Tests: `tofu -chdir=roots/services-config test` (mocks `vyoscmd`, `dns`, `random`; init still
needs all three installed).

## The DNS VIP

`dns-keepalived.tf`, separate from BIND (a change never restarts BIND; a redeploy reloads keepalived,
which keeps the current MASTER):

- One VRRP instance: `dns_vrrp.vip` 10.8.53.53/16 on BIND's service NIC (VLAN 8, with `use_vmac`,
  MAC 00:00:5e:00:01:35) and `zone_vip` 10.53.53.53/16 on the lylat-dns NIC (no VMAC). BIND listens
  on both and binds them when keepalived adds them.
- VRRPv3 over IPv6, unicast over the `ha_dns` NIC (VNI 5053 / VLAN 1053, `fd69:5053::51`/`::52`,
  derived from 10.50.53.51/.52), VRID 53, no authentication.
- Both start BACKUP with `nopreempt`; `dns_primary` gets priority 150 for the first election only. A
  failing check (`dig` of the `lylat.space` SOA on the VM's own address) puts the node in FAULT,
  releasing the VIP.
- DHCP hands out only the VIP (DT-051): vyoscmd sorts multi-value nodes as text, so a list with the
  server addresses would put .1/.2 ahead of the VIP. Clients configured by hand should use
  `10.8.53.1` + `10.8.53.2`.
- Never reboot both DNS VMs at once: both claim the VMAC and EVPN duplicate-address detection
  freezes it (`vtysh -c 'show evpn mac vni all duplicate'`, clear with
  `clear evpn dup-addr vni all` on every leaf).
