terraform {
  required_version = ">= 1.9.0"
  required_providers {
    proxmox = {
      source  = "local/mechanic/proxmox"
      version = "0.111.0"
    }
  }
}
