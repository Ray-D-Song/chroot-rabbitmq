#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-rabbitmq
DATA_DIR=/var/lib/chroot-rabbitmq/data
CONF_DIR=/etc/chroot-rabbitmq/conf
LOG_DIR=/var/log/chroot-rabbitmq
CREDENTIALS=/etc/chroot-rabbitmq/credentials
SERVICE_NAME=chroot-rabbitmq
PORT=5672
MGMT_PORT=15672
BIND_ADDRESS=127.0.0.1
NODENAME=rabbit@localhost
RABBITMQ_USER=admin
PASSWORD_CLI=''

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --prefix PATH             Rootfs install directory (default: $PREFIX)
  --data-dir PATH           Persistent data directory (default: $DATA_DIR)
  --conf-dir PATH           Persistent configuration directory (default: $CONF_DIR)
  --log-dir PATH            Persistent log directory (default: $LOG_DIR)
  --port PORT               AMQP port (default: $PORT)
  --mgmt-port PORT          Management HTTP port (default: $MGMT_PORT)
  --bind-address ADDRESS    AMQP bind address (default: $BIND_ADDRESS)
  --service-name NAME       systemd service name (default: $SERVICE_NAME)
  --credentials-file PATH   Root-only credentials file (default: $CREDENTIALS)
  --password VALUE          admin password for a new instance (or set CHROOT_RABBITMQ_PASSWORD)
EOF
}

validate_password() {
  local pw="$1"
  [[ -n "$pw" ]] || { echo 'password must not be empty' >&2; exit 2; }
  (( ${#pw} >= 8 )) || { echo 'password must be at least 8 characters' >&2; exit 2; }
  [[ "${pw//$'\n'}" == "$pw" ]] || { echo 'password must not contain newline' >&2; exit 2; }
  (( $(printf '%s' "$pw" | tr -cd '\0' | wc -c) == 0 )) \
    || { echo 'password must not contain null bytes' >&2; exit 2; }
  [[ ! "$pw" =~ [[:cntrl:]] ]] || { echo 'password must not contain control characters' >&2; exit 2; }
}

password_was_provided() {
  [[ -n "$PASSWORD_CLI" || -n "${CHROOT_RABBITMQ_PASSWORD:-}" ]]
}

warn_if_password_ignored() {
  if password_was_provided; then
    echo 'Warning: existing data directory detected; --password and CHROOT_RABBITMQ_PASSWORD were ignored.' >&2
  fi
}

resolve_password_for_new_install() {
  if [[ -n "$PASSWORD_CLI" ]]; then
    password="$PASSWORD_CLI"
    echo "Using password from --password. It will be stored in $CREDENTIALS (root only)."
  elif [[ -n "${CHROOT_RABBITMQ_PASSWORD:-}" ]]; then
    password="$CHROOT_RABBITMQ_PASSWORD"
    echo "Using password from CHROOT_RABBITMQ_PASSWORD. It will be stored in $CREDENTIALS (root only)."
  else
    password="$(openssl rand -hex 32)"
    echo "Generated RabbitMQ password. It is stored in $CREDENTIALS (root only)."
  fi
  validate_password "$password"
}

read_credentials_file() {
  password="$(awk -F= '$1 == "RABBITMQ_PASSWORD" { print substr($0, index($0, "=") + 1) }' "$CREDENTIALS")"
  [[ -n "$password" ]] || { echo "credentials file has no RABBITMQ_PASSWORD: $CREDENTIALS" >&2; exit 1; }
  RABBITMQ_USER="$(awk -F= '$1 == "RABBITMQ_USER" { print substr($0, index($0, "=") + 1) }' "$CREDENTIALS")"
  [[ -n "$RABBITMQ_USER" ]] || { echo "credentials file has no RABBITMQ_USER: $CREDENTIALS" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--conf-dir|--log-dir|--port|--mgmt-port|--bind-address|--service-name|--credentials-file|--password)
      key="$1"; shift; [[ $# -gt 0 ]] || { echo "missing value for $key" >&2; exit 2; }
      case "$key" in
        --prefix) PREFIX="$1" ;;
        --data-dir) DATA_DIR="$1" ;;
        --conf-dir) CONF_DIR="$1" ;;
        --log-dir) LOG_DIR="$1" ;;
        --port) PORT="$1" ;;
        --mgmt-port) MGMT_PORT="$1" ;;
        --bind-address) BIND_ADDRESS="$1" ;;
        --service-name) SERVICE_NAME="$1" ;;
        --credentials-file) CREDENTIALS="$1" ;;
        --password) PASSWORD_CLI="$1" ;;
      esac
      shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'run install.sh with sudo or as root' >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo 'chroot-rabbitmq supports Linux amd64 only' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo 'port must be 1..65535' >&2; exit 2; }
