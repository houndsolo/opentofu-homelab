# Let's Encrypt certificates for the proxy pair (proxy01/02): *.svc.lylat.space via the Cloudflare
# DNS-01 challenge (vancluever/acme), copied to the proxies over SSH. Renewal runs from a daily
# scheduled apply. State and plans are encrypted (state-encryption.tf): they hold the private keys.
terraform {
  required_version = ">= 1.13.0"
}
