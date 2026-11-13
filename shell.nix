# The everyday shell: OpenTofu, Python with python-hcl2 (tooling/with-secrets) and git, with
# TF_CLI_CONFIG_FILE pointing at the local provider mirror. direnv loads it automatically
# (.envrc, cached by nix-direnv); `nix-shell` works too. Go is only needed to build the providers:
# that lives in tooling/build-shell.nix, which the build scripts enter by themselves.
{ pkgs ? import <nixpkgs> {} }:

let
  # OpenTofu from nixos-unstable: the stable channel (26.05) ships 1.11.x. a0-nix puts
  # <nixpkgs-unstable> on NIX_PATH (/etc/nixos: nix.nixPath); elsewhere fall back to <nixpkgs>.
  unstable =
    if builtins.any (e: e.prefix == "nixpkgs-unstable") builtins.nixPath
    then import <nixpkgs-unstable> {} else pkgs;
  tofu = unstable.opentofu;
  hcl2 = pkgs.python3Packages.python-hcl2;

  # Python with the HCL parser that tooling/with-secrets uses.
  python = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.python-hcl2
  ]);

in

# Stop with a clear error if a required version is too old.
assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast tofu.version "1.13.0")
  "OpenTofu >= 1.13.0 is required. Select a newer nixpkgs channel.";

assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast hcl2.version "7.3.1")
  "python-hcl2 >= 7.3.1 is required. Select a newer nixpkgs channel.";

pkgs.mkShell {
  # Make these tools available in the shell.
  packages = [
    python
    pkgs.git
    tofu
  ];

  # Resolve the local/mechanic/* providers from the repo's provider mirror.
  shellHook = ''
    export TF_CLI_CONFIG_FILE=${toString ./tooling/local-provider.generated.tfrc}
  '';
}
