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
Edit `inventory/auto.tfvars/vms.auto.tfvars` to set each VM's node, ID,
image, and any overrides. Shared defaults are already loaded from
`inventory/auto.tfvars/vm-config.auto.tfvars`; no extra VM settings file is needed.

Check that the Debian 13 and VyOS image IDs in `vm_images` match files
in your Proxmox storage. This root imports existing images; it does not
fetch them. The Debian path is `cephfs:import/debian-13-genericcloud-amd64.qcow2`.
The starter DNS and DHCP VMs use node `venom` and IDs 301 and 302.
Check these IDs before applying.

Supply `pve_api_token` and `gf_api_token` in your private variable file,
or use `TF_VAR_pve_api_token` and `TF_VAR_gf_api_token`.
The shared provider configuration requires both tokens.
Set `ssh_private_key_path` if the default `~/.ssh/id_rsa` is incorrect.
Keep credentials outside tracked inventory files. For unrelated shared
credentials such as `vyos_api_key` and `ssh_keys`, use `TF_VAR_...`
environment variables to avoid warnings from roots that do not declare them.

Remove any old local `vm_config` assignment made from the previous example.
It would replace the shared inventory assignment.

```sh
tofu -chdir=roots/services-vms init
tofu -chdir=roots/services-vms validate
tofu -chdir=roots/services-vms plan
tofu -chdir=roots/services-vms apply
tofu -chdir=roots/services-vms output vms
```

The service VM default is `started = false`. Use a per-VM override to start
a guest. Generated VTEPs retain `started = true`. Start the VMs and check service API access before
you apply service configuration. A DHCP management address in the outputs
is the configured value `dhcp`, not the assigned IP address.

### Shared VM defaults and overrides

All VM roots call `modules/proxmox/vm`. Its `defaults` submodule resolves
shared defaults and per-VM overrides. There is no separate `pve_leaf`
hardware configuration.

| File | Purpose |
| --- | --- |
| `inventory/auto.tfvars/vm-config.auto.tfvars` | Shared storage and hardware defaults, plus named images |
| `inventory/schema/vm-config.tf` | Available shared settings and built-in defaults |
| `inventory/auto.tfvars/vms.auto.tfvars` | VM placement, image selection, and per-VM overrides |
| `inventory/auto.tfvars/fabric-vms.auto.tfvars` | VTEP naming, generated IDs, addresses, and NIC layout |

Settings apply in this order: shared defaults, selected image settings,
short per-VM fields (`cores`, `memory_mb`, `bridge`, `started`, `tags`),
then `config`. A later value overrides an earlier value.
Omitted or null override values inherit the previous value. False, zero,
and empty lists are explicit overrides. Lists are replaced as a whole.
An image selection can clear a shared cloud-init snippet; Debian has no
VyOS snippet. `cloud_init = false` disables cloud-init for a VM.

For example, edit the `dns01` entry:

```hcl
dns01 = {
  owner = "services-vms"
  node  = "venom"
  vm_id = 301
  image = "debian13"
  cores = 2
  memory_mb = 2048
  config = {
    disk_size_gb = 20
    started      = true
  }
}
```

Use `image = "vyos"` for DHCP VMs. The supplied DHCP entry creates a
VyOS guest with the existing API cloud-init snippet. DHCP scopes and
interfaces still require service configuration.

VTEPs are generated from the node inventory. To override one, add an entry
with its generated hostname to the same `vms` map:

```hcl
vtep-venom = {
  owner = "fabric-vms"
  config = {
    cpu_cores    = 2
    memory_mb    = 2048
    disk_size_gb = 20
  }
}
```

This entry changes the existing VTEP. It does not create a second VM.
Unspecified node, ID, management address, and NICs retain generated values.
Future VMs use the same `vms` map and module.
VTEP entries must use `owner = "fabric-vms"`.

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan -input=false

tofu -chdir=roots/services-vms plan -input=false
```

VM resource addresses remain unchanged. No state move is required for
this defaults change. Review plans before applying; changing an image,
node, or ID can cause replacement or other provider-managed changes.

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

## Check VM defaults

This check needs OpenTofu, but does not need Proxmox access or a provider binary:

```sh
tofu -chdir=modules/proxmox/vm/defaults init
tofu -chdir=modules/proxmox/vm/defaults test
```
