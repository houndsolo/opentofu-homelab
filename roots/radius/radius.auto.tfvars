# RADIUS identity (roots/radius). Non-secret: names, groups, devices. Password hashes live in the
# git-ignored radius.secret.auto.tfvars; client secrets and generated passwords are made by tofu.

groups = {
  # Admin on network gear: Cisco-style priv-lvl 15 (C9800 WLC, FS, VyOS -> radius_priv_user), RouterOS group full.
  "net-admins" = {
    reply = [
      { attribute = "Cisco-AVPair", op = "+=", value = "shell:priv-lvl=15" },
      { attribute = "Mikrotik-Group", value = "full" },
    ]
  }
  # Read-only: priv-lvl 1 (VyOS operator = radius_user, no sudo/configure), RouterOS group read.
  "net-readonly" = {
    reply = [
      { attribute = "Cisco-AVPair", op = "+=", value = "shell:priv-lvl=1" },
      { attribute = "Mikrotik-Group", value = "read" },
    ]
  }
}

users = {
  # Password chosen by the owner: its hash goes in radius.secret.auto.tfvars (password_hashes.houndsolo).
  houndsolo = { groups = ["net-admins"] }
  # Test account, read-only, password generated: tofu output -json generated_passwords | jq -r .test
  test = { groups = ["net-readonly"], generate_password = true }
}

# Devices generated from the inventory: every VyOS fabric leaf as leaf-<id> (mgmt 10.20.10.<id>). fabric-leaves
# configures the leaf side from the generated radius-clients.secret.auto.tfvars.
inventory_clients = {
  vyos_leaves = true
}

# Other devices allowed to ask the servers (their MGMT address), each with a generated secret (output
# client_secrets); a name here overrides a generated one.
clients = {
}
