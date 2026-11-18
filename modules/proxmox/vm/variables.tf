variable "configure_data_ips" {
  description = "Whether cloud-init configures IPs on additional NICs. Management is configured separately."
  type        = bool
  default     = true
}

variable "ssh_pubkeys" {
  description = "Named SSH public key registry; VMs select entries with config.ssh_pubkeys."
  type        = map(string)
  default     = {}
}

variable "name" {
  description = "VM hostname, derived by the caller."
  type        = string
}
