variable "vyos_api_key" {
  description = "VyOS API key; alternatively use VYOS_API_KEY."
  type        = string
  sensitive   = true
  default     = null
}

provider "vyoscmd" {
  api_key = var.vyos_api_key
}
