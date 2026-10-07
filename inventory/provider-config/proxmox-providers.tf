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


  pve_cluster_mgmt = "https://10.20.7.11:8006"
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

provider "proxmox" {
  endpoint  = "https://10.20.7.20:8006"
  alias     = "greatfox"
  api_token = var.gf_api_token
  insecure  = true

  ssh {
    username    = "root"
    private_key = file("~/.ssh/id_rsa")
  }
}
