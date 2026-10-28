variable "pve_api_token" {
  type      = string
  sensitive = true
}
variable "greatfox_api_token" {
  type      = string
  sensitive = true
}
variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/id_rsa"
}

locals {
  pve_management_ips = {
    for name, node in var.nodes.proxmox :
    name => cidrhost(var.nodes.management_prefix, node.id)
  }

  pve_api_url = "https://${local.pve_management_ips[var.nodes.cluster_api_node]}:8006"
}

provider "proxmox" {
  endpoint  = local.pve_api_url
  api_token = var.pve_api_token
  insecure  = true

  ssh {
    username    = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))

    dynamic "node" {
      for_each = {
        for name, ip in local.pve_management_ips : name => ip
        if !var.nodes.proxmox[name].standalone
      }

      content {
        name    = node.key
        address = node.value
      }
    }
  }
}

provider "proxmox" {
  endpoint  = "https://${local.pve_management_ips["greatfox"]}:8006"
  alias     = "greatfox"
  api_token = var.greatfox_api_token
  insecure  = true

  ssh {
    username    = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
  }
}
