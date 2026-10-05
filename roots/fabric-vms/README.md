# Fabric leaf VMs

This root creates the Proxmox leaf VMs through `modules/proxmox/vm`, following the
VM creation pattern in
[houndsolo/vyos_vxlan_homelab](https://github.com/houndsolo/vyos_vxlan_homelab/tree/1d9cbdf2a5b2b15d2deac71e2c652f3f136d69e2/create_fabric_vms).
It has its own local state and owns only its configured leaf VMs.

Edit `inventory/auto.tfvars/pve-leaf.auto.tfvars`. This root's
`pve-leaf.auto.tfvars` is a relative symlink to that file; preserve the link.
The typed input is named **`pve_leaf`** and replaces `proxmox_vtep_vm`.
Everything needed to describe leaf creation is in that one input:

| Section | Purpose |
| --- | --- |
| `proxmox` | Endpoint, TLS verification setting and SSH username/agent settings |
| `defaults` | Hostname prefix, VM ID offset, address derivation and underlay bridges/MAC seed |
| `vm_config` | Shared VM resource settings, including image, disk, CPU, memory, cloud-init, console and timeouts |
| `leaves` | Managed leaf instances and per-leaf overrides |

The example creates seven VMs, one per named Proxmox host. Only leaves with
`is_vm = true` are managed. The root does not iterate over the unrelated `nodes`
variable or mix in workload/service VM definitions.

For each leaf, defaults produce:

- Hostname: `vtep-<inventory key>`.
- VM ID: `id + 700`.
- Management IPv4: `cidrhost("10.20.10.0/24", id)` with prefix length `/16`.
- First NIC: the management bridge from `vm_config`.
- Remaining NICs: `vmbr4001`, `vmbr4002`, `vmbr4000`, in that order.
- Stable MACs: the reference's formula using AS base, leaf ID and interface index.

For example, `fichina` with ID `11` becomes `vtep-fichina`, VM `711`, address
`10.20.10.11/16`, and eth1 MAC `02:07:11:00:11:01`.

A leaf can override its identity, startup, tags, hardware and networking:

```hcl
leaves = {
  fichina = {
    hypervisor_node    = "fichina"
    id                 = 11
    vm_id              = 811
    hostname           = "custom-leaf"
    management_address = "10.20.10.111" # Bare IPv4; the root appends management_cidr.
    gateway            = "10.20.0.1"
    started            = false
    cores              = 2
    memory_mb          = 2048
    underlay_bridges   = ["vmbr4001", "vmbr4002"]
    fabric_macs        = { eth1 = "02:aa:bb:cc:dd:01" }
  }
}
```

Unset MACs are generated. For complete NIC control, supply `network_devices`
instead of `underlay_bridges`; each NIC supports bridge, VLAN, MAC, model, MTU
and disconnected state. An explicit empty list creates only the management NIC.
VM IDs must be unique among managed leaves and across other roots in the cluster.

## Run

Configure `PROXMOX_VE_API_TOKEN` or the sensitive `TF_VAR_pve_api_token` securely.
For image-import SSH, use an agent or set `TF_VAR_ssh_private_key_path` to an
existing key. Credentials are not stored in `pve-leaf.auto.tfvars`.
The configured endpoint must be reachable and its TLS certificate trusted.

After building and installing this repository's local provider, run from the
repository checkout:

```sh
tofu -chdir=roots/fabric-vms init
tofu -chdir=roots/fabric-vms validate
tofu -chdir=roots/fabric-vms plan
```

Use the local provider mirror CLI configuration prepared by the setup workflow.
The image and cloud-init snippet referenced in the inventory must already exist.
`leaf_vms` outputs the resulting identities and ordered extra NIC layout.

`tofu -chdir=roots/fabric-vms test` runs mocked, plan-only tests using the example
inventory. They cover the reference layout, overrides, physical-leaf filtering
and duplicate-ID rejection. These checks do not establish live Proxmox access.
