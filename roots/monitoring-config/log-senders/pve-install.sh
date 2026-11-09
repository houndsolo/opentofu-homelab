#!/bin/bash
# Run as root on a PVE node from this folder's files:
#   scp pve-*.conf pve-install.sh root@<node>:/root/ && ssh root@<node> bash /root/pve-install.sh
# Config first, then the package, so rsyslog never starts with Debian's file rules active.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 0755 /etc/rsyslog.d
# 30-: before packages' own rules, e.g. FRR's 45-frr.conf, which writes /var/log/frr/frr.log
# and stops its messages there.
install -m 0644 pve-30-loki.conf /etc/rsyslog.d/30-loki.conf
rm -f /etc/rsyslog.d/50-loki.conf
if [ -f /var/log/ceph/ceph.log ]; then
  install -m 0644 pve-40-ceph-cluster-log.conf /etc/rsyslog.d/40-ceph-cluster-log.conf
fi
if ! dpkg-query -W -f='${Status}' rsyslog 2>/dev/null | grep -q 'ok installed'; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends rsyslog
fi
rsyslogd -N1 >/dev/null
systemctl enable rsyslog.service
systemctl restart rsyslog.service
systemctl is-active --quiet rsyslog.service
rm -f pve-30-loki.conf pve-40-ceph-cluster-log.conf pve-install.sh
