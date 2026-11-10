# Cloud-init resolver for the service VMs (2026-11): without it Proxmox copies the host's
# resolv.conf (nameserver 1.1.1.1, search lylat.space), so lylat.space names don't resolve.
# The DNS VIP answers internal and external names. Only this root sets it (not the shared
# vm-config.auto.tfvars). A change here is a cloud-init change: the provider reboots the VM,
# and cloud-init runs as a new instance (new SSH host keys).
variable "vm_dns" {
  description = "cloud-init DNS for services-vms VMs: servers and search domain. null = leave it to Proxmox."
  type = object({
    servers = list(string)
    domain  = string
  })
  default = {
    servers = ["10.8.53.53"] # DNS VIP (keepalived on dns01/dns02)
    domain  = "lylat.space"
  }
}

variable "vm_dns_vyos" {
  description = "Also give the VyOS VMs (dhcp01/02) the cloud-init DNS. Off by default: on VyOS a new cloud-init instance re-applies the user-data snippet's vyos_config_commands and the network config (system name-server) on the live DHCP pair; manage their resolver in services-config instead, or turn this on deliberately and roll them one at a time."
  type        = bool
  default     = false
}

locals {
  vm_dns_config = {
    dns_servers = try(var.vm_dns.servers, null)
    dns_domain  = try(var.vm_dns.domain, null)
  }
}
