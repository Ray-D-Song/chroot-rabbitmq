#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ROOTFS="$BUILD_DIR/rootfs"

[[ "$(uname -m)" == "x86_64" ]] || { echo 'only amd64 hosts are supported' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'run build-rootfs.sh with sudo' >&2; exit 1; }
command -v debootstrap >/dev/null || { echo 'debootstrap is required' >&2; exit 1; }

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
debootstrap --arch=amd64 --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates gnupg curl apt-transport-https
  rm -rf /var/lib/apt/lists/* /var/cache/apt/*
'

install -d -m 0755 "$ROOTFS/usr/share/keyrings"
curl -1sLf "$RABBITMQ_APT_KEY_URL" | gpg --dearmor > "$ROOTFS/usr/share/keyrings/com.rabbitmq.team.gpg"
chmod 0644 "$ROOTFS/usr/share/keyrings/com.rabbitmq.team.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/rabbitmq.list" <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-server/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-server/debian/bookworm bookworm main
EOF

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    erlang-base erlang-asn1 erlang-crypto erlang-eldap erlang-ftp erlang-inets \
    erlang-mnesia erlang-os-mon erlang-parsetools erlang-public-key \
    erlang-runtime-tools erlang-snmp erlang-ssl erlang-syntax-tools erlang-tftp \
    erlang-tools erlang-xmerl \
    rabbitmq-server="'"$RABBITMQ_PACKAGE_VERSION"'"
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
  rm -rf /var/lib/rabbitmq/* /var/log/rabbitmq/*
  rm -f /usr/sbin/policy-rc.d /etc/machine-id
'

actual="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' rabbitmq-server)"
[[ "$actual" == "$RABBITMQ_PACKAGE_VERSION" ]] || { echo "RabbitMQ version mismatch: expected $RABBITMQ_PACKAGE_VERSION, got $actual" >&2; exit 1; }
cat > "$ROOTFS/etc/chroot-rabbitmq-build.env" <<EOF
RABBITMQ_PACKAGE_VERSION=$actual
RABBITMQ_UPSTREAM_VERSION=$RABBITMQ_UPSTREAM_VERSION
EOF
if [[ -f "$ROOTFS/etc/rabbitmq/rabbitmq.conf" ]]; then
  install -D -m 0644 "$ROOTFS/etc/rabbitmq/rabbitmq.conf" "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference"
elif [[ -f "$ROOTFS/usr/share/doc/rabbitmq-server/examples/rabbitmq.conf.example" ]]; then
  install -D -m 0644 "$ROOTFS/usr/share/doc/rabbitmq-server/examples/rabbitmq.conf.example" \
    "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference"
elif [[ -f "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.example" ]]; then
  install -D -m 0644 "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.example" \
    "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference"
else
  install -d -m 0755 "$ROOTFS/usr/share/rabbitmq"
  curl -fsSL "https://raw.githubusercontent.com/rabbitmq/rabbitmq-server/v${RABBITMQ_UPSTREAM_VERSION}/deps/rabbit/docs/rabbitmq.conf.example" \
    -o "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference"
  chmod 0644 "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference"
fi
[[ -f "$ROOTFS/usr/share/rabbitmq/rabbitmq.conf.reference" ]] \
  || { echo 'failed to install rabbitmq.conf.reference' >&2; exit 1; }
install -d -m 0755 "$ROOTFS/etc/rabbitmq" "$ROOTFS/var/lib/rabbitmq" "$ROOTFS/var/log/rabbitmq"
echo "rootfs ready: $ROOTFS"
