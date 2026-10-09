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

## Service VMs and configuration

`roots/services-vms` creates the service VMs and manages cloud-init.
It selects entries with `owner = "services-vms"` from
`inventory/auto.tfvars/vms.auto.tfvars`.

`roots/services-config` is reserved for configuration through service APIs.
It currently has no managed resources. Add providers and resources there
when you implement a service. Each root has separate state.

### Create service VMs

Run from the repository directory after the setup commands above.
Set each service VM's node, ID, CPU, RAM and bridge in the shared inventory.
Replace the starter node `pve01` with an actual Proxmox node.

Create the local settings file:

```sh
cp examples/services-vms.tfvars roots/services-vms/settings.secret.auto.tfvars
```

Edit that file. Set the datastore and the existing cloud image ID.
Add `pve_api_token` and `gf_api_token`, or supply them with
`TF_VAR_pve_api_token` and `TF_VAR_gf_api_token`.
The shared provider configuration requires both tokens.
Set `ssh_private_key_path` if the default `~/.ssh/id_rsa` is incorrect.
The `*.secret.auto.tfvars` file is ignored by Git.

```sh
tofu -chdir=roots/services-vms init
tofu -chdir=roots/services-vms validate
tofu -chdir=roots/services-vms plan
tofu -chdir=roots/services-vms apply
tofu -chdir=roots/services-vms output vms
```

The VM module starts guests only when `vm_config.started = true`.
Its default is false. Start the VMs and check service API access before
you apply service configuration. A DHCP management address in the outputs
is the configured value `dhcp`, not the assigned IP address.

### Configure services

After you add service providers, resources and their required inputs:

```sh
tofu -chdir=roots/services-config init
tofu -chdir=roots/services-config validate
tofu -chdir=roots/services-config plan
tofu -chdir=roots/services-config apply
```

These commands make no resource changes while this root is a placeholder.
The roots do not automatically apply each other or wait for service readiness.

### Existing network-services state

If you already applied `roots/network-services`, move its local state
before you plan or apply `services-vms`. The `module.vm` name and VM map
keys are unchanged, so resource addresses stay the same.

Run these commands once, only if the old local state exists and the new
root has no state. Stop all OpenTofu operations first.

```sh
test -f roots/network-services/terraform.tfstate
test ! -e roots/services-vms/terraform.tfstate
cp roots/network-services/terraform.tfstate roots/network-services/terraform.tfstate.before-services-split
mv -n roots/network-services/terraform.tfstate roots/services-vms/terraform.tfstate
```

Run each check successfully before the next command.
If you used non-default workspaces, also move `terraform.tfstate.d`
after checking that the destination does not exist.
Move any private variable files you still need to the new VM root.
Do not copy the old `.terraform` directory; run `init` in the new root.

For remote state, configure the new VM root to use the existing backend
and state key. The configuration root must use the state that already owns
the VMs. Do not apply an empty VM state to existing VMs.
