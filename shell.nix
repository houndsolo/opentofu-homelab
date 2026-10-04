# Use the nixpkgs package collection configured on this machine.
{ pkgs ? import <nixpkgs> {} }:

let
  # Use Go 1.26 if available. Otherwise, use the default Go package.
  go = pkgs.go_1_26 or pkgs.go;

  tofu = pkgs.opentofu;
  hcl2 = pkgs.python3Packages.python-hcl2;

  # Python with the HCL parser used by the inventory tests.
  python = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.python-hcl2
  ]);

in

# Stop with a clear error if a required version is too old.
assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast go.version "1.26.0")
  "Go >= 1.26.0 is required. Select a newer nixpkgs channel.";

assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast tofu.version "1.11.6")
  "OpenTofu >= 1.11.6 is required. Select a newer nixpkgs channel.";

assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast hcl2.version "7.3.1")
  "python-hcl2 >= 7.3.1 is required. Select a newer nixpkgs channel.";

pkgs.mkShell {
  # Make these tools available inside nix-shell.
  packages = [
    go
    python
    pkgs.git
    tofu
  ];

  # Use the supplied Go compiler. Do not download another toolchain.
  GOTOOLCHAIN = "local";

  # Disable Go integration with C code for these provider builds.
  CGO_ENABLED = "0";
}
