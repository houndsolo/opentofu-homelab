# Inventory

Shared configuration used by the roots.

| Directory | Contents |
| --- | --- |
| auto.tfvars/ | Configuration values |
| schema/ | Variable types, defaults and validation |
| provider-config/ | Provider configuration and credential variables |
| versions/ | Provider requirements |

## Main value files

| File | Purpose |
| --- | --- |
| nodes.auto.tfvars | Proxmox nodes and stable IDs |
| fabric.auto.tfvars | Fabric members, addressing and MTUs |
| fabric-vms.auto.tfvars | VTEP naming, addresses and NIC generation |
| vm-config.auto.tfvars | Shared VM defaults and named Debian/VyOS images |
| pve-network.auto.tfvars | Proxmox host networking |
| vnis.auto.tfvars | VRFs, L2/L3 VNIs, gateways and route targets |
| vms.auto.tfvars | General VM definitions |

Edit values here. Roots and modules use relative symlinks to the shared files.

A VNI's `roles` select the leaves that receive its VRF and nested L2VNIs.
Route targets are explicit values; changing the overlay AS does not update them.

Keep credentials outside tracked inventory files. Use environment variables
or private variable files.

`schema/vm-config.tf` defines the shared VM settings used by the VM module
and all VM roots. `schema/vm.tf` contains the single-VM object used by
the VM module and its defaults helper. Service VM owners include
`services-vms-dns` and `services-vms-dhcp`.

## One shared secrets file without undeclared-variable warnings

OpenTofu has no per-variable warning ignore list. An auto-loaded tfvars file
warns when a root does not declare every supplied key. `-compact-warnings`
shortens warnings; it does not suppress this category. Do not add unused dummy
variable declarations to every root just to silence the warnings.

Keep your one existing file at:

```text
inventory/auto.tfvars/passwords.secret.auto.tfvars
```

Run the wrapper from the repository directory inside `nix-shell`:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
tooling/with-secrets tofu -chdir=roots/services-config apply
```

The wrapper loads that file as `TF_VAR_<name>` environment variables for the
child command. Roots consume only variables they declare; extra environment
settings are ignored without these warnings. Strings and complex values are
decoded by a temporary, provider-free OpenTofu configuration, not by shell eval.
The wrapper prints no secret values or parser diagnostics containing them.
Null entries unset the corresponding environment setting, allowing defaults.
Normal tfvars and `-var` command-line precedence still apply over environment
values. The existing `TF_CLI_CONFIG_FILE` provider-mirror selection is preserved
for your actual command.

Remove any symlink to that shared file from each root first, otherwise OpenTofu
will still auto-load it. For example, after confirming this is a symlink:

```sh
test -L roots/services-config/passwords.secret.auto.tfvars && \
  unlink roots/services-config/passwords.secret.auto.tfvars
```

`unlink` removes only the link; keep the central secrets file. The wrapper also
checks for an auto-loaded link and reports it rather than modifying it.
Override the source path with `--file /path/to/secrets.tfvars` before the command.
It requires OpenTofu/Terraform and python-hcl2, already included in `nix-shell`.

The old `ssh_keys` setting has no consumer in the tracked configuration. VM SSH
keys come from `inventory/ssh_pubkeys.tf` and each VM's `config.ssh_pubkeys`.
Remove that old secret-file entry if nothing outside this repo uses it; the
wrapper can also leave it present harmlessly as an unused environment setting.
