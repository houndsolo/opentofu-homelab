# Inventory

Edit values in `auto.tfvars/`. Roots link to these files and their `schema/`
declarations; providers and version constraints live in `provider-config/` and
`versions/`. `ssh_pubkeys.tf` holds the named public-key registry.

| Value file | Purpose |
| --- | --- |
| nodes.auto.tfvars | Proxmox hosts and stable node IDs |
| fabric.auto.tfvars | Leaves, spines, addressing and MTUs |
| fabric-vms.auto.tfvars | Fabric VM naming, addresses and ordered bridges |
| pve-network.auto.tfvars | Host networking |
| vm-config.auto.tfvars | VM defaults and named images |
| vms.auto.tfvars | VM owners, placement, NICs and overrides |
| vnis.auto.tfvars | VRFs, VNIs, gateways, route targets and DHCP scopes |
| dns-records.auto.tfvars | Custom DNS records |

VNI `roles` select participating leaves. VM `owner` (`fabric-vms`, `services-vms`
or `workloads`) selects the deploying root; `role` (`dns` or `dhcp`) selects the
service. Set `standalone = true` on the one Proxmox host outside the cluster.
Route targets are explicit; changing an AS does not rewrite them.

## Naming

Use `snake_case`, plural names for collections, and familiar network terms
(`ip`, `vlan`, `vni`, `mac`). Use `management` consistently. A network `prefix`
is a CIDR string; `prefix_length` is a number. Keep provider field names intact.

This cleanup renames the following inputs; tracked inventory and callers are
updated together. Update any private override files using the old names:

| Old | New |
| --- | --- |
| fabric.settings.vyos_mgmt_prefix | management_prefix |
| fabric.settings.vyos_mgmt_cidr | management_prefix_length |
| fabric_vms.management_cidr | management_prefix_length |
| fabric_vms.default_underlay_bridges | underlay_bridges |
| fabric.spines[*].uplink_if | uplink_interface |
| VNI border_leaf_ipv4_vpn_import_bool | import_ipv4_vpn |
| VNI border_leaf_ipv4_vrf_imports | import_ipv4_vrfs |
| VM module configure_data_nic_ips | configure_data_ips |
| DHCP module dhcp_ha_subnet | ha_subnet |
| local.ssh_pubkey | local.ssh_pubkeys |
| fabric.settings.bgp_system_as | leaf_underlay_as_base |
| fabric.overlay_as | fabric.settings.overlay_as |
| fabric_vms.management_prefix, management_prefix_length | removed; uses fabric.settings.management_* |
| nodes.proxmox_cluster + nodes.proxmox | nodes.proxmox, with standalone = true on greatfox |
| (hardcoded 10.20.7.0/24, cluster API URL) | nodes.management_prefix, nodes.cluster_api_node |
| VM cores, memory_mb, bridge, started, tags | config.cpu_cores, memory_mb, management_bridge, started, tags |
| owner services-vms-dns / services-vms-dhcp | owner = "services-vms" with role = "dns" / "dhcp" |
| VM owner default "services-vms" | owner is required |
| gf_api_token | greatfox_api_token |
| DHCP module ha_subnet, fabric_macs | ha_prefix, interface_macs |
| DHCP MAC module dhcp_vlans input | vnis (selects DHCP VLANs itself) |

Module and inventory keys are unchanged. Two spine resources were renamed
(`BGP-LOOPBACKS` → `bgp_loopbacks`, `test` → `leaf_uplinks`); `moved` blocks
migrate their state on the next plan. Rename `gf_api_token` in your secrets file.

## Secrets

Credentials live in one central file,
`inventory/auto.tfvars/passwords.secret.auto.tfvars`, kept only on the machine
that runs OpenTofu (an editing checkout needs none). Keep the
`.secret.auto.tfvars` suffix: OpenTofu auto-loads only `*.auto.tfvars`, and
`.gitignore` ignores `*.secret.auto.tfvars` and `*.secret.tfvars`. See
[the example](../examples/auto.tfvars/passwords.example.auto.tfvars).
Supply it to roots in either of two ways.

**Root symlinks.** Link the central file into each root that needs credentials:

```sh
ln -s ../../inventory/auto.tfvars/passwords.secret.auto.tfvars roots/services-config/
```

Plain `tofu` then auto-loads it. Roots that do not declare every variable in the
file print undeclared-variable warnings; they are harmless, and
`-compact-warnings` shortens them.

**Wrapper.** Without links, run commands through the wrapper inside `nix-shell`:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
```

It exports `TF_VAR_*` only to its child process, so undeclared variables are
ignored without warnings. It preserves value types; null entries unset their
environment variable. Normal tfvars/CLI precedence applies. `--file PATH` selects
another secrets file. It refuses a root that also links the file, since that
root already auto-loads it; use plain `tofu` there.

The guided runner chooses per root: a root linking a `*.secret.auto.tfvars` file
runs `tofu` directly, and other roots use the wrapper when the central file
exists. `--no-secrets` disables the wrapper for existing environment credentials.

`ssh_keys` has no tracked consumer. Public keys use `local.ssh_pubkeys` and VM
`config.ssh_pubkeys = ["laptop", "desktop"]`. Never store private keys in Git.
