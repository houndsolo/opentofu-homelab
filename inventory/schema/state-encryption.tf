# OpenTofu state and plan encryption: AES-GCM with a key derived (PBKDF2) from one passphrase.
# Roots opt in by symlinking this file and the passphrase file:
#   roots/<root>/state-encryption.tf        -> ../../inventory/schema/state-encryption.tf
#   roots/<root>/state.secret.auto.tfvars   -> ../../inventory/auto.tfvars.secret/state.secret.auto.tfvars
# Encrypted now: certs, services-config. Without the passphrase their state cannot be read, so keep
# a copy outside a0-nix. Never rename the "state" key provider or method: encrypted files record
# those names (a rename needs a fallback block, see the OpenTofu state encryption docs).
variable "state_passphrase" {
  description = "Passphrase for state/plan encryption (inventory/auto.tfvars.secret/state.secret.auto.tfvars, git-ignored)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 32
    error_message = "state_passphrase must be at least 32 characters (generate one with: openssl rand -base64 33)."
  }
}

terraform {
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    # enforced: never write plaintext state or plans. A root joining later still has plaintext
    # state: for its first apply, add `method "unencrypted" "migrate" {}` here and
    # `fallback { method = method.unencrypted.migrate }` inside state {} with enforced removed,
    # then put this file back (OpenTofu docs: "Pre-existing project").
    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
