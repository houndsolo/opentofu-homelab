variable "keepalive_time" {
  description = "BGP keepalive interval for both spines, including explicit connection overrides."
  type        = string
  default     = "1m"
}

variable "hold_time" {
  description = "BGP hold time for both spines. Keep keepalive_time at most one third of this."
  type        = string
  default     = "3m"
}
