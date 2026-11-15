# Tooling

Run from the top of the repo, in the dev shell (direnv or `nix-shell`).

| File | What it is |
| --- | --- |
| `build-all` | Build and install the custom providers (`build-providers` + `install-providers`) |
| `provider-manifest.json` | Source address and version of each custom provider |
| `local-provider.tfrc` → `.generated.tfrc` | CLI config: local mirror for `local/mechanic/*`. `TF_CLI_CONFIG_FILE` points at the generated file. |
| `dev.tfrc` → `.generated.tfrc` | CLI config with `dev_overrides`, for provider development only |
| `build-shell.nix` | Go shell for the provider builds |
| `walk-roots.sh` | Guided plan/apply across the roots, in deployment order |
| `with-secrets` | Run a command with one central secrets file loaded as `TF_VAR_*` |
| `routeros-spine-imports.py` | Import existing spine objects into state |
| `tofu_import_stuff.sh` | Import existing Proxmox host networking into state |
| `tests/` | Unit tests for `walk-roots.sh`, `with-secrets` and the VM schema files |

## The development shell

`shell.nix` (loaded by direnv via `.envrc`, cached by nix-direnv in `.direnv/`; or `nix-shell`)
provides OpenTofu >= 1.13.0, Python 3 with `python-hcl2` >= 7.3.1 (for `with-secrets`), git, and
`TF_CLI_CONFIG_FILE=tooling/local-provider.generated.tfrc`. Non-interactive: `direnv exec . tofu ...`.

- OpenTofu comes from `<nixpkgs-unstable>` when on `NIX_PATH` (a0-nix sets it; stable ships
  1.11.x), else `<nixpkgs>`. Python and git come from `<nixpkgs>`. Too-old versions stop the
  shell with a message; override for one run with
  `nix-shell -I nixpkgs=https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz`.
- Startup: `<nixpkgs>` should resolve to a store path (`NIX_PATH=nixpkgs=/nix/store/...`). With
  NixOS's default `nixpkgs=flake:nixpkgs` every lookup re-hashes nixpkgs (~4 s); a0-nix pins it
  with `nix.nixPath`.
- Go (>= 1.26, `GOTOOLCHAIN=local`, `CGO_ENABLED=0`) is only in `build-shell.nix`;
  `build-providers`/`build-all` re-run themselves there when Go isn't on PATH.
- Without Nix: install the same tools (`pip install 'python-hcl2>=7.3.1'`).

## Building the providers

```sh
tooling/build-all                    # all three
tooling/build-all proxmox vyoscmd    # only these
```

1. **`build-providers`**: copies each submodule's source to a temp dir (the submodule is never
   modified), runs `go build -mod=mod -trimpath`, writes the binary and a `.build.json` (commit,
   dirty flag, platform, version) to `.provider-build/<platform>/`. Warns on uncommitted submodule
   changes; stops if a submodule isn't checked out.
2. **`install-providers`**: installs nothing unless every selected binary exists; copies them into
   the mirror and writes both `*.generated.tfrc` files.

```text
.tofu-provider-mirror/local/mechanic/        <- source = "local/mechanic/<name>"
├── proxmox/<version>/linux_amd64/{terraform-provider-proxmox_v<version>, build.json}
├── vyoscmd/<version>/linux_amd64/...
└── routeros/<version>/linux_amd64/...
```

Versions: `provider-manifest.json`. `.provider-build/` and `.tofu-provider-mirror/` are git-ignored.

### CLI config

Outside the dev shell: `export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"`.

| File | Use | Behaviour |
| --- | --- | --- |
| `local-provider.generated.tfrc` | Normal | `filesystem_mirror` for `local/mechanic/*`; everything else from the registry. `tofu init` and lock files work as usual. |
| `dev.generated.tfrc` | Provider development | `dev_overrides`: loads binaries straight from the mirror, skips version/checksum checks, warns on every command |

The generated files hold absolute paths and are rewritten on every install, so the committed
copies may show as modified after a build. The templates use placeholders (`@MIRROR@`).

### Lock file checksums

The checksum in `.terraform.lock.hcl` covers `build.json` (which includes the commit), so a rebuild
can change it and no two machines agree: lock files are git-ignored. On a mismatch:
`tofu -chdir=roots/<root> init -upgrade`.

## walk-roots.sh: the guided runner

