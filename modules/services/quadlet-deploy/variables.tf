variable "name" {
  description = "Deployment name (e.g. \"monitoring\", \"netbox\"): names the list of unit files this deployment manages on the VM, so several deployments can share a VM."
  type        = string
}

variable "host" {
  description = "VM name, for the script's messages."
  type        = string
}

variable "files" {
  description = <<-EOT
    Files to install. `units` are the systemd units the file belongs to. A changed unit file (under
    /etc/containers/systemd or /etc/systemd/system) restarts them; any other changed file reloads them
    (systemctl reload-or-restart: a unit without ExecReload restarts). `restart = true` forces a restart.
    `owner` is numeric uid:gid. `once = true` installs the file only when it doesn't exist yet and never
    touches it again (seed data the service then owns). `stage_only = true` only unpacks it into $stage
    for the deploy's own commands (a one-off secret, a file published elsewhere) and never installs it.
  EOT
  type = list(object({
    path    = string
    content = string
    mode    = optional(string, "0644")
    owner   = optional(string, "0:0")
    units   = optional(list(string), [])
    restart = optional(bool, false)
    once    = optional(bool, false)
    # Unpacked into $stage only, never installed.
    stage_only = optional(bool, false)
  }))
}

variable "units" {
  description = "systemd units of this deployment, in start order. Each is restarted if one of its files asked for it or it isn't running, else reloaded if one of its files changed."
  type        = list(string)
}

variable "dirs" {
  description = "Directories to create with a fixed mode and numeric owner (data directories; parents of files are created 0755 root by themselves)."
  type        = list(object({ path = string, mode = optional(string, "0755"), owner = optional(string, "0:0") }))
  default     = []
}

variable "images" {
  description = "Container images to pull before anything is installed."
  type        = list(string)
  default     = []
}

variable "packages" {
  description = "Debian packages installed when missing (unpinned; version pins go through setup)."
  type        = list(string)
  default     = []
}

variable "setup" {
  description = "Shell commands run first, before anything is unpacked (sysctl, pinned packages, mounts)."
  type        = list(string)
  default     = []
}

variable "checks" {
  description = "Shell commands that validate the staged files ($stage mirrors /) before anything is installed. A failure stops the deploy."
  type        = list(string)
  default     = []
}

variable "pre_install" {
  description = "Shell commands run after the checks passed and before anything is installed ($stage holds the new files; e.g. hand a VIP to a peer when a unit is about to restart)."
  type        = list(string)
  default     = []
}

variable "post_install" {
  description = "Shell commands run after the files are installed and systemd reloaded, before units are restarted (e.g. systemctl enable of host units)."
  type        = list(string)
  default     = []
}

variable "verify" {
  description = "Shell commands run after the units are up, for checks the units' own HealthCmd can't do (a VIP, another host). Prefix with `retry` to wait up to two minutes."
  type        = list(string)
  default     = []
}

variable "prune_dirs" {
  description = "Directories (which must receive at least one file) where files this deployment doesn't install are deleted (dashboards)."
  type        = list(string)
  default     = []
}
