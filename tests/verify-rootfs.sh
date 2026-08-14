#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs.sh <rootfs>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"

[[ -x "$ROOTFS/usr/sbin/rabbitmq-server" ]]
[[ -x "$ROOTFS/usr/sbin/rabbitmqctl" ]]
[[ -x "$ROOTFS/usr/sbin/rabbitmq-diagnostics" ]]
[[ -f "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference" ]] \
  || { echo "rabbitmq.conf.reference is missing" >&2; exit 1; }
actual="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' rabbitmq-server)"
[[ "$actual" == "$RABBITMQ_PACKAGE_VERSION" ]] || { echo "RabbitMQ version mismatch: expected $RABBITMQ_PACKAGE_VERSION, got $actual" >&2; exit 1; }
chroot "$ROOTFS" /usr/sbin/rabbitmq-plugins list -s | grep -q 'rabbitmq_management'
chroot "$ROOTFS" /usr/sbin/rabbitmqctl version | grep -Fq "$RABBITMQ_UPSTREAM_VERSION"
echo 'rootfs verification passed'
