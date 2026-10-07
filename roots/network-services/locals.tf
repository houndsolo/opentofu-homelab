locals {
  dhcp_segments = {
    for segment in flatten([for vni in var.vnis : values(vni.l2)]) : tostring(segment.vni) => segment
    if segment.dhcp != null
  }
}