```text
tooling/walk-roots.sh [--no-secrets] [--list] [ROOT ...]
```

| Option | Effect |
| --- | --- |
| *(no roots)* / `ROOT ...` | Walk every usable root / only these, always in deployment order |
| `--list` | Print the root names |
| `--no-secrets` | Don't use `with-secrets`; use exported `TF_VAR_*` (linked secret files still auto-load) |
| `TOFU_BIN=...` | OpenTofu executable (default `tofu`) |

Per root it prints a reminder, then `[p]lan, [a]pply, [s]kip (default), [q]uit` (services-config
adds `[b]ootstrap DNS`):

| Choice | What happens |
| --- | --- |
| `p` | `init`, `validate`, `plan`. Changes nothing. |
| `a` | `init`, `validate`, `plan` to a private temp file; if there are changes, asks `Type yes:` and applies exactly that plan |
| `s` / Enter | Skip |
| `q` | Stop |
| `b` | services-config only: [DNS bootstrap](../roots/services-config/README.md#first-deployment-bootstrap-first), like `a` with `-target=terraform_data.bind9`; then asks again for the normal apply |

- Naming a root does **not** add the roots it depends on.
- Any failing command stops the walk before later roots.
- No changes → no question. Plan files (may contain secrets) are deleted after use and on exit.
- Roots with a linked `*.secret.auto.tfvars` run plain `tofu`; others go through `with-secrets`
  if `inventory/auto.tfvars/passwords.secret.auto.tfvars` exists.
- Only runs `tofu`: doesn't create images, APIs or credentials.
- `proxmox-virtual-hosts` isn't in its list; naming it exits 2.

## with-secrets

The alternative to per-provider links: all secrets in one file.

```text
tooling/with-secrets [--file PATH] [--tofu PATH] [--] COMMAND [ARGS...]
```

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
tooling/with-secrets --file ~/other-lab.tfvars tofu -chdir=roots/workloads plan
tooling/with-secrets python3 tooling/routeros-spine-imports.py --import   # any command
```

1. Reads only the variable **names** from the file (default
   `inventory/auto.tfvars/passwords.secret.auto.tfvars`) with `python-hcl2`.
2. Has OpenTofu decode the values (`tofu console` in an empty temp dir), so types and escaping
   match what OpenTofu sees.
3. Runs the command with `TF_VAR_<name>` per value (strings as-is, other types as JSON, `null`
   unsets).

Refuses a root (from `-chdir` or the cwd) that links the same file (`... already auto-loads the
shared secrets; run tofu without with-secrets`). Never prints values, even on a parse error;
variables exist only for the child. See also
[inventory/README.md](../inventory/README.md#the-alternative-one-file-and-the-wrapper).

## Import helpers

Not executable; run through the interpreter. Both have hard-coded assumptions (the spine script's
object names, the import script's node/interface lists): read them first.

| Script | Run | Details |
| --- | --- | --- |
| `routeros-spine-imports.py` | `python3 tooling/routeros-spine-imports.py` (preview), add `--import` to write state; prompts for REST credentials; the provider needs `routeros.secret.auto.tfvars` linked into `roots/fabric-spines` | [fabric-spines](../roots/fabric-spines/README.md#importing-existing-spine-config) |
| `tofu_import_stuff.sh` | `bash tooling/tofu_import_stuff.sh` (needs `proxmox.secret.auto.tfvars` linked into `roots/proxmox-network`) | [proxmox-network](../roots/proxmox-network/README.md#adopting-the-existing-host-config) |

## Tests

```sh
python3 -m unittest discover -s tooling/tests
```

| File | Needs | Checks |
| --- | --- | --- |
| `test_walk_roots.py` | Python (fake `tofu`) | apply needs `yes` and uses the saved plan; declining never applies; failure stops the walk; bootstrap then full apply; dependency order; skipped/unknown roots run nothing; linked root runs plain `tofu`, unlinked uses the wrapper |
| `test_with_secrets.py` | real OpenTofu (`TOFU_TEST_BINARY=...`; skipped if none) + `python-hcl2` | types/escaping preserved; no leak on parse error; linked root refused; no undeclared-variable warnings |
| `test_schemas.py` | Python | `inventory/schema/vm.tf`, `vms.tf` and `vm-config.tf` list the same VM settings |
