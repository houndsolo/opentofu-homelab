output "certificate" {
  description = "The deployed certificate (no key material)."
  value = {
    server       = var.acme_server
    domain       = acme_certificate.svc.certificate_domain
    serial       = acme_certificate.svc.certificate_serial
    not_after    = acme_certificate.svc.certificate_not_after
    renew_window = try("${acme_certificate.svc.renewal_info_window_start} .. ${acme_certificate.svc.renewal_info_window_end}", null)
    deployed_to  = sort(keys(local.proxy_vms))
  }
}
