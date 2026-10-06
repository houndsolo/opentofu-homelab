variable "vyos_api_key" {
  description = "Shared VyOS API key; when null, the provider uses VYOS_API_KEY."
  type        = string
  sensitive   = true
  default     = null
}

variable "vyos_insecure" {
  description = "Disable TLS certificate verification for VyOS HTTPS API connections."
  type        = bool
  default     = false
  nullable    = false
}

provider "vyoscmd" {
  api_key  = var.vyos_api_key
  insecure = var.vyos_insecure

  # Each leaf resource supplies its endpoint from fabric.settings.vyos_mgmt_prefix
  # and leaf.id. Provider configuration is shared by all leaf instances.
}
