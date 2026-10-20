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

VNI `roles` select participating leaves. VM `owner` selects the deploying root.
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

Resource/module labels and inventory keys are unchanged; these renames do not
require state moves. Credential variable names are unchanged.

## Secrets

Keep the central, ignored file at
`inventory/auto.tfvars/passwords.secret.auto.tfvars`. Run inside `nix-shell`:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
```

The wrapper exports `TF_VAR_*` only to its child process. Undeclared environment
variables are ignored, avoiding shared-tfvars warnings. It preserves value types;
null entries unset their environment variable. Normal tfvars/CLI precedence applies.
There is no per-variable warning filter; `-compact-warnings` only shortens output.

Remove root symlinks to the secrets file once, so it is not also auto-loaded:

```sh
test -L roots/services-config/passwords.secret.auto.tfvars &&
  unlink roots/services-config/passwords.secret.auto.tfvars
```

Repeat for other roots with that link; retain the central target. The wrapper
reports remaining links without removing them. `--file PATH` selects another
secrets file. The guided runner uses the wrapper automatically when the central
file exists, or accepts `--no-secrets` for existing environment credentials.

`ssh_keys` has no tracked consumer. Public keys use `local.ssh_pubkeys` and VM
`config.ssh_pubkeys = ["laptop", "desktop"]`. Never store private keys in Git.
