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
