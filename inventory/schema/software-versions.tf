variable "containers" {
  description = <<-EOT
    Every container image the roots deploy: key => { image, version }. version is a tag ("v1.21.3") or a digest
    ("sha256:..."). Change a version and plan the roots that link this file (services-config, monitoring-config):
    every VM running that container gets the new image.
  EOT
  type = map(object({
    image   = string
    version = string
    digest  = optional(string) # sha256:..., pins the exact image when the tag moves: image:version@digest
  }))

  validation {
    condition = alltrue([
      for c in values(var.containers) :
      can(regex("^[a-z0-9][a-z0-9._/-]*$", c.image)) && !strcontains(c.image, ":") &&
      can(regex("^([A-Za-z0-9_][A-Za-z0-9._-]{0,127}|sha256:[0-9a-f]{64})$", c.version)) &&
      (c.digest == null || can(regex("^sha256:[0-9a-f]{64}$", coalesce(c.digest, "x"))))
    ])
    error_message = "containers: image is a repository without a tag (e.g. docker.io/grafana/alloy), version a tag or sha256:<digest>, digest sha256:<64 hex>."
  }
}

variable "packages" {
  description = <<-EOT
    Debian packages the roots install at a pinned version: name => version. Give the upstream version ("18.6":
    any Debian revision of it, e.g. 18.6-1.pgdg13+2) or a full Debian version ("18.6-1.pgdg13+2"). Today the
    Patroni stack (monitoring-config): postgresql (its major also names the cluster), patroni, etcd, pgbackrest.
  EOT
  type        = map(string)

  validation {
    condition     = alltrue([for k, v in var.packages : can(regex("^[a-z0-9][a-z0-9.+-]*$", k)) && can(regex("^[0-9][A-Za-z0-9.+~:-]*$", v))])
    error_message = "packages: name => version, e.g. postgresql = \"18.6\" or \"18.6-1.pgdg13+2\" (no globs)."
  }

  validation {
    condition     = !contains(keys(var.packages), "postgresql") || try(tonumber(split(".", var.packages["postgresql"])[0]) >= 17, false)
    error_message = "packages.postgresql: the major (before the first dot) must be 17 or later (PGDG on Debian 13)."
  }
}

locals {
  # key => full reference ("repo:tag", "repo:tag@sha256:..." or "repo@sha256:...") as the templates use it.
  container_images = {
    for k, c in var.containers :
    k => "${c.image}${startswith(c.version, "sha256:") ? "@" : ":"}${c.version}${c.digest == null ? "" : "@${c.digest}"}"
  }

  # name => dpkg version glob: "18.6" accepts any Debian revision of 18.6, a full version only itself.
  package_patterns = { for k, v in var.packages : k => strcontains(v, "-") ? v : "${v}-*" }
}
