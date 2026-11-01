# Roots

A **root** is a folder that you run `tofu` in. Each folder here deploys one
layer of the lab and keeps its **own state file**.

## Why the lab is split into roots

- **Plans stay small** enough to read properly before you apply them.
- **Layers are isolated.** A mistake in one layer can't plan the destruction of
  another.
- **Access is limited.** Each root only needs the credentials and network
  reachability for its own layer.
- **Re-runs are cheap.** You can re-run just the layer you changed.

The roots don't read each other's state (there's no `terraform_remote_state`).
The only thing they share is the [inventory](../inventory/README.md), which
every root reads through symlinks. So the deployment order below isn't enforced
by OpenTofu. It reflects real-world readiness: for example, a leaf can't be
configured until its VM has booted and its API answers.

## What's in a root folder

| File | What it is |
| --- | --- |
| `main.tf`, `locals.tf`, ... | The root's own code. Mostly calls to [modules](../modules/README.md). |
| `*.auto.tfvars` → `inventory/auto.tfvars/` | Symlinks to the values |
| `*.variables.tf` → `inventory/schema/` | Symlinks to the variable declarations |
| `providers.tf`, `versions.tf` → `inventory/...` | Symlinks to the provider settings and version pins |
| `.terraform/` | Created by `tofu init`: the providers and modules this root uses. Git-ignored. |
| `.terraform.lock.hcl` | Created by `tofu init`: checksums of the providers in use. Git-ignored, because locally built providers get different checksums on every machine. |
| `terraform.tfstate` | Created by `tofu apply`: the state. Git-ignored. **Back it up.** |

## Deployment order

| # | Root | What it builds or configures | Must be ready first | Credentials it uses |
| --- | --- | --- | --- | --- |
| 1 | [proxmox-download-files](proxmox-download-files/README.md) | The Debian 13 cloud image on `cephfs` (optional) | `cephfs` storage allows *Import* content | `pve_api_token`, `greatfox_api_token` |
| 2 | [proxmox-network](proxmox-network/README.md) | NICs, bond, bridges and VLAN interfaces on each cluster node | Console access to the hosts, in case a change cuts off management | Proxmox tokens |
| 3 | [fabric-vms](fabric-vms/README.md) | A `vtep-<host>` VyOS VM on every Proxmox host | VyOS image and `vyos_api.yml` snippet on `cephfs`; bridges `vmbr4000`–`vmbr4002` on every host | Proxmox tokens |
| 4 | [fabric-spines](fabric-spines/README.md) | BGP, BFD and EVPN route reflection on the RouterOS spines | Spines reachable, REST API enabled | `routeros_password` (and `routeros_username`, default `admin`) |
| 5 | [fabric-leaves](fabric-leaves/README.md) | The EVPN/VXLAN config on every leaf | Leaf VMs booted with their HTTPS API enabled | `vyos_api_key` |
| 6 | [services-vms](services-vms/README.md) | The DNS and DHCP VMs | Images and host bridges exist | Proxmox tokens |
| 7 | [services-config](services-config/README.md) | BIND (over SSH), DNS records (RFC 2136), DHCP HA and pools (VyOS API) | DNS VMs have Podman and passwordless sudo; the fabric routes VLAN 8 | `ssh_private_key_path`, `vyos_api_key` |
| 8 | [workloads](workloads/README.md) | Ordinary VMs (`owner = "workloads"`) | Images and host bridges exist | Proxmox tokens |

Why this order:

- **`proxmox-network` comes first**, because every VM plugs into its bridges.
  `vmbr4000` carries the tenant VLANs, and `vmbr4001`/`vmbr4002` are the links to
  the spines.
- **`fabric-vms` comes before `fabric-leaves`**, because OpenTofu can only
  configure a leaf VM after it exists and is running.
- **`fabric-spines` and `fabric-leaves`** can each be applied on their own. The
  BGP sessions come up once both sides are configured.
- **`services-config` comes after `services-vms` and after the fabric.** The DNS
  VMs have no management gateway: they reach the internet (to pull the BIND
  image) and receive DNS updates through VLAN 8, which the leaves route.
- **`proxmox-download-files`** only matters if your VMs use the stock `debian13`
  image, and it must run before the roots that create those VMs.

## Running a root

### With the guided runner

```sh
tooling/walk-roots.sh                               # every root, in the order above
tooling/walk-roots.sh services-vms services-config  # only these, still in that order
tooling/walk-roots.sh --list                        # print the root names
```

At each root you choose plan, apply, skip or quit. Details are in
[tooling](../tooling/README.md#walk-rootssh-the-guided-runner).

### By hand

```sh
# Set this first, so OpenTofu finds the locally built providers.
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"

# init: prepare the providers and modules. Run it once per root, and again
# after a provider changes.
tooling/with-secrets tofu -chdir=roots/services-vms init

# plan: preview the changes. Nothing is modified.
tooling/with-secrets tofu -chdir=roots/services-vms plan

# apply: shows the plan again, then asks you to type "yes" before changing anything.
tooling/with-secrets tofu -chdir=roots/services-vms apply
```

`-chdir=roots/<name>` runs `tofu` as if you had `cd`'d into that folder.
`tooling/with-secrets` supplies the credentials. Alternatively, link the secrets
file into the root and run plain `tofu`; see
[Secrets](../inventory/README.md#two-ways-to-give-a-root-its-secrets).

## State

- **Where it lives.** Each root keeps `terraform.tfstate` in its own folder, and
  OpenTofu keeps the previous version as `terraform.tfstate.backup`. Git ignores
  both.
- **It's sensitive.** State holds some secrets in plain text, such as the
  generated TSIG key in `services-config`. Keep it private, and copy it somewhere
  safe regularly.
- **If you lose it,** OpenTofu no longer knows it manages those objects. It
  won't delete them, but the next apply will try to create them again, which
  usually fails or makes duplicates. You recover with `tofu import`.
- **One owner per object.** Every real object should be managed by exactly one
  state. To move one between roots, run `tofu state rm` in the old root (this
  only makes OpenTofu forget the object; it doesn't delete it), then `tofu import`
  in the new root. [proxmox-download-files](proxmox-download-files/README.md#moving-the-image-from-an-older-services-vms-state)
  has a worked example.

## Unfinished roots

Two roots aren't usable yet, and the runner refuses to run them:

| Root | State |
| --- | --- |
| `proxmox-settings` | Meant to manage a Proxmox InfluxDB metrics server through `modules/proxmox/settings`. The module reads `var.influxdb`, which isn't declared anywhere, so the root doesn't validate. |
| `proxmox-virtual-hosts` | An empty `main.tf` |
