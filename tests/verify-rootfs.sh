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
mgmt_plugin="$(find "$ROOTFS/usr/lib/rabbitmq" -type d -name 'rabbitmq_management-*' -print -quit)"
[[ -n "$mgmt_plugin" ]] || { echo 'rabbitmq_management plugin is missing from rootfs' >&2; exit 1; }
delayed_plugin="$(find "$ROOTFS/usr/lib/rabbitmq" -type f -name "$DELAYED_PLUGIN_FILE" -print -quit)"
[[ -n "$delayed_plugin" ]] || { echo "Delayed-message plugin is missing from rootfs: $DELAYED_PLUGIN_FILE" >&2; exit 1; }
actual_plugin_sha256="$(sha256sum "$delayed_plugin" | awk '{print $1}')"
[[ "$actual_plugin_sha256" == "$DELAYED_PLUGIN_SHA256" ]] \
  || { echo "Delayed-message plugin checksum mismatch: expected $DELAYED_PLUGIN_SHA256, got $actual_plugin_sha256" >&2; exit 1; }
version_out="$(chroot "$ROOTFS" /usr/sbin/rabbitmqctl version 2>/dev/null || true)"
grep -Fq "$RABBITMQ_UPSTREAM_VERSION" <<<"$version_out" \
  || { echo "rabbitmqctl version mismatch: expected $RABBITMQ_UPSTREAM_VERSION in: $version_out" >&2; exit 1; }
echo 'rootfs verification passed'
