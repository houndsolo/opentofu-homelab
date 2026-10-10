variable "vm_images" {
  description = "Named existing Proxmox cloud images and their cloud-init snippets."
  type = map(object({
    import_image      = string
    user_data_file_id = optional(string)
    tags              = optional(list(string))
  }))
  default = {}
}
