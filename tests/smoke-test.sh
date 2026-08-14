#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: smoke-test.sh <bundle.tar.gz>}"
TEST_ID="${2:-${GITHUB_RUN_ID:-local}-${RANDOM}}"
WORK_DIR="$(mktemp -d /tmp/chroot-rabbitmq-test.XXXXXX)"
PREFIX="/opt/chroot-rabbitmq-test-$TEST_ID"
DATA_DIR="/var/lib/chroot-rabbitmq-test-$TEST_ID"
CONF_DIR="/etc/chroot-rabbitmq-test-$TEST_ID/conf"
LOG_DIR="/var/log/chroot-rabbitmq-test-$TEST_ID"
SERVICE="chroot-rabbitmq-test-$TEST_ID"
PORT="$(( 20000 + RANDOM % 20000 ))"
MGMT_PORT="$(( 20000 + RANDOM % 20000 ))"
CREDENTIALS="/etc/chroot-rabbitmq-test-$TEST_ID/credentials"
NODENAME=rabbit@localhost
PACKAGE_DIR=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
      --log-dir "$LOG_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  rm -rf "$PREFIX" "$DATA_DIR" "$CONF_DIR" "$LOG_DIR" "$(dirname "$CREDENTIALS")" "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
"$PACKAGE_DIR/install.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --log-dir "$LOG_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" \
  --port "$PORT" --mgmt-port "$MGMT_PORT" --bind-address 127.0.0.1
systemctl is-active --quiet "$SERVICE"
[[ "$(grep -c '^# BEGIN chroot-rabbitmq managed settings$' "$CONF_DIR/rabbitmq.conf")" == 1 ]] \
  || { echo 'managed block is missing or duplicated' >&2; exit 1; }

source "$CREDENTIALS"

mgmt_api() {
  curl -sf -u "$RABBITMQ_USER:$RABBITMQ_PASSWORD" "$@"
}

queue_smoke_test() {
  local mgmt_base="http://127.0.0.1:${RABBITMQ_MGMT_PORT}/api"
  mgmt_api -X PUT "${mgmt_base}/queues/%2F/ci_smoke" \
    -H 'content-type: application/json' \
    -d '{"durable":true,"auto_delete":false,"arguments":{}}'
  mgmt_api -X POST "${mgmt_base}/exchanges/%2F/amq.default/publish" \
    -H 'content-type: application/json' \
    -d '{"properties":{},"routing_key":"ci_smoke","payload":"ok","payload_encoding":"string"}'
  local payload
  payload="$(mgmt_api -X POST "${mgmt_base}/queues/%2F/ci_smoke/get" \
    -H 'content-type: application/json' \
    -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}')"
  grep -F 'ok' <<<"$payload" || { echo "queue get missing payload: $payload" >&2; exit 1; }
}

mount_rabbitmq_paths() {
  local prefix="$1" data_dir="$2" conf_dir="$3" log_dir="$4"
  mkdir -p "$prefix/rootfs/var/lib/rabbitmq" "$prefix/rootfs/etc/rabbitmq" "$prefix/rootfs/var/log/rabbitmq" "$prefix/rootfs/proc"
  mount --bind "$data_dir" "$prefix/rootfs/var/lib/rabbitmq"
  mount --bind "$conf_dir" "$prefix/rootfs/etc/rabbitmq"
  mount --bind "$log_dir" "$prefix/rootfs/var/log/rabbitmq"
  mount -t proc proc "$prefix/rootfs/proc"
}

umount_rabbitmq_paths() {
  local prefix="$1"
  umount "$prefix/rootfs/proc" 2>/dev/null || true
  umount "$prefix/rootfs/var/log/rabbitmq" 2>/dev/null || true
  umount "$prefix/rootfs/etc/rabbitmq" 2>/dev/null || true
  umount "$prefix/rootfs/var/lib/rabbitmq" 2>/dev/null || true
}

rabbitmqctl_exec() {
  local prefix="$1" data_dir="$2" conf_dir="$3" log_dir="$4" rc=0
  shift 4
  mount_rabbitmq_paths "$prefix" "$data_dir" "$conf_dir" "$log_dir"
  chroot "$prefix/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C \
    /usr/sbin/rabbitmqctl -n "$NODENAME" "$@" || rc=$?
  umount_rabbitmq_paths "$prefix"
  return "$rc"
}

wait_for_rabbitmq() {
  local prefix="$1" data_dir="$2" conf_dir="$3" log_dir="$4" i
  mount_rabbitmq_paths "$prefix" "$data_dir" "$conf_dir" "$log_dir"
  for i in $(seq 1 60); do
    if chroot "$prefix/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C \
         /usr/sbin/rabbitmqctl -n "$NODENAME" ping >/dev/null 2>&1; then
      if chroot "$prefix/rootfs" env HOME=/var/lib/rabbitmq LANG=C LC_ALL=C \
           /usr/sbin/rabbitmqctl -n "$NODENAME" await_startup --timeout 1 >/dev/null 2>&1; then
        umount_rabbitmq_paths "$prefix"
        return 0
      fi
    fi
    sleep 1
  done
  umount_rabbitmq_paths "$prefix"
  echo "RabbitMQ did not become ready on ports $PORT/$MGMT_PORT" >&2
  return 1
}

