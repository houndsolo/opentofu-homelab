# Shared SSH public key registry. Add full public keys, then select their names
# in vms.auto.tfvars with config.ssh_pubkeys = ["laptop", "desktop"].
# Public keys only; never put private keys here.
locals {
  ssh_pubkey = {
    # laptop  = "ssh-ed25519 AAAA... laptop"
    # desktop = "ssh-ed25519 AAAA... desktop"
  }
}
