terraform {
  required_version = ">= 1.9.0"
  required_providers {
    vyoscmd = {
      source  = "local/mechanic/vyoscmd"
      version = "0.1.0"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
