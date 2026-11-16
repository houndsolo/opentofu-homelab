#!/bin/bash
# Managed by OpenTofu (services-config, main.tf): bind9.service's ExecReload. SIGHUP = rndc reload (there is
# no rndc channel): named re-reads named.conf and the key, keeps its cache and never drops queries. Fails
# unless named logs that the reload succeeded: on a failed reload it keeps running with the old config.
set -euo pipefail
since=$(date +%s)
podman kill --signal HUP bind9 >/dev/null
for _ in $(seq 1 30); do
  result=$(podman logs --since "$since" bind9 2>&1 | grep -oE 'reloading configuration (succeeded|failed.*)' | tail -n 1 || true)
  if [ -n "$result" ]; then
    echo "bind9: $result"
    [ "$result" = "reloading configuration succeeded" ]
    exit 0
  fi
  sleep 1
done
echo "bind9: no reload result logged in 30 s" >&2
exit 1
