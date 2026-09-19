#!/usr/bin/env bash
#
# mssql-instance-conf.sh -- run mssql-conf against an additional instance.
#
# Plain `mssql-conf` always edits /var/opt/mssql/mssql.conf, i.e. the packaged
# instance. This wrapper runs it inside the target instance's mount namespace so
# it edits that instance's own mssql.conf instead.
#
# Example:
#   sudo ./mssql-instance-conf.sh mssql2 set network.tcpport 1435
#   sudo ./mssql-instance-conf.sh mssql2 get network
#
set -euo pipefail

INSTANCE_ROOT="/var/opt/mssql-instances"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
Usage: sudo $0 <instance-name> <mssql-conf arguments...>

Examples:
  sudo $0 mssql2 set network.tcpport 1435
  sudo $0 mssql2 set memory.memorylimitmb 2048
  sudo $0 mssql2 get network
  sudo $0 mssql2 list
EOF
    exit 1
fi

NAME="$1"; shift
DIR="$INSTANCE_ROOT/$NAME"
UNIT="mssql-conf-$NAME.service"

[[ "${EUID}" -eq 0 ]] || die "must run as root (use sudo)"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]] || die "invalid instance name '$NAME'"
[[ -d "$DIR" ]] || die "no such instance: $DIR"
[[ -x /opt/mssql/bin/mssql-conf ]] || die "/opt/mssql/bin/mssql-conf not found"

systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true

systemd-run --pipe --collect --unit="$UNIT" \
    -p BindPaths="$DIR:/var/opt/mssql" \
    -p WorkingDirectory=/var/opt/mssql \
    /opt/mssql/bin/mssql-conf "$@"

cat <<EOF

Applied to instance '$NAME' ($DIR/mssql.conf).
Restart it to pick up the change:

  sudo systemctl restart mssql-server@$NAME
EOF
