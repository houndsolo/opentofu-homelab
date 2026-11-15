# Users and groups -> one SQL transaction on the canary.
locals {
  generated_users = toset([for u, c in var.users : u if c.enabled && c.generate_password])
  hash_users      = toset([for u, c in var.users : u if c.enabled && !c.generate_password && contains(keys(nonsensitive(var.password_hashes)), u)])
  users_without_password = sort([
    for u, c in var.users : u if c.enabled && !c.generate_password && !contains(keys(nonsensitive(var.password_hashes)), u)
  ])
  synced_users = setunion(local.generated_users, local.hash_users)

  group_rows = flatten([for g, c in var.groups : concat(
    [for a in c.reply : format("INSERT INTO radgroupreply (groupname, attribute, op, value) VALUES ('%s', '%s', '%s', '%s');", g, replace(a.attribute, "'", "''"), a.op, replace(a.value, "'", "''"))],
    [for a in c.check : format("INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES ('%s', '%s', '%s', '%s');", g, replace(a.attribute, "'", "''"), a.op, replace(a.value, "'", "''"))],
  )])
  member_rows = flatten([for u in sort(tolist(local.synced_users)) : [
    for i, g in var.users[u].groups : format("INSERT INTO radusergroup (username, groupname, priority) VALUES ('%s', '%s', %d);", u, g, i + 1)
  ]])
  # Rows for chosen-password users are known at plan time; generated ones only after random_password exists.
  hash_check_rows = [for u in sort(tolist(local.hash_users)) :
    format("INSERT INTO radcheck (username, attribute, op, value) VALUES ('%s', 'Crypt-Password', ':=', '%s');", u, var.password_hashes[u])
  ]
  generated_check_rows = [for u in sort(tolist(local.generated_users)) :
    format("INSERT INTO radcheck (username, attribute, op, value) VALUES ('%s', 'Crypt-Password', ':=', '%s');", u, random_password.user[u].bcrypt_hash)
  ]
  check_rows = concat(local.hash_check_rows, local.generated_check_rows)

  sync_sql = join("\n", concat(
    [
      "-- Managed by OpenTofu (roots/radius). Replaces the whole identity tables in one transaction:",
      "-- logins during the sync keep seeing the old rows (MVCC) until COMMIT.",
      "BEGIN;",
      "LOCK TABLE radcheck, radreply, radusergroup, radgroupcheck, radgroupreply IN EXCLUSIVE MODE;",
      "DELETE FROM radcheck;", "DELETE FROM radreply;", "DELETE FROM radusergroup;",
      "DELETE FROM radgroupcheck;", "DELETE FROM radgroupreply;",
    ],
    local.group_rows, local.member_rows, local.check_rows,
    ["COMMIT;"],
  ))

  expected_counts = format("%d|%d|%d|%d|%d",
    length(local.check_rows), 0, length(local.member_rows),
    length(flatten([for c in values(var.groups) : c.check])), length(flatten([for c in values(var.groups) : c.reply])),
  )
}

resource "random_password" "user" {
  for_each = local.generated_users
  length   = 24
  special  = false
}

resource "terraform_data" "users" {
  count = local.canary == null ? 0 : 1

  triggers_replace = [
    sha256(local.sync_sql),
    local.radius_vms[local.canary].management_address,
    local.radius_vms[local.canary].vm_id,
  ]

  lifecycle {
    precondition {
      condition     = alltrue(flatten([for u, c in var.users : [for g in c.groups : contains(keys(var.groups), g)]]))
      error_message = "Every group a user lists must exist in var.groups."
    }
    precondition {
      condition     = length([for u, c in var.users : u if c.generate_password && contains(keys(nonsensitive(var.password_hashes)), u)]) == 0
      error_message = "A user has generate_password = true AND a hash in password_hashes: pick one."
    }
    precondition {
      condition     = length([for u in keys(nonsensitive(var.password_hashes)) : u if !contains(keys(var.users), u)]) == 0
      error_message = "password_hashes has an entry for a user that isn't in var.users."
    }
  }

  connection {
    type        = "ssh"
    host        = split("/", local.radius_vms[local.canary].management_address)[0]
    user        = local.radius_vms[local.canary].config.ssh_username
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 /tmp/tofu-radius-users-${self.id}"]
  }

  provisioner "file" {
    content = templatefile("${path.module}/templates/users-sync.sh.tftpl", {
      db       = var.database
      sql_b64  = base64encode(local.sync_sql)
      expected = local.expected_counts
      # Generated passwords are checked with a real login after the sync (base64: never plain in the script).
      probe_b64 = base64encode(join("\n", [for u in sort(tolist(local.generated_users)) : "${u} ${random_password.user[u].result}"]))
    })
    destination = "/tmp/tofu-radius-users-${self.id}/sync.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "rc=0; sudo -n bash /tmp/tofu-radius-users-${self.id}/sync.sh || rc=$?; rm -rf /tmp/tofu-radius-users-${self.id}; exit $rc",
    ]
  }
}
