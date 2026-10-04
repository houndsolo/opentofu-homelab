variable "pve_api_token" {
  type      = string
  sensitive = true
}
variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/id_rsa"
}

locals {
  pve_mgmt_subnet = "10.20.7.0/24"

  pve_node_mgmt = {
    for name, node in var.nodes.proxmox :
    name => cidrhost(local.pve_mgmt_subnet, node.id)
  }

  pve_cluster_mgmt = "https://${local.pve_node_mgmt[var.nodes.proxmox_cluster.pve.endpoint_node]}:8006"
}

provider "proxmox" {
  endpoint  = local.pve_cluster_mgmt
  api_token = var.pve_api_token
  insecure  = true

  ssh {
    username    = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))

    dynamic "node" {
      for_each = local.pve_node_mgmt

      content {
        name    = node.key
        address = node.value
      }
    }
  }
}
