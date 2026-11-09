# Tooling

Scripts to build the providers, load secrets and walk through the roots. Run
them from the top of the repo, inside `nix-shell`.

| File | What it is | When you use it |
| --- | --- | --- |
| `build-all` | Builds and installs the providers | First setup, and after updating a provider |
| `build-providers`, `install-providers` | The two halves of `build-all` | Rarely on their own |
| `provider-manifest.json` | Name, source address and version of each custom provider | When a provider's version changes |
| `local-provider.tfrc` → `.generated.tfrc` | CLI config: use the local mirror for the custom providers | Point `TF_CLI_CONFIG_FILE` at the generated file |
| `dev.tfrc` → `.generated.tfrc` | CLI config using `dev_overrides` | Only when developing a provider |
| `walk-roots.sh` | Guided plan/apply across the roots | Everyday use |
| `with-secrets` | Runs a command with one shared secrets file loaded as `TF_VAR_*` | Only if you keep all secrets in one file instead of per-provider links |
| `routeros-spine-imports.py` | Imports existing spine objects into state | Adopting a spine that's already configured |
| `tofu_import_stuff.sh` | Imports existing Proxmox host networking into state | Adopting hosts that are already configured |
| `tests/` | Unit tests for `walk-roots.sh` and `with-secrets` | After changing those scripts |

## The development shell

`nix-shell`, using `shell.nix` at the top of the repo, gives you:

- **Go ≥ 1.26.** `GOTOOLCHAIN=local` stops Go from downloading a different
  toolchain, and `CGO_ENABLED=0` makes static builds.
- **OpenTofu ≥ 1.11.6.**
- **Python 3 with `python-hcl2` ≥ 7.3.1**, which `with-secrets` uses.
- **git.**
- **`TF_CLI_CONFIG_FILE`**, already pointing at
  `tooling/local-provider.generated.tfrc`, so OpenTofu finds the locally built
  providers (see below).

`shell.nix` uses your configured nixpkgs channel (`<nixpkgs>`). If that channel's
versions are too old, it stops with a message. You can point it at a newer
channel for one run:

```sh
nix-shell -I nixpkgs=https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz
```

Without Nix, install the same tools yourself. For example, run
`pip install 'python-hcl2>=7.3.1'` for the Python part.

## Building the providers

```sh
tooling/build-all                    # build and install all three providers
tooling/build-all proxmox vyoscmd    # or only the ones you name
```

`build-all` runs two steps for your machine's platform (for example
`linux_amd64`):

1. **`build-providers`**, for each provider:
   - Copies the submodule's source to a temporary folder. The submodule itself is
     never modified, and Go is free to create a missing `go.sum`.
   - Runs `go build -mod=mod -trimpath`.
   - Writes the binary and a small `.build.json` (commit, "dirty" flag,
     platform, version) into `.provider-build/<platform>/`.
   - Warns if the submodule has uncommitted changes, and stops with a clear
     message if the submodule hasn't been downloaded yet.
2. **`install-providers`**:
   - Checks that every selected binary exists. If one is missing, it installs
     nothing.
   - Copies the binaries into a local mirror, using the folder layout OpenTofu
     expects (shown below).
   - Writes the two `*.generated.tfrc` files.

```text
.tofu-provider-mirror/
└── local/mechanic/                                    <- matches source = "local/mechanic/<name>"
    ├── proxmox/0.111.0/linux_amd64/
    │   ├── terraform-provider-proxmox_v0.111.0
    │   └── build.json
    ├── vyoscmd/0.1.0/linux_amd64/...
    └── routeros/1.99.1/linux_amd64/...
```

`.provider-build/` and `.tofu-provider-mirror/` are both git-ignored.

### Pointing OpenTofu at the mirror

Inside `nix-shell` this is already done for you. Outside it, run:

```sh
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
```

