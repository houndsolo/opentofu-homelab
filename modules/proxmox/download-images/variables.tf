variable "images" {
  description = "Pinned image downloads with published SHA512 checksums."
  type = map(object({
    node         = string
    datastore_id = string
    url          = string
    file_name    = string
    checksum     = string
  }))
  validation {
    condition = alltrue([
      for image in values(var.images) : startswith(image.url, "https://") &&
      !strcontains(image.url, "/latest/") && can(regex("^[0-9a-fA-F]{128}$", image.checksum))
    ])
    error_message = "Images need a pinned HTTPS URL (not /latest/) and a 128-character SHA512 checksum."
  }
}
