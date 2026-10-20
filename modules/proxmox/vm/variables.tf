variable "configure_data_nic_ips" {
  description = "Whether cloud-init configures IPs on additional NICs. Management is configured separately."
  type        = bool
  default     = true
}

variable "ssh_pubkeys" {
  description = "Named SSH public key registry; VMs select entries with config.ssh_pubkeys."
  type        = map(string)
  default     = {}
}

variable "vendor_data_file_id" {
  description = "Optional cloud-init vendor data snippet, preserving generated user data."
  type        = string
  default     = null
}

variable "name" {
  description = "VM hostname, derived by the caller."
  type        = string
}