| CLI config | Use it for | What it does |
| --- | --- | --- |
| `local-provider.generated.tfrc` | Normal use | A `filesystem_mirror` for `local/mechanic/*`. Everything else (`hashicorp/dns`, `hashicorp/random`) comes from the public registry. `tofu init` and lock files work as usual. |
| `dev.generated.tfrc` | Provider development | `dev_overrides`: OpenTofu loads the binaries straight from the mirror folders, skips the version and checksum checks, and prints a warning on every command. |

The generated files contain **absolute paths**, so `install-providers` rewrites
them for your checkout every time it runs. The committed copies still contain
the original author's paths, which is why they may show up as modified in
`git status` after a build. The templates (`dev.tfrc`, `local-provider.tfrc`)
contain placeholders like `@MIRROR@` instead.

### After a rebuild: lock file checksums

Each root records its providers' checksums in `.terraform.lock.hcl`. That
checksum also covers `build.json`, which includes the commit. So a rebuild can
change the checksum even when the Go code didn't change, and two machines never
agree on it. That's why lock files are git-ignored here. If `tofu init`
complains that a provider doesn't match the lock file, refresh it:

```sh
tofu -chdir=roots/<root> init -upgrade
```

## walk-roots.sh: the guided runner

```text
Usage: tooling/walk-roots.sh [--no-secrets] [--list] [ROOT ...]
```

| Option | Effect |
| --- | --- |
| *(no roots)* | Walk every usable root, in dependency order |
| `ROOT ...` | Walk only these roots, still in dependency order |
| `--list` | Print the root names and exit |
| `--no-secrets` | Don't use `with-secrets`; use the `TF_VAR_*` you've already exported. A root that links the secrets file still auto-loads it. |
| `--help` | Show the usage text |
| `TOFU_BIN=...` | Environment variable: which OpenTofu executable to run (default `tofu`) |
| `TF_VAR_<name>=...` | Environment variable: any input, e.g. `TF_VAR_ssh_private_key_path=~/.ssh/id_ed25519` |

At each root, it prints a reminder of what that root needs, then asks:

```text
--- services-config ---
DNS VMs need SSH/sudo and Podman; DHCP VMs need reachable VyOS APIs.
[p]lan, [a]pply, [s]kip (default), [q]uit, [b]ootstrap DNS:
```

