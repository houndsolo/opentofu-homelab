variable "name" {
  type = string
}
variable "overlay_as" {
  type = number
}
variable "leaf" {
  type = object({
    management_ip = string
    router_id = string
    vtep_ipv6 = string
  })
}
