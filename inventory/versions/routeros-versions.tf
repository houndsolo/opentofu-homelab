terraform {
  required_version = ">= 1.9.0"

  required_providers {
    routeros = {
      source  = "local/mechanic/routeros"
      version = "1.99.1"
    }
  }
}