[[ "$MGMT_PORT" =~ ^[0-9]+$ ]] && (( MGMT_PORT >= 1 && MGMT_PORT <= 65535 )) || { echo 'mgmt-port must be 1..65535' >&2; exit 2; }
[[ "$BIND_ADDRESS" =~ ^[a-zA-Z0-9.:_-]+$ ]] || { echo 'invalid bind address' >&2; exit 2; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo 'invalid service name' >&2; exit 2; }
[[ "$PREFIX" == /* && "$PREFIX" != / && "$DATA_DIR" == /* && "$DATA_DIR" != / ]] \
  || { echo 'prefix and data-dir must be non-root absolute paths' >&2; exit 2; }
[[ "$CONF_DIR" == /* && "$CONF_DIR" != / ]] || { echo 'conf-dir must be a non-root absolute path' >&2; exit 2; }
[[ "$LOG_DIR" == /* && "$LOG_DIR" != / ]] || { echo 'log-dir must be a non-root absolute path' >&2; exit 2; }
[[ "$CREDENTIALS" == /* && "$CREDENTIALS" != / ]] || { echo 'credentials-file must be a non-root absolute path' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOTFS="$SCRIPT_DIR/rootfs"
[[ -x "$SOURCE_ROOTFS/usr/sbin/rabbitmq-server" ]] || { echo "rootfs is missing from $SOURCE_ROOTFS" >&2; exit 1; }

cleanup_mounts() {
  umount "$PREFIX/rootfs/var/log/rabbitmq" 2>/dev/null || true
  umount "$PREFIX/rootfs/etc/rabbitmq" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/rabbitmq" 2>/dev/null || true
}

rabbitmqctl_chroot() {
  chroot "$PREFIX/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C \
    /usr/sbin/rabbitmqctl -n "$NODENAME" "$@"
}

wait_for_rabbitmq_ready() {
  local i
  for i in $(seq 1 60); do
    if rabbitmqctl_chroot ping >/dev/null 2>&1; then
      rabbitmqctl_chroot await_startup --timeout 60
      return 0
    fi
    sleep 1
  done
  echo "RabbitMQ did not become ready (node $NODENAME)" >&2
  return 1
}

if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl stop "$SERVICE_NAME"; fi
mkdir -p "$PREFIX" "$(dirname "$CREDENTIALS")"
chmod 0750 "$(dirname "$CREDENTIALS")"

new_rootfs="$PREFIX/rootfs.new"
rm -rf "$new_rootfs"
cp -a "$SOURCE_ROOTFS" "$new_rootfs"
if [[ -d "$PREFIX/rootfs" ]]; then rm -rf "$PREFIX/rootfs"; fi
mv "$new_rootfs" "$PREFIX/rootfs"
install -D -m 0755 "$SCRIPT_DIR/bin/chroot-rabbitmq-run" "$PREFIX/bin/chroot-rabbitmq-run"

RABBITMQ_UID="$(chroot "$PREFIX/rootfs" id -u rabbitmq)"
RABBITMQ_GID="$(chroot "$PREFIX/rootfs" id -g rabbitmq)"

mkdir -p "$DATA_DIR" "$CONF_DIR" "$LOG_DIR"
chown "$RABBITMQ_UID:$RABBITMQ_GID" "$DATA_DIR" "$CONF_DIR" "$LOG_DIR"
chmod 0750 "$DATA_DIR" "$CONF_DIR" "$LOG_DIR"

data_has_state=false
if [[ -d "$DATA_DIR/mnesia" || -f "$DATA_DIR/.erlang.cookie" ]]; then data_has_state=true; fi
needs_bootstrap=false
if [[ "$data_has_state" == true ]]; then
  [[ -f "$CREDENTIALS" ]] || { echo "existing data directory requires credentials file: $CREDENTIALS" >&2; exit 1; }
  read_credentials_file
  warn_if_password_ignored
elif [[ -f "$CREDENTIALS" ]]; then
  read_credentials_file
  warn_if_password_ignored
else
  resolve_password_for_new_install
  needs_bootstrap=true
fi

umask 077
install -m 0600 /dev/null "$CREDENTIALS"
cat > "$CREDENTIALS" <<EOF
RABBITMQ_USER=$RABBITMQ_USER
RABBITMQ_PASSWORD=$password
RABBITMQ_AMQP_PORT=$PORT
RABBITMQ_MGMT_PORT=$MGMT_PORT
EOF

MANAGED_BEGIN='# BEGIN chroot-rabbitmq managed settings'
MANAGED_END='# END chroot-rabbitmq managed settings'
write_managed_block() {
  local target="$1" tmp
  tmp="$(mktemp)"
  { printf '%s\n' "$MANAGED_BEGIN"; cat; printf '%s\n' "$MANAGED_END"; } > "$tmp"
  if [[ -f "$target" ]]; then
    awk -v head="$MANAGED_BEGIN" -v tail="$MANAGED_END" '
      $0 == head { inside = 1; next }
      $0 == tail { inside = 0; next }
      inside == 0 { print }
    ' "$target" >> "$tmp"
  else
    cat >> "$tmp" <<'HINT'

# Add custom directives below this line. They override the managed block above.
# The annotated upstream reference lives in the rootfs at /usr/share/rabbitmq/rabbitmq.conf.reference.
HINT
  fi
  cat "$tmp" > "$target"
  rm -f "$tmp"
  chown "$RABBITMQ_UID:$RABBITMQ_GID" "$target"
  chmod 0600 "$target"
}

write_managed_block "$CONF_DIR/rabbitmq.conf" <<EOF
listeners.tcp.1 = $BIND_ADDRESS:$PORT
management.tcp.port = $MGMT_PORT
loopback_users = none
EOF

cat > "$CONF_DIR/rabbitmq-env.conf" <<EOF
NODENAME=$NODENAME
MNESIA_BASE=/var/lib/rabbitmq/mnesia
HOME=/var/lib/rabbitmq
EOF
chown "$RABBITMQ_UID:$RABBITMQ_GID" "$CONF_DIR/rabbitmq-env.conf"
chmod 0600 "$CONF_DIR/rabbitmq-env.conf"
printf '%s\n' '[rabbitmq_management].' > "$CONF_DIR/enabled_plugins"
chown "$RABBITMQ_UID:$RABBITMQ_GID" "$CONF_DIR/enabled_plugins"
chmod 0644 "$CONF_DIR/enabled_plugins"

if [[ "$needs_bootstrap" == true ]]; then
  install -d -o "$RABBITMQ_UID" -g "$RABBITMQ_GID" -m 0750 \
    "$PREFIX/rootfs/var/lib/rabbitmq" "$PREFIX/rootfs/etc/rabbitmq" "$PREFIX/rootfs/var/log/rabbitmq"
  mount --bind "$DATA_DIR" "$PREFIX/rootfs/var/lib/rabbitmq"
  mount --bind "$CONF_DIR" "$PREFIX/rootfs/etc/rabbitmq"
  mount --bind "$LOG_DIR" "$PREFIX/rootfs/var/log/rabbitmq"
  trap cleanup_mounts EXIT
  chroot "$PREFIX/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C /usr/sbin/rabbitmq-server -detached
  wait_for_rabbitmq_ready
  chroot "$PREFIX/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C \
    /usr/sbin/rabbitmq-plugins enable rabbitmq_management
  rabbitmqctl_chroot add_user "$RABBITMQ_USER" "$password"
  rabbitmqctl_chroot set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"
  rabbitmqctl_chroot set_user_tags "$RABBITMQ_USER" administrator
  rabbitmqctl_chroot delete_user guest 2>/dev/null || true
  rabbitmqctl_chroot stop
  cleanup_mounts
  trap - EXIT
fi

sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@DATA_DIR@|$DATA_DIR|g" \
  -e "s|@CONF_DIR@|$CONF_DIR|g" -e "s|@LOG_DIR@|$LOG_DIR|g" \
  "$SCRIPT_DIR/systemd/chroot-rabbitmq.service.in" > "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Installed $SERVICE_NAME. Check: systemctl status $SERVICE_NAME"
