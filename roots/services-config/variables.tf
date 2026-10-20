variable "ssh_private_key_path" {
  description = "Local private key authorized for each DNS VM's config.ssh_username."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "bind9_image" {
  description = "ISC BIND9 image. Pin a digest here for reproducible deployments."
  type        = string
  default     = "docker.io/internetsystemsconsortium/bind9:9.20"
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", var.bind9_image))
    error_message = "Use a container image reference without whitespace or shell characters."
  }
}

variable "dns_allowed_clients" {
  description = "IPv4 client networks permitted to query and use recursion."
  type        = list(string)
  default     = ["127.0.0.1/32", "10.0.0.0/8"]
  validation {
    condition     = length(var.dns_allowed_clients) > 0 && alltrue([for prefix in var.dns_allowed_clients : can(cidrnetmask(prefix))])
    error_message = "Provide at least one valid IPv4 CIDR."
  }
}

variable "dns_deploy_revision" {
  description = "Change to redeploy after rebuilding a VM without changing its address or ID."
  type        = string
  default     = "1"
}

variable "dns_hosts" {
  description = "Zone-relative owner => record type => single RDATA string, in BIND zone-file syntax. Overrides generated records for that owner."
  type        = map(map(string))
  default     = {}
  validation {
    condition = alltrue(flatten([
      for owner, records in var.dns_hosts : [
        for type, data in records :
        can(regex("^(@|[A-Za-z0-9_*][A-Za-z0-9_.*-]*)$", owner)) &&
        can(regex("^[A-Z][A-Z0-9]*$", type)) &&
        !can(regex("[\r\n]", data)) && trimspace(data) != ""
      ]
    ]))
    error_message = "Use DNS owner names, uppercase record types and nonempty single-line RDATA in BIND syntax."
  }
}

variable "dns_records" {
  description = "Additional records, supporting repeated owner/type pairs and per-record TTLs. RDATA uses BIND syntax, including RFC 3597 TYPE records."
  type = list(object({
    name = string
    type = string
    data = string
    ttl  = optional(number, 300)
  }))
  default = []
  validation {
    condition = alltrue([
      for record in var.dns_records :
      can(regex("^(@|[A-Za-z0-9_*][A-Za-z0-9_.*-]*)$", record.name)) &&
      can(regex("^[A-Z][A-Z0-9]*$", record.type)) &&
      !can(regex("[\r\n]", record.data)) && trimspace(record.data) != "" &&
      record.ttl >= 0 && record.ttl <= 2147483647 && record.ttl == floor(record.ttl)
    ])
    error_message = "Records need a valid owner, uppercase type, single-line RDATA and an integer TTL in 0..2147483647."
  }
}

variable "dns_primary" {
  description = "Inventory hostname of the writable primary; other DNS VMs are secondaries."
  type        = string
  default     = "dns01"
}

variable "dns_tsig_secret" {
  description = "Optional existing base64 HMAC-SHA256 key. When null, generate 32 random bytes once and retain them in state."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition     = var.dns_tsig_secret == null || can(regex("^[A-Za-z0-9+/]{43}=$", var.dns_tsig_secret))
    error_message = "Supply a base64-encoded 32-byte HMAC-SHA256 key, e.g. openssl rand -base64 32."
  }
}
