# Roots

A root is a folder you run `tofu` in. Each deploys one layer and keeps its own local state. Split
so plans stay readable, a mistake in one layer can't plan another's destruction, each root needs
only its own credentials/reachability, and you re-run only what changed.

Roots don't read each other's state (no `terraform_remote_state`); they share only the
[inventory](../inventory/README.md), via symlinks. The order below is not enforced by OpenTofu: it
is real-world readiness (a leaf can't be configured until its VM boots and its API answers).

## Root folder contents

| File | What it is |
| --- | --- |
| `main.tf`, `locals.tf`, ... | The root's own code, mostly module calls |
| `*.auto.tfvars` → `inventory/auto.tfvars/` | Values |
| `*.variables.tf` → `inventory/schema/` | Variable declarations |
| `providers.tf`/`*-provider.tf`, `versions.tf` → `inventory/provider-config/`, `inventory/versions/` | Provider blocks and version pins (services-config and monitoring-config have their own `providers.tf`) |
| `state-encryption.tf` → `inventory/schema/` | State/plan encryption (certs, radius, services-config) |
| `*.secret.auto.tfvars` → `inventory/auto.tfvars.secret/` | Credentials this root needs. Git-ignored. |
| `.terraform/`, `.terraform.lock.hcl` | From `tofu init`. Git-ignored (local provider builds give per-machine checksums). |
| `terraform.tfstate` | State. Git-ignored. Back it up. |

`ls -l roots/<root>/` shows exactly what a root links.

## Deployment order

| # | Root | Builds / configures | Must be ready first | Linked secret files |
| --- | --- | --- | --- | --- |
| 1 | [proxmox-download-files](proxmox-download-files/README.md) | Debian 13 cloud image on `cephfs` (optional) | `cephfs` allows *Import* | `proxmox` |
| 2 | [proxmox-network](proxmox-network/README.md) | NICs, bond, bridges, VLAN interfaces on each cluster node | Console access in case management is cut off | `proxmox` |
| 3 | [proxmox-settings](proxmox-settings/README.md) | Datacenter options, DNS, time zone on every host | Nothing (existing settings are imported) | `proxmox` |
| 4 | [fabric-vms](fabric-vms/README.md) | A `vtep-<host>` VyOS VM per Proxmox host | VyOS image + `vyos_api.yml` snippet on `cephfs`; `vmbr4000`-`vmbr4002` on every host | `proxmox` |
| 5 | [fabric-spines](fabric-spines/README.md) | Loopback, leaf ports, one eBGP session per leaf (underlay + EVPN), BFD on the spines | Spines reachable, REST API on | `routeros` |
| 6 | [fabric-leaves](fabric-leaves/README.md) | EVPN/VXLAN config on every leaf | Leaf VMs booted, HTTPS API on | `vyos`, `radius-clients` |
| 7 | [services-vms](services-vms/README.md) | Every `owner = "services-vms"` VM | Images and host bridges | `proxmox` |
| 8 | [certs](certs/README.md) | Let's Encrypt wildcard (Cloudflare DNS-01), copied to the proxy VMs over SSH | Proxy VMs exist | `cloudflare`, `state` |
| 9 | [services-config](services-config/README.md) | BIND (SSH), DNS records (RFC 2136), DHCP (VyOS API), NetBox, Valkey, dark-triage, nginx (SSH) | Service VMs have Podman + passwordless sudo; fabric routes VLAN 8; certificate on the proxy VMs | `vyos`, `app-db`, `netbox`, `forgejo`, `nextcloud`, `arr`, `state` |
| 10 | [monitoring-config](monitoring-config/README.md) | Prometheus, Alertmanager, exporters, Telegraf, Grafana, Loki, Mimir, Patroni Postgres (SSH); PVE metric servers (API) | Monitoring VMs have Podman + passwordless sudo; zone segments, lylat-telemetry (VLAN 1501) and the `ha_*` L2VNIs on the leaves | `proxmox`, `monitoring`, `logging`, `metrics`, `postgres`, `app-db` |
| 11 | [workloads](workloads/README.md) | Every `owner = "workloads"` VM | Images and host bridges | `proxmox` |

[radius](radius/README.md) (RADIUS users, groups and clients on the rad01/02 pair; linked secrets
`radius`, `state`) is not part of the walk: run it by hand once services-config has deployed
FreeRADIUS. It writes `radius-clients.secret.auto.tfvars`, which fabric-leaves reads for the leaves'
RADIUS login.

Secret file names are `<name>.secret.auto.tfvars`. The SSH roots (Proxmox roots, certs,
services-config, monitoring-config) also read `ssh_private_key_path` (default `~/.ssh/id_rsa`).
monitoring-config's optional secret inputs (`pve_exporter_token`, `snmp_v3_auths`) go in a
git-ignored `*.secret.auto.tfvars`.

Why this order:

- **proxmox-network first**: every VM plugs into its bridges (`vmbr4000` tenant VLANs,
  `vmbr4001`/`vmbr4002` spine links).
- **fabric-vms before fabric-leaves**: a leaf is configured through its running VM's API.
- **fabric-spines and fabric-leaves** apply independently; sessions come up once both sides are done.
- **certs between services-vms and services-config**: the proxy VMs must exist, and nginx expects
  the certificate on first start.
- **services-config after the fabric**: the DNS VMs have no management gateway; they pull the
  BIND image and receive DNS updates through VLAN 8, which the leaves route.
- **proxmox-download-files** only matters for VMs on the stock `debian13` image.

## Running a root

```sh
tooling/walk-roots.sh                               # every root, in order
tooling/walk-roots.sh services-vms services-config  # only these, still in order
tooling/walk-roots.sh --list                        # root names
```

Details: [tooling](../tooling/README.md#walk-rootssh-the-guided-runner). By hand (dev shell sets
`TF_CLI_CONFIG_FILE`; outside it, `export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"`):

```sh
tofu -chdir=roots/services-vms init     # once, and after a provider changes
tofu -chdir=roots/services-vms plan
tofu -chdir=roots/services-vms apply
```

Linked secret files load automatically. With a single central secrets file instead, prefix
commands with `tooling/with-secrets` ([Secrets](../inventory/README.md#secrets)).

## State

- `terraform.tfstate` (+ `.backup`) lives in each root folder, git-ignored.
- It holds secrets in plain text (e.g. generated passwords in monitoring-config). certs, radius and
  services-config state and plans are encrypted with the passphrase in
  `state.secret.auto.tfvars`: keep a copy of the passphrase, or that state is unreadable.
- Lost state: OpenTofu doesn't delete anything, but the next apply tries to create it again.
  Recover with `tofu import`.
- One state per real object. To move one between roots: `tofu state rm` in the old root (forgets,
  doesn't delete), then `tofu import` in the new one.
