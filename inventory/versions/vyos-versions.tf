terraform {
  required_version = ">= 1.9.0"

  required_providers {
    vyoscmd = {
      source  = "local/mechanic/vyoscmd"
      version = "0.1.0"
    }
  }
}
