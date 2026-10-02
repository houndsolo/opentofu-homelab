# Add a host networking module here when you are ready.
locals {
  node_networking = {
    for name, node in var.nodes : name => {
      management_ip = node.management_ip
      profile = var.host_networking[node.network_profile]
    }
  }
}