| Choice | What happens |
| --- | --- |
| `p` | `init`, `validate`, `plan`. Shows the plan and changes nothing. |
| `a` | `init`, `validate`, then `plan`, saved to a private temporary file. If there are changes, it asks `Apply the plan shown above? Type yes:` and applies exactly that saved plan. Any answer other than `yes` applies nothing. |
| `s`, or just Enter | Skip this root |
| `q` | Stop the walk |
| `b` | services-config only: the [DNS bootstrap](../roots/services-config/README.md#first-deployment-bootstrap-first). Like `a`, but limited to `-target=terraform_data.bind9`. Afterwards it asks again for the same root, so you can do the normal apply. |

Behaviour worth knowing:

- **Dependency order is fixed.** `tooling/walk-roots.sh services-config services-vms`
  still runs `services-vms` first. Naming a root does **not** add the roots it
  depends on.
- **Failures stop everything.** If any command fails (`init`, `validate`, `plan`
  or `apply`), the walk stops, and later roots aren't touched.
- **No changes, no question.** If the plan finds nothing to change, you aren't
  asked anything.
- **Plans are cleaned up.** Saved plan files can contain secrets, so they're
  deleted right after use and again when the script exits.
- **Secrets are chosen per root.** In a root that has a `*.secret.auto.tfvars`
  file (normally a link to one of the per-provider files), it runs plain `tofu`,
  which auto-loads it, and prints `Secrets: auto-loading the per-provider files
  linked into this root.` Every other root goes through `with-secrets`, as long
  as the single file `inventory/auto.tfvars/passwords.secret.auto.tfvars` exists.
- **Starting it changes nothing.** Only an `a` or `b` choice followed by `yes`
  does.
- **It only runs `tofu`.** It doesn't install images, enable APIs or create
  credentials.
- **Unfinished roots are refused.** `proxmox-virtual-hosts` isn't in its list;
  naming it exits with code 2.

## with-secrets

The lab links one secret file per provider into each root, and plain `tofu`
loads it. `with-secrets` is the alternative for keeping **all** secrets in one
file without linking anything.

```text
tooling/with-secrets [--file PATH] [--tofu PATH] [--] COMMAND [ARGS...]
```

```sh
tooling/with-secrets tofu -chdir=roots/services-config plan
tooling/with-secrets --file ~/other-lab.tfvars tofu -chdir=roots/workloads plan
tooling/with-secrets bash tooling/tofu_import_stuff.sh   # any command works, not just tofu
tooling/with-secrets python3 tooling/routeros-spine-imports.py --import
```

How it works:

1. It reads **only the variable names** from the secrets file
   (`inventory/auto.tfvars/passwords.secret.auto.tfvars` by default), using
   `python-hcl2`.
2. It asks **OpenTofu itself** to decode the values, by running `tofu console`
   in an empty temporary folder. The types and escaping are therefore exactly
   what OpenTofu would see.
3. It runs your command with `TF_VAR_<name>` set for each value. Strings are
   passed as they are, other types as JSON, and `null` unsets the variable.

Safety features:

- **Linked roots are refused.** If the target root (taken from `-chdir`, or the
  current folder) has a `*.auto.tfvars` file that *is* the secrets file, usually
  a link, it stops: `... already auto-loads the shared secrets; run tofu without
  with-secrets`. That root loads the file by itself, so wrapping it would load
  everything twice.
- **Values never print**, not even when the file has a syntax error.
- **Nothing leaks.** The variables exist only for the child command, never in
  your shell.

How it fits next to the per-provider files:
[inventory/README.md](../inventory/README.md#the-alternative-one-file-and-the-wrapper).

## Import helpers

These two scripts adopt infrastructure that already exists into state, so
OpenTofu can manage it without recreating it. They aren't executable, so run
them through their interpreter.

| Script | Run it like this | Details |
| --- | --- | --- |
| `routeros-spine-imports.py` | `python3 tooling/routeros-spine-imports.py` to preview, then add `--import` (it needs `routeros.secret.auto.tfvars` linked into `roots/fabric-spines`) | [fabric-spines](../roots/fabric-spines/README.md#importing-existing-spine-config) |
| `tofu_import_stuff.sh` | `bash tooling/tofu_import_stuff.sh` (it needs `proxmox.secret.auto.tfvars` linked into `roots/proxmox-network`) | [proxmox-network](../roots/proxmox-network/README.md#adopting-the-existing-host-config) |

Both have hard-coded assumptions: the spine script's object names, and the
import script's node and interface lists. Read them before you run them.

## Tests

```sh
# From the top of the repo, inside nix-shell
python3 -m unittest discover -s tooling/tests
```

- **`test_walk_roots.py`** runs `walk-roots.sh` against a fake `tofu` that only
  records its arguments, so it never touches real infrastructure. It checks
  that:
  - apply needs `yes` and uses the saved plan
  - declining never applies
  - a failure stops the walk before the next root
  - bootstrap followed by a full apply works
  - roots run in dependency order
  - skipped and unknown roots run nothing
  - a root that links the secrets file runs plain `tofu`, and an unlinked root
    goes through the wrapper
- **`test_with_secrets.py`** needs a real OpenTofu (choose one with
  `TOFU_TEST_BINARY=/path/to/tofu`) and `python-hcl2`. These tests are skipped if
  no `tofu` is found. They check that:
  - value types and escaping are preserved
  - secrets don't leak on a parse error
  - a root that links the file is refused
  - there are no "undeclared variable" warnings
- **`test_schemas.py`** needs only Python. It checks that `inventory/schema/vm.tf`,
  `vms.tf` and `vm-config.tf` list the same VM settings. OpenTofu can't share one
  object type between variables, so the fields are written out three times, and
  this test keeps the copies identical.
