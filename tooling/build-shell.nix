# The shell for building the local providers (tooling/build-providers, tooling/build-all): Go plus
# what the build scripts themselves need. The everyday shell (../shell.nix) has no Go; the build
# scripts re-run themselves in this one when Go isn't on PATH, so `tooling/build-all` just works.
{ pkgs ? import <nixpkgs> {} }:

let
  # Use Go 1.26 if available. Otherwise, use the default Go package.
  go = pkgs.go_1_26 or pkgs.go;
in

assert pkgs.lib.assertMsg
  (pkgs.lib.versionAtLeast go.version "1.26.0")
  "Go >= 1.26.0 is required. Select a newer nixpkgs channel.";

pkgs.mkShell {
  packages = [
    go
    pkgs.python3
    pkgs.git
  ];

  # Use the supplied Go compiler. Do not download another toolchain.
  GOTOOLCHAIN = "local";

  # Disable Go integration with C code for these provider builds (static binaries).
  CGO_ENABLED = "0";
}
