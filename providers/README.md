# Local providers

Provider sources are Git submodules. Their OpenTofu addresses and versions are
listed in [the manifest](../tooling/provider-manifest.json).

Run from the repository directory:

```sh
git submodule update --init --recursive
nix-shell
tooling/build-all proxmox vyoscmd
export TF_CLI_CONFIG_FILE="$PWD/tooling/local-provider.generated.tfrc"
tofu -chdir=roots/fabric-vms init
```

The current Nix shell requires Go >= 1.26.0, OpenTofu >= 1.11.6 and
python-hcl2 >= 7.3.1 from your configured nixpkgs.

`tooling/build-all` builds and installs every provider when no names are supplied.
Use `tooling/build-all routeros` when the spine configuration needs it.
Binaries go to `.provider-build/`; installed packages go to
`.tofu-provider-mirror/`. Installation regenerates the CLI config with local paths.

Use the generated mirror config for normal `init`, `plan` and `apply` commands.
Keep credentials in environment variables or private variable files.
