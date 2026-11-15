variable "groups" {
  description = "RADIUS groups: what members get back in the Access-Accept (reply), and optional extra conditions (check)."
  type = map(object({
    reply = optional(list(object({
      attribute = string
      op        = optional(string, ":=")
      value     = string
    })), [])
    check = optional(list(object({
      attribute = string
      op        = optional(string, "==")
      value     = string
    })), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for g in keys(var.groups) : can(regex("^[a-z0-9][a-z0-9_.-]{0,63}$", g))])
    error_message = "Group names: lowercase letters, digits, _ . - (max 64)."
  }
  validation {
    condition = alltrue(flatten([for g in values(var.groups) : [
      for a in concat(g.reply, g.check) : contains(["=", ":=", "+=", "==", "!=", ">", ">=", "<", "<=", "=~", "!~", "=*", "!*"], a.op)
    ]]))
    error_message = "Unknown operator in a group attribute (see the FreeRADIUS users(5) operators)."
  }
}

variable "users" {
  description = <<-EOT
    RADIUS users. groups: in priority order; only the FIRST group's reply is used unless that group's reply
    sets Fall-Through = Yes, so give each user one group. Password: either generate_password = true (tofu
    makes one, read it with `tofu output -json generated_passwords`), or a crypt hash in password_hashes
    (radius.secret.auto.tfvars). A user with neither is skipped (listed in output users_without_password).
  EOT
  type = map(object({
    groups            = list(string)
    generate_password = optional(bool, false)
    enabled           = optional(bool, true)
  }))
  default = {}

  validation {
    condition     = alltrue([for u in keys(var.users) : can(regex("^[a-z0-9][a-z0-9_.@-]{0,63}$", u))])
    error_message = "User names: lowercase letters, digits, _ . @ - (max 64)."
  }
}

variable "password_hashes" {
  description = "user => crypt hash of the password you chose (radius.secret.auto.tfvars, git-ignored). Make one with `openssl passwd -6` ($6$, SHA-512 crypt) or `mkpasswd -m sha-512`; bcrypt ($2a$/$2b$/$2y$) works too."
  type        = map(string)
  sensitive   = true
  default     = {}

  validation {
    condition     = alltrue([for h in values(var.password_hashes) : can(regex("^\\$(6|2[aby])\\$[./A-Za-z0-9$]+$", h))])
    error_message = "password_hashes values must be crypt hashes starting with $6$ (openssl passwd -6) or $2a$/$2b$/$2y$ (bcrypt), never a clear-text password."
  }
}

variable "clients" {
  description = <<-EOT
    RADIUS clients (devices allowed to ask the servers), name => { address (IP or CIDR the device sends from:
    its MGMT address), nas_type, require_message_authenticator }. Each gets a generated 32-char secret (output
    client_secrets). localhost (secret testing123, used by the servers' own health checks) is always added.
  EOT
  type = map(object({
    address                       = string
    nas_type                      = optional(string, "other")
    require_message_authenticator = optional(string) # yes | no | auto; null = FreeRADIUS default (auto)
  }))
  default = {}

  validation {
    condition     = alltrue([for n in keys(var.clients) : can(regex("^[a-z0-9][a-z0-9_-]{0,63}$", n)) && !startswith(n, "localhost")])
    error_message = "Client names: lowercase letters, digits, _ - (max 64), not starting with localhost."
  }
  validation {
    condition     = alltrue([for c in values(var.clients) : can(cidrhost(strcontains(c.address, "/") ? c.address : "${c.address}/32", 0))])
    error_message = "Client address must be an IPv4 address or CIDR."
  }
  validation {
    condition     = alltrue([for c in values(var.clients) : c.require_message_authenticator == null || contains(["yes", "no", "auto"], coalesce(c.require_message_authenticator, "auto"))])
    error_message = "require_message_authenticator must be yes, no or auto."
  }
}

variable "database" {
  description = "The radius database (same values as services-config var.radius.database). Its password comes from /etc/radius/radius.env on the VM."
  type = object({
    host = optional(string, "10.56.14.104") # Patroni VIP (lylat-data)
    port = optional(number, 5432)
    name = optional(string, "radius")
    user = optional(string, "radius")
  })
  default = {}
}

variable "ssh_private_key_path" {
  description = "Local private key authorized for the radius VMs' config.ssh_username."
  type        = string
  default     = "~/.ssh/id_rsa"
}
