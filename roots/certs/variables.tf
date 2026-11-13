variable "acme_server" {
  description = "Let's Encrypt environment: production, or staging for tests (untrusted certificates, high rate limits). Switching: see README.md."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["staging", "production"], var.acme_server)
    error_message = "acme_server must be staging or production."
  }
}

variable "certificate" {
  description = "The wildcard certificate for the reverse proxy and where it lands on each proxy VM."
  type = object({
    common_name = optional(string, "*.lylat.space") # covers every proxied name (one level deep)
    key_type    = optional(string, "EC256")
    directory   = optional(string, "/etc/ssl/svc") # fullchain.pem (0644) and privkey.pem (0600, root)
  })
  default = {}
}

variable "cloudflare" {
  description = "Cloudflare API access per zone (inventory/auto.tfvars.secret/cloudflare.secret.auto.tfvars, git-ignored). api_token needs Zone:DNS:Edit on the zone."
  type = map(object({
    account_id = string
    api_token  = string
  }))
  sensitive = true
}

variable "ssh_private_key_path" {
  description = "Local private key authorized for the proxy VMs' config.ssh_username."
  type        = string
  default     = "~/.ssh/id_rsa"
}
