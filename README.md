# OpenTofu homelab

Proxmox VMs and host networking, a VyOS/RouterOS EVPN fabric, and BIND/DHCP services.

```sh
git submodule update --init --recursive
nix-shell
tooling/build-all
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
tooling/walk-roots.sh
```

Edit [inventory](inventory/README.md) first. The Bash runner walks the usable
[roots](roots/README.md) in dependency order, offering plan, apply, skip and quit.
It reviews a saved plan before applying it and offers a separate first-time DNS
bootstrap. Each root keeps its own state; retain and back up those state files.

| Directory | Purpose |
| --- | --- |
| [inventory/](inventory/README.md) | Values, schemas, public keys and provider configuration |
| [roots/](roots/README.md) | Deployable configurations, each with separate state |
| [modules/](modules/README.md) | Shared VM, network and service logic |
| providers/ | Provider source submodules |
| [tooling/](tooling/README.md) | Provider builds, secrets wrapper and guided runner |

For a single root: `tooling/walk-roots.sh services-config`.
For direct commands and shared credentials, see [secrets setup](inventory/README.md#secrets).
