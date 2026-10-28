# Tooling

Run from `nix-shell`. Provider configuration should use the generated filesystem
mirror so `init` can resolve the local providers:

```sh
tooling/build-all
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
```

`build-all [proxmox vyoscmd routeros]` builds/installs all or selected providers.
`build-providers` and `install-providers` run those stages separately.

## Guided roots

```sh
tooling/walk-roots.sh
tooling/walk-roots.sh services-vms services-config
tooling/walk-roots.sh --list
```

Select plan, apply, skip (default), or quit at each root. Apply first initializes,
validates and saves a plan; type `yes` to apply that exact plan. A failed command
stops the walk. Private temporary plan files are deleted on exit.

The services-config bootstrap option targets only BIND deployment. Use it once
before the first full apply, then choose normal apply for DNS records and DHCP.
The runner excludes the unfinished settings and empty virtual-host roots.
Selected roots still run in dependency order; dependencies are not auto-selected.
It does not apply anything merely by starting it.

Roots that link the passwords file run `tofu` directly and auto-load it. Other
roots use `with-secrets` when the central file exists
([secrets setup](../inventory/README.md#secrets)). Use `--no-secrets` for
existing environment credentials. `TOFU_BIN` selects the
executable; `TF_VAR_*` supplies inputs, for example:

```sh
TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519 tooling/walk-roots.sh services-config
```

For individual commands:

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
```

`routeros-spine-imports.py` and `tofu_import_stuff.sh` are import helpers; inspect
their host/resource mappings before use.
