#!/bin/bash
# Grafana Alloy for the Ceph daemon logs (DT-021). Run as root on a PVE node from this folder's files:
#   scp pve-alloy.config.alloy pve-alloy-install.sh root@<node>:/root/ && ssh root@<node> bash /root/pve-alloy-install.sh
# Optional: put alloy-1.21.3-1.amd64.deb next to them, otherwise the node downloads it from GitHub.
# Either way the .deb must match the SHA-256 below. Idempotent: re-run after changing the config.
#
# Package: Grafana's GitHub release .deb, pinned by version + checksum, same Alloy as the VMs' container
# (docker.io/grafana/alloy:v1.21.3). No apt repository is added, so `apt full-upgrade` on the hypervisor
# never moves Alloy; upgrade = new version + checksum here, re-run. The package ships alloy.service
# (User=alloy, EnvironmentFile=/etc/default/alloy, storage /var/lib/alloy/data), does not enable or start
# it on first install, and creates the alloy user (groups adm, systemd-journal).
# Our files (the package's conffiles /etc/default/alloy and /etc/alloy/config.alloy stay as shipped,
# so upgrades never stop at a conffile prompt):
#   /etc/alloy/pve.alloy                        <- pve-alloy.config.alloy
#   /etc/alloy/pve.env                          CONFIG_FILE + CUSTOM_ARGS (HTTP on the node's 10.5 address)
#   /etc/systemd/system/alloy.service.d/pve.conf  reads pve.env after /etc/default/alloy; sandboxing
#   ACL u:alloy:r-x on /var/log/ceph            (dir is ceph:ceph 2770; the daemon logs are 0644)
set -euo pipefail
cd "$(dirname "$0")"

ALLOY_VERSION=1.21.3
ALLOY_DEB="alloy-${ALLOY_VERSION}-1.amd64.deb"
ALLOY_SHA256=dbbd705de8ab37dec0cbd6361a3fc7e754d6b2854b57ce672a83e6366199ba73
ALLOY_URL="https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/${ALLOY_DEB}"
HTTP_PORT=12345

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f pve-alloy.config.alloy ] || { echo "pve-alloy.config.alloy missing next to $0" >&2; exit 1; }

# Alloy's HTTP server (/metrics, /-/ready, UI) on the node's monitoring (VLAN 5) address, where
# Prometheus already scrapes node_exporter (10.5.1.<id>:9100). Loopback if the node has none.
listen=$(ip -4 -o addr show | awk '$4 ~ /^10\.5\./ { split($4, a, "/"); print a[1]; exit }')
listen=${listen:-127.0.0.1}

# 1. Package (only when this exact version isn't installed).
if [ "$(dpkg-query -W -f='${Status} ${Version}' alloy 2>/dev/null || true)" != "install ok installed ${ALLOY_VERSION}-1" ]; then
  [ -f "$ALLOY_DEB" ] || curl -fsSL --retry 3 -o "$ALLOY_DEB" "$ALLOY_URL"
  echo "${ALLOY_SHA256}  ${ALLOY_DEB}" | sha256sum -c --quiet -
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends --allow-downgrades \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "./${ALLOY_DEB}"
fi
/usr/bin/alloy --version 2>&1 | sed -n 1p

# 2. Config, environment, unit drop-in.
/usr/bin/alloy fmt pve-alloy.config.alloy >/dev/null   # syntax check before it goes live
install -m 0640 -o root -g alloy pve-alloy.config.alloy /etc/alloy/pve.alloy
cat >/etc/alloy/pve.env.new <<EOF
# Managed by roots/monitoring-config/log-senders/pve-alloy-install.sh (DT-021). Read after /etc/default/alloy.
CONFIG_FILE=/etc/alloy/pve.alloy
CUSTOM_ARGS="--server.http.listen-addr=${listen}:${HTTP_PORT} --disable-reporting"
EOF
install -m 0640 -o root -g alloy /etc/alloy/pve.env.new /etc/alloy/pve.env
rm -f /etc/alloy/pve.env.new
install -d -m 0755 /etc/systemd/system/alloy.service.d
cat >/etc/systemd/system/alloy.service.d/pve.conf <<'EOF'
# Managed by roots/monitoring-config/log-senders/pve-alloy-install.sh (DT-021).
[Service]
# Read after the package's EnvironmentFile=/etc/default/alloy, so CONFIG_FILE/CUSTOM_ARGS here win.
EnvironmentFile=/etc/alloy/pve.env
# Hypervisor guard rails: Alloy only reads logs and writes positions/WAL under /var/lib/alloy.
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/alloy
ProtectHome=yes
PrivateTmp=yes
MemoryMax=1G
Nice=10
EOF

# 3. Read access to the Ceph daemon logs: traverse /var/log/ceph (ceph:ceph 2770) via a named-user ACL,
#    not group ceph (that group may write there). ceph-common's postinst chmods the dir on upgrades;
#    chmod keeps named ACL entries, and re-running this script re-asserts it anyway.
if [ -d /var/log/ceph ]; then
  setfacl -m u:alloy:rx /var/log/ceph
  for f in /var/log/ceph/ceph-osd.*.log /var/log/ceph/ceph-mon.*.log /var/log/ceph/ceph-mgr.*.log \
           /var/log/ceph/ceph-mds.*.log /var/log/ceph/ceph-client.rgw.*.log; do
    [ -f "$f" ] || continue
    setpriv --reuid=alloy --regid=alloy --init-groups head -c 0 "$f" || { echo "alloy can't read $f" >&2; exit 1; }
  done
fi

# 4. (Re)start and check.
systemctl daemon-reload
systemctl enable --quiet alloy.service
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart alloy.service
for _ in $(seq 1 30); do
  curl -fs -m 2 -o /dev/null "http://${listen}:${HTTP_PORT}/-/ready" && break
  sleep 1
done
systemctl is-active --quiet alloy.service
curl -fsS -m 2 -o /dev/null "http://${listen}:${HTTP_PORT}/-/ready"
if journalctl -u alloy.service --since "$since" --no-pager -o cat | grep -E "invalid stage|failed to evaluate config|Failed to build|permission denied"; then
  echo "alloy started with errors (above)" >&2
  exit 1
fi
echo "alloy ${ALLOY_VERSION} running on $(hostname -s), http://${listen}:${HTTP_PORT}"
rm -f pve-alloy.config.alloy "$ALLOY_DEB" pve-alloy-install.sh
