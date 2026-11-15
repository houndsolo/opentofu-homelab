output "users" {
  description = "Synced users: groups (priority order) and where the password comes from."
  value = { for u in sort(tolist(local.synced_users)) : u => {
    groups   = var.users[u].groups
    password = contains(tolist(local.generated_users), u) ? "generated (output generated_passwords)" : "hash from radius.secret.auto.tfvars"
  } }
}

output "users_without_password" {
  description = "Enabled users NOT synced because they have no hash in password_hashes and generate_password = false."
  value       = local.users_without_password
}

output "generated_passwords" {
  description = "user => password for generate_password users. Read: tofu output -json generated_passwords | jq -r .<user>"
  value       = { for u in local.generated_users : u => random_password.user[u].result }
  sensitive   = true
}

output "client_secrets" {
  description = "client => RADIUS shared secret, for the device side (VyOS system login radius ... key, etc.)."
  value       = { for n in keys(local.all_clients) : n => random_password.client[n].result }
  sensitive   = true
}

output "clients" {
  description = "RADIUS clients in clients.conf (besides localhost): name => address."
  value       = { for n, c in local.all_clients : n => c.address }
}

output "servers" {
  description = "RADIUS servers devices should list (MGMT addresses: the WLCs and FS switches can't reach the app network)."
  value       = [for n in local.radius_names : split("/", local.radius_vms[n].management_address)[0]]
}
