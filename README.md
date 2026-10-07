# OpenTofu homelab

Proxmox infrastructure and a VyOS EVPN/VXLAN fabric.

| Directory | Purpose |
| --- | --- |
| inventory/ | Shared values, variable definitions and provider configuration |
| roots/ | Separate OpenTofu configurations |
| modules/ | Reusable modules |
| providers/ | Provider source submodules |
| tooling/ | Provider build and installation scripts |

## Setup

Run from the repository directory:

```sh
git submodule update --init --recursive
nix-shell
tooling/build-all proxmox vyoscmd
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
```

## Usage

Edit the shared inventory, then select a root:

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms plan
tofu -chdir=roots/fabric-vms apply
```

Review the plan before applying. Each root has separate state.

## Order to run roots

### Proxmox Hypervisor settings/network settings
```sh
tofu -chdir=roots/proxmox-settings apply
tofu -chdir=roots/proxmox-network apply
```

### EVPN-VxLAN fabric. Proxmox VTEP VM creation, Spine & Leaf configuration

```sh
tofu -chdir=roots/fabric-vms apply
tofu -chdir=roots/fabric-leaves apply
tofu -chdir=roots/fabric-spines apply
```

### Network service VMs, (DNS, DHCP, NTP, etc)

```sh
tofu -chdir=roots/network-services apply
```

### VMs and LXCs

```sh
tofu -chdir=roots/proxmox-virtual-hosts
```
