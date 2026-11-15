# roots/radius: RADIUS users, groups and clients

What the FreeRADIUS pair (rad01/rad02) knows: who may log in, what they get, and which devices may ask.
The servers themselves (VMs, container, sql module, schema) are services-vms + services-config.
State and plans are encrypted (`state-encryption.tf`): they hold password hashes, generated passwords and
client secrets.

| What | Where | How it reaches the servers |
|---|---|---|
| Groups (reply attributes: admin level, RouterOS group, VLAN) | `radius.auto.tfvars` `groups` | SQL sync on the canary (rad01) |
| Users (name, groups, generated or chosen password) | `radius.auto.tfvars` `users` | SQL sync |
| Hashes of chosen passwords | `radius.secret.auto.tfvars` (git-ignored) `password_hashes` | SQL sync |
| RADIUS clients (devices) + generated secrets | `radius.auto.tfvars` `clients` | `/etc/radius/clients.conf` on both, radius restarts one at a time |

- **The sync owns five tables** (radcheck, radreply, radusergroup, radgroupcheck, radgroupreply): one
  transaction deletes and re-inserts everything declared here, so rows added by hand disappear on the next
  apply. Logins during the sync see the old rows until COMMIT. User/group changes apply to the next login, no
  restart.
- **Only the first group's reply counts** unless that group's reply has `Fall-Through = Yes`: one group per user.
- Every generated-password user is checked with a real PAP login after the sync; the check's log rows are deleted.
- The login log (`radpostauth`) never stores passwords (services-config's post-auth override).

## Users

Chosen password (e.g. houndsolo): put only its crypt hash in the secret file, never the password.

```bash
nix-shell -p openssl --run 'openssl passwd -6'      # prompts twice, no echo; prints $6$...
nvim ~/network_automation/tofu/opentofu-homelab/inventory/auto.tfvars.secret/radius.secret.auto.tfvars
#   password_hashes = {
#     houndsolo = "$6$...."
#   }
tofu -chdir=roots/radius plan     # houndsolo leaves users_without_password, the users sync re-runs
tofu -chdir=roots/radius apply
```

Changing it later: new hash, same steps. Removing a user: delete it from `users` (and its hash), apply.

Generated password (e.g. test): `generate_password = true`; read it after the apply with
`tofu -chdir=roots/radius output -json generated_passwords | jq -r .test`. New password:
`tofu -chdir=roots/radius apply -replace='random_password.user["test"]'`.

| Group | Cisco-AVPair | Mikrotik-Group | VyOS runs the login as |
|---|---|---|---|
| net-admins | shell:priv-lvl=15 | full | radius_priv_user (sudo, configure) |
| net-readonly | shell:priv-lvl=1 | read | radius_user (operator) |

## Clients

Add a device by its MGMT address (WLCs and FS switches can't reach the servers' app network):

```hcl
clients = {
  "leaf-11" = { address = "10.20.10.11" }
}
```

Apply, then give the device its secret (`tofu -chdir=roots/radius output -json client_secrets | jq -r '."leaf-11"'`)
and both servers (`tofu output servers`). For the VyOS leaves that is the fabric-leaves root (DT-131):
`system login radius server <ip> key <secret>` for both servers + `system login radius vrf mgmt`.
localhost (secret `testing123`) is always in the file: the servers' own health checks use it.

## Apply order

services-config first (it mounts `/etc/radius/clients.conf` and seeds it once); this root refuses to write
clients.conf until that mount exists.
