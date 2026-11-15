# certs

One Let's Encrypt wildcard certificate, `*.lylat.space` (EC256), validated with the Cloudflare
DNS-01 challenge and copied to every proxy VM (`owner = "services-vms"`, `role = "proxy"` in
[`vms.auto.tfvars`](../../inventory/auto.tfvars/vms.auto.tfvars): proxy01/02). nginx uses it for
every proxied name (grafana, netbox, dark-triage, pve, ...).

| File | What |
| --- | --- |
| `certificate.tf` | ACME account (`acme_registration`, no email) and the certificate (`acme_certificate.svc`) |
| `deploy.tf` | copies `fullchain.pem` (0644) and `privkey.pem` (0600, root) to `/etc/ssl/svc/` on each proxy over SSH (management address), reloads nginx if it runs |
| `state-encryption.tf` | link to the shared state/plan encryption: the state holds the account and certificate keys |
| `*.secret.auto.tfvars` | links to `inventory/auto.tfvars.secret/`: `cloudflare` (API token, Zone:DNS:Edit on lylat.space) and `state` (`state_passphrase`) |

Order: after services-vms (the proxies must exist), before services-config (the proxy deploy stops
if the certificate is missing). The deploy re-runs when the serial (renewal), a proxy's management
address or VM ID, or `certificate.directory` changes.

## Renewal

`acme_certificate` only renews during a plan/apply: inside Let's Encrypt's renewal window
(`use_renewal_info`) or, without one, once a third of the lifetime is left (`min_days_dynamic`).
A daily scheduled `tofu -chdir=roots/certs apply` from a clean worktree does that. Lifetimes: 90
days today, 64 from 2027-02-10, 45 from 2028-02-16.

## Split-horizon DNS

a0-nix resolves `lylat.space` through dns01/dns02, which are authoritative for the internal zone
and never see Cloudflare's `_acme-challenge` TXT records. `recursive_nameservers` points the
propagation check at 1.1.1.1/1.0.0.1; without it every issue/renew waits two minutes and fails.

## Staging vs production

`acme_server` defaults to `production`; `staging` (untrusted certificates, generous rate limits) is
for testing changes to this root. Destroy before switching, so the account is never deactivated
against the wrong server:

```
tofu -chdir=roots/certs destroy                           # account + cert, deploy records (files stay on the VMs)
tofu -chdir=roots/certs apply -var acme_server=staging    # or production (the default)
```

Nothing is revoked on destroy (`revoke_certificate_on_destroy = false`; revoke by hand if a key
leaks); the next apply overwrites the files on the proxies.
