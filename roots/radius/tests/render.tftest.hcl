# Plan-only checks of the rendered SQL and clients.conf (no SSH, nothing applied).
variables {
  ssh_private_key_path = "/dev/null"
  password_hashes      = { houndsolo = "$6$saltsalt$abcdefghijklmnopqrstuvwxyz./ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopq" }
  clients              = { "wlc-1" = { address = "10.20.1.1", nas_type = "cisco" } }
}

run "sql_and_clients_render" {
  command = plan

  assert {
    condition     = strcontains(join("\n", local.hash_check_rows), "INSERT INTO radcheck (username, attribute, op, value) VALUES ('houndsolo', 'Crypt-Password', ':=', '$6$saltsalt$")
    error_message = "houndsolo's hash row is missing from the sync SQL"
  }
  assert {
    condition     = contains(local.member_rows, "INSERT INTO radusergroup (username, groupname, priority) VALUES ('test', 'net-readonly', 1);")
    error_message = "test should be in net-readonly"
  }
  assert {
    condition     = contains(local.group_rows, "INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('net-admins', 'Cisco-AVPair', '+=', 'shell:priv-lvl=15');")
    error_message = "net-admins reply row missing"
  }
  assert {
    condition     = length(local.users_without_password) == 0
    error_message = "no user should be skipped when houndsolo has a hash"
  }
  assert {
    condition     = local.all_clients["leaf-11"].address == "10.20.10.11" && local.all_clients["leaf-42"].address == "10.20.10.42" && local.all_clients["wlc-1"].nas_type == "cisco"
    error_message = "inventory leaves (leaf-<id> at 10.20.10.<id>) and manual clients should both be in all_clients"
  }
  assert {
    condition     = length(local.leaf_clients) == 11
    error_message = "expected 11 VyOS leaves from the inventory (3 physical + 8 Proxmox)"
  }
  assert {
    condition     = local.expected_counts == "2|0|2|0|4"
    error_message = "expected row counts radcheck|radreply|radusergroup|radgroupcheck|radgroupreply = 2|0|2|0|4"
  }
}

run "user_without_hash_is_skipped" {
  command = plan
  variables {
    password_hashes = {}
  }

  assert {
    condition     = length(local.users_without_password) == 1 && local.users_without_password[0] == "houndsolo"
    error_message = "houndsolo without a hash must be listed in users_without_password"
  }
  assert {
    condition     = length(local.hash_check_rows) == 0 && !contains(tolist(local.synced_users), "houndsolo")
    error_message = "houndsolo without a hash must not be synced"
  }
}

run "clear_text_password_rejected" {
  command = plan
  variables {
    password_hashes = { houndsolo = "hunter2" }
  }
  expect_failures = [var.password_hashes]
}
