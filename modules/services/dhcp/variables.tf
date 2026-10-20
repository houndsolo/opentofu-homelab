variable "name" {
  description = "DHCP VM name from inventory."
  type        = string
}

variable "management_ip" {
  description = "DHCP VM OOB IPv4 address, without the CIDR prefix."
  type        = string
}
