variable "vyos_api_key" {
  description = "Shared VyOS API key; when null, the provider uses VYOS_API_KEY."
  type        = string
  sensitive   = true
  default     = null
}

provider "vyoscmd" {
  api_key  = var.vyos_api_key
  insecure = false
}
