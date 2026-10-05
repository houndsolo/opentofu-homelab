variable "pve_api_token" {
  description = "Proxmox API token; alternatively use PROXMOX_VE_API_TOKEN."
  type        = string
  sensitive   = true
  default     = null
}

variable "ssh_private_key_path" {
  description = "Optional SSH key path for image imports; otherwise use the SSH agent."
  type        = string
  default     = null
}

provider "proxmox" {
  endpoint  = var.pve_leaf.proxmox.endpoint
  api_token = var.pve_api_token
  insecure  = var.pve_leaf.proxmox.insecure

  ssh {
    username    = var.pve_leaf.proxmox.ssh_username
    agent       = var.ssh_private_key_path == null ? var.pve_leaf.proxmox.ssh_agent : false
    private_key = var.ssh_private_key_path == null ? null : file(pathexpand(var.ssh_private_key_path))
  }
}
