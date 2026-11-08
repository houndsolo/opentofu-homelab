# Providers

A **provider** is the plugin OpenTofu uses to talk to an API. This repo builds
three providers from source code, kept here as git submodules, instead of
downloading them from the public registry.

| Provider | Name in the HCL (`source`) | Version | Talks to | Used by |
| --- | --- | --- | --- | --- |
| `proxmox` | `local/mechanic/proxmox` | 0.111.0 | Proxmox VE API (and SSH to the nodes) | proxmox-download-files, proxmox-network, fabric-vms, services-vms, workloads |
| `vyoscmd` | `local/mechanic/vyoscmd` | 0.1.0 | VyOS HTTPS API | fabric-leaves, services-config |
| `routeros` | `local/mechanic/routeros` | 1.99.1 | RouterOS REST API | fabric-spines |

| Submodule folder | Git repository |
| --- | --- |
| `terraform-provider-proxmox` | `git@github.com:houndsolo/terraform-provider-proxmox.git`, a fork of the bpg/proxmox provider |
| `terraform-provider-vyoscmd` | `git@github.com:houndsolo/vibecoded-opentofu-vyos-provider.git`, which sends lists of VyOS `set` commands (`vyoscmd_commands`) |
| `terraform-provider-routeros` | `git@github.com:houndsolo/terraform-provider-routeros.git`, a fork of the community RouterOS provider |

`services-config` also uses two ordinary providers from the public registry,
`hashicorp/dns` and `hashicorp/random`. `tofu init` downloads those as usual.

## Why `local/mechanic/...`?

A provider's `source` address is just the name OpenTofu uses to find it.
`local/mechanic` isn't a real registry, so OpenTofu never tries to download these
three. Instead, the CLI config written by `tooling/install-providers` tells
OpenTofu to look in the local mirror, `.tofu-provider-mirror/`.

The **Git URL** (where the code lives) and the **source address** (what the HCL
calls the provider) are separate settings. You can switch to another fork
without touching any `.tf` file or any state.

## Getting the source

```sh
git submodule update --init --recursive
```

The URLs in `.gitmodules` use SSH, so you need an SSH key on GitHub. If you don't
have one set up, point the submodules at HTTPS before updating. Private
repositories will still ask for credentials.

```sh
git config submodule.providers/terraform-provider-proxmox.url  https://github.com/houndsolo/terraform-provider-proxmox.git
git config submodule.providers/terraform-provider-vyoscmd.url  https://github.com/houndsolo/vibecoded-opentofu-vyos-provider.git
git config submodule.providers/terraform-provider-routeros.url https://github.com/houndsolo/terraform-provider-routeros.git
git submodule update --init --recursive
```

## Building

```sh
nix-shell                  # Go, OpenTofu, Python; also sets TF_CLI_CONFIG_FILE to the mirror config
tooling/build-all          # build and install all three (or name some: tooling/build-all vyoscmd)
# Outside nix-shell, point OpenTofu at the mirror yourself:
# export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
```

[tooling/](../tooling/README.md#building-the-providers) explains what each step
does.

## Updating a provider

```sh
# 1. Move the submodule to the commit you want.
git -C providers/terraform-provider-vyoscmd fetch
git -C providers/terraform-provider-vyoscmd checkout <commit-or-tag>

# 2. Record that commit in this repo. A submodule is stored as a pointer to one commit.
git add providers/terraform-provider-vyoscmd
git commit -m "Update vyoscmd provider"

# 3. Rebuild and reinstall it.
tooling/build-all vyoscmd

# 4. In each root that uses it, refresh the provider checksum in .terraform.lock.hcl.
tofu -chdir=roots/fabric-leaves init -upgrade
```

If the provider's **version number** changes, update it everywhere it's pinned:

- `tooling/provider-manifest.json`
- the matching file in `inventory/versions/`: `pve-versions.tf`,
  `vyos-versions.tf` or `routeros-versions.tf`
- `roots/services-config/providers.tf`, which has its own pin for `vyoscmd`

`tooling/build-providers` prints a warning if a submodule has uncommitted local
changes. A binary built from those can't be reproduced from the recorded commit
alone.
