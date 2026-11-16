locals {
  unit_dirs = ["/etc/containers/systemd", "/etc/systemd/system"]

  script = templatefile("${path.module}/deploy.sh.tftpl", {
    name         = var.name
    host         = var.host
    files        = var.files
    installed    = [for f in var.files : f if !f.stage_only]
    units        = var.units
    dirs         = var.dirs
    images       = var.images
    packages     = var.packages
    setup        = var.setup
    checks       = var.checks
    pre_install  = var.pre_install
    post_install = var.post_install
    verify       = var.verify
    prune_dirs   = var.prune_dirs
    # "restart", "reload" or "once" per file path.
    action = { for f in var.files : f.path => f.once ? "once" : f.restart || contains(local.unit_dirs, dirname(f.path)) ? "restart" : "reload" }
    # Unit files this deployment manages: one that disappears from the list is stopped and removed.
    unit_files = [for f in var.files : f.path if contains(local.unit_dirs, dirname(f.path)) && !f.stage_only]
  })
}
