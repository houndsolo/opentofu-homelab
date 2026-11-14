#!/bin/bash
# Run as root on a PVE node from this folder's files (cluster nodes and greatfox alike):
#   scp pve-https-redirect.nft pve-https-redirect.service pve-https-install.sh root@<node>:/root/ \
#     && ssh root@<node> bash /root/pve-https-install.sh
# Makes https://<node>.lylat.space work without :8006 (443 -> 8006 on the node's own addresses). The
# certificate is PVE's own ACME one (pvenode config: acme account=mechanic, acmedomain0
# <node>.lylat.space,plugin=cloudflare), renewed by pve-daily-update.
set -euo pipefail
cd "$(dirname "$0")"
nft -c -f pve-https-redirect.nft
install -m 0644 pve-https-redirect.nft /etc/pve-https-redirect.nft
install -m 0644 pve-https-redirect.service /etc/systemd/system/pve-https-redirect.service
systemctl daemon-reload
systemctl enable pve-https-redirect.service
systemctl restart pve-https-redirect.service
nft list table ip pve_https >/dev/null
rm -f pve-https-redirect.nft pve-https-redirect.service pve-https-install.sh
