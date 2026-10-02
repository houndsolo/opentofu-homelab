# Use the build server's nixpkgs channel; override it with nix-shell -I nixpkgs=...
# when that channel does not yet provide the required Go/OpenTofu versions.
{ pkgs ? import <nixpkgs> {} }:
let
  go = pkgs.go_1_26 or pkgs.go;
  python = pkgs.python3.withPackages (p: [ p.python-hcl2 ]);
in
assert pkgs.lib.assertMsg (pkgs.lib.versionAtLeast go.version "1.26.0")
  "This repository requires Go >= 1.26.0; select a newer nixpkgs channel.";
assert pkgs.lib.assertMsg (pkgs.lib.versionAtLeast pkgs.opentofu.version "1.11.6")
  "The offline tests require OpenTofu >= 1.11.0; select a newer nixpkgs channel.";
assert pkgs.lib.assertMsg (pkgs.lib.versionAtLeast pkgs.python3Packages.python-hcl2.version "7.3.1")
  "Inventory tests require python-hcl2 >= 7.3.1; select a newer nixpkgs channel.";
pkgs.mkShell {
  packages = [ go python pkgs.git pkgs.opentofu ];

  # Avoid implicit Go toolchain downloads and NixOS dynamic-linker dependencies.
  GOTOOLCHAIN = "local";
  CGO_ENABLED = "0";
}
