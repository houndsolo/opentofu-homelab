locals {
  #
  # All leaves this spine talks to, with the spine-side underlay interface.
  # Matches the leaf side in modules/fabric/leaf: coalesce(spine.uplink_if, "eth${spine.id}").
  #
  all_leaves = {
    for name, leaf in var.leaves :
    name => merge(leaf, {
      spine_uplink = coalesce(leaf.spine_uplink, "ether${leaf.id}")
    })
  }
}
