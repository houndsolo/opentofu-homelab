terraform {
  required_version = ">= 1.9.0"

  required_providers {
    dns = {
      source  = "registry.terraform.io/hashicorp/dns"
      version = "3.6.2"
    }
    random = {
      source  = "registry.terraform.io/hashicorp/random"
      version = "3.9.1"
    }
    proxmox = {
      source  = "local/mechanic/proxmox"
      version = "0.111.0"
    }
  }
}
