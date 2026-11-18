# RADIUS login (`system login radius`) in its OWN vyoscmd resource: the shared secret makes the command list
# sensitive, and this way only this resource is hidden in plans, not the whole leaf config. VyOS enables pam
# radius in "optional" mode, so local users (vyos) keep working if the servers don't answer. Removing the
# leaf's secret (or fabric.settings.leaf_radius) destroys the resource, which deletes these lines again.
locals {
  radius_enabled = var.fabric.settings.leaf_radius != null && nonsensitive(var.radius != null)

  radius_commands = !local.radius_enabled ? [] : concat(
    [for server in var.radius.servers : "set system login radius server ${server} key '${var.radius.secret}'"],
    var.fabric.settings.leaf_radius.vrf == null ? [] : [
      "set system login radius vrf '${var.fabric.settings.leaf_radius.vrf}'",
    ],
  )
}

resource "vyoscmd_commands" "radius" {
  count    = local.radius_enabled ? 1 : 0
  name     = "${var.name}-radius"
  endpoint = "https://${var.leaf.management_ip}"
  save     = true
  commands = local.radius_commands
}
