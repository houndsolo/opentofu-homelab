# Providers

The three custom providers, built from source (git submodules) instead of downloaded:

| Provider | `source` | Talks to | Used by |
| --- | --- | --- | --- |
| `proxmox` | `local/mechanic/proxmox` | Proxmox VE API (and SSH to the nodes) | proxmox-download-files, proxmox-network, proxmox-settings, fabric-vms, services-vms, monitoring-config, workloads |
| `vyoscmd` | `local/mechanic/vyoscmd` | VyOS HTTPS API | fabric-leaves, services-config |
| `routeros` | `local/mechanic/routeros` | RouterOS REST API | fabric-spines |

| Submodule | Repository |
| --- | --- |
| `terraform-provider-proxmox` | `git@github.com:houndsolo/terraform-provider-proxmox.git` (fork of bpg/proxmox) |
| `terraform-provider-vyoscmd` | `git@github.com:houndsolo/vibecoded-opentofu-vyos-provider.git` (sends lists of VyOS `set` commands: `vyoscmd_commands`) |
| `terraform-provider-routeros` | `git@github.com:houndsolo/terraform-provider-routeros.git` (fork of the community RouterOS provider) |

Versions are pinned in `tooling/provider-manifest.json` and `inventory/versions/*.tf`. Registry
providers (`hashicorp/dns`, `hashicorp/random`, `vancluever/acme`) download normally.

`local/mechanic` isn't a real registry, so OpenTofu never tries to download these; the CLI config
written by `tooling/install-providers` points it at `.tofu-provider-mirror/`. The Git URL and the
source address are independent: switching forks touches no `.tf` file or state.

## Getting the source

```sh
git submodule update --init --recursive
```

`.gitmodules` uses SSH URLs. Without a GitHub SSH key, switch to HTTPS first (private repos still
ask for credentials):

```sh
git config submodule.providers/terraform-provider-proxmox.url  https://github.com/houndsolo/terraform-provider-proxmox.git
git config submodule.providers/terraform-provider-vyoscmd.url  https://github.com/houndsolo/vibecoded-opentofu-vyos-provider.git
git config submodule.providers/terraform-provider-routeros.url https://github.com/houndsolo/terraform-provider-routeros.git
git submodule update --init --recursive
```

## Building

```sh
tooling/build-all            # all three, or name some: tooling/build-all vyoscmd
```

Details: [tooling/](../tooling/README.md#building-the-providers).

## Updating a provider

```sh
git -C providers/terraform-provider-vyoscmd fetch
git -C providers/terraform-provider-vyoscmd checkout <commit-or-tag>
git add providers/terraform-provider-vyoscmd && git commit -m "Update vyoscmd provider"
tooling/build-all vyoscmd
tofu -chdir=roots/fabric-leaves init -upgrade   # in each root that uses it (lock checksum)
```

If the **version number** changes, update every pin:

- `tooling/provider-manifest.json`
- `inventory/versions/pve-versions.tf`, `vyos-versions.tf` or `routeros-versions.tf`
- `roots/services-config/providers.tf` (own `vyoscmd` pin)
- `roots/monitoring-config/providers.tf` (own `proxmox` pin)

`build-providers` warns about uncommitted submodule changes: such a binary can't be reproduced from
the recorded commit.