wait_for_rabbitmq "$PREFIX" "$DATA_DIR" "$CONF_DIR" "$LOG_DIR"
auth_out="$(rabbitmqctl_exec "$PREFIX" "$DATA_DIR" "$CONF_DIR" "$LOG_DIR" \
  authenticate_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD")"
grep -Fx 'Success' <<<"$auth_out" || { echo "authenticate_user failed: $auth_out" >&2; exit 1; }
queue_smoke_test

systemctl restart "$SERVICE"
wait_for_rabbitmq "$PREFIX" "$DATA_DIR" "$CONF_DIR" "$LOG_DIR"
queue_smoke_test

"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --log-dir "$LOG_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -d "$DATA_DIR/mnesia" ]] || { echo 'uninstall unexpectedly removed RabbitMQ data' >&2; exit 1; }
[[ -f "$CONF_DIR/rabbitmq.conf" ]] || { echo 'uninstall unexpectedly removed configuration' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" \
  --log-dir "$LOG_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" && ! -e "$CONF_DIR" && ! -e "$LOG_DIR" ]] \
  || { echo 'purge-data did not remove test data' >&2; exit 1; }

# Custom password via environment variable on a fresh install.
CUSTOM_TEST_ID="${TEST_ID}-custom"
CUSTOM_PREFIX="/opt/chroot-rabbitmq-test-$CUSTOM_TEST_ID"
CUSTOM_DATA_DIR="/var/lib/chroot-rabbitmq-test-$CUSTOM_TEST_ID"
CUSTOM_CONF_DIR="/etc/chroot-rabbitmq-test-$CUSTOM_TEST_ID/conf"
CUSTOM_LOG_DIR="/var/log/chroot-rabbitmq-test-$CUSTOM_TEST_ID"
CUSTOM_SERVICE="chroot-rabbitmq-test-$CUSTOM_TEST_ID"
CUSTOM_PORT="$(( 20000 + RANDOM % 20000 ))"
CUSTOM_MGMT_PORT="$(( 20000 + RANDOM % 20000 ))"
CUSTOM_CREDENTIALS="/etc/chroot-rabbitmq-test-$CUSTOM_TEST_ID/credentials"
CUSTOM_PASSWORD='ci-fixed-pass-8chars'
OTHER_PASSWORD='other-pass-8chars'

custom_cleanup() {
  if [[ -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" \
      --conf-dir "$CUSTOM_CONF_DIR" --log-dir "$CUSTOM_LOG_DIR" \
      --service-name "$CUSTOM_SERVICE" --credentials-file "$CUSTOM_CREDENTIALS" --purge-data || true
  fi
  rm -rf "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$CUSTOM_CONF_DIR" "$CUSTOM_LOG_DIR" "$(dirname "$CUSTOM_CREDENTIALS")"
}
trap custom_cleanup EXIT

CHROOT_RABBITMQ_PASSWORD="$CUSTOM_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --conf-dir "$CUSTOM_CONF_DIR" \
  --log-dir "$CUSTOM_LOG_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --mgmt-port "$CUSTOM_MGMT_PORT" \
  --bind-address 127.0.0.1
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$RABBITMQ_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'custom password was not stored in credentials' >&2; exit 1; }
wait_for_rabbitmq "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$CUSTOM_CONF_DIR" "$CUSTOM_LOG_DIR"
auth_out="$(rabbitmqctl_exec "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$CUSTOM_CONF_DIR" "$CUSTOM_LOG_DIR" \
  authenticate_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD")"
grep -Fx 'Success' <<<"$auth_out" || { echo "custom password auth failed: $auth_out" >&2; exit 1; }

systemctl stop "$CUSTOM_SERVICE"
reinstall_output="$(CHROOT_RABBITMQ_PASSWORD="$OTHER_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --conf-dir "$CUSTOM_CONF_DIR" \
  --log-dir "$CUSTOM_LOG_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --mgmt-port "$CUSTOM_MGMT_PORT" \
  --bind-address 127.0.0.1 --password "$OTHER_PASSWORD" 2>&1)"
grep -q 'ignored' <<<"$reinstall_output" || { echo 'reinstall did not warn about ignored password' >&2; exit 1; }
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$RABBITMQ_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'reinstall changed the stored password' >&2; exit 1; }
wait_for_rabbitmq "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$CUSTOM_CONF_DIR" "$CUSTOM_LOG_DIR"
auth_out="$(rabbitmqctl_exec "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$CUSTOM_CONF_DIR" "$CUSTOM_LOG_DIR" \
  authenticate_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD")"
grep -Fx 'Success' <<<"$auth_out" || { echo "reinstall auth failed: $auth_out" >&2; exit 1; }

custom_cleanup
trap - EXIT

echo 'chroot-rabbitmq smoke test passed'
