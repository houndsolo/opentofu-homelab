# RADIUS identity for the FreeRADIUS pair (rad01/rad02): users, groups and RADIUS clients (devices + their
# shared secrets). The servers themselves (VMs, container, sql module, schema) belong to services-vms and
# services-config; this root only manages what the servers know.
#
#   users + groups -> the radius database (radcheck, radusergroup, radgroupreply, radgroupcheck, radreply),
#                     one transaction run on the canary (first radius VM by name) with the host's psql and the
#                     database password services-config put in /etc/radius/radius.env. This root OWNS those five
#                     tables: rows it doesn't declare are deleted. Changes apply to the next login, no restart.
#   clients        -> /etc/radius/clients.conf on every radius VM (mounted into the container by
#                     services-config), one generated secret per client; radius restarts when it changes,
#                     one server at a time, and must answer Status-Server before the next one.
#
# Passwords never live here in clear text: a chosen password is stored as a crypt hash in the git-ignored
# radius.secret.auto.tfvars; a generated one (generate_password = true) is a random_password whose bcrypt hash
# goes to the database and whose value you read with `tofu output`. State and plans are encrypted.
terraform {
  required_version = ">= 1.13.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Every fabric leaf from the inventory (physical fabric.leaves + one VyOS VM per Proxmox node), same module
# the fabric roots use; management address = cidrhost(fabric.settings.management_prefix, id).
module "leaves" {
  source = "../../modules/fabric/leaves"
  fabric = var.fabric
  nodes  = var.nodes
}

locals {
  radius_vms   = { for name, vm in var.vms : name => vm if vm.owner == "services-vms" && vm.role == "radius" }
  radius_names = sort(keys(local.radius_vms))
  canary       = length(local.radius_names) > 0 ? local.radius_names[0] : null
}
