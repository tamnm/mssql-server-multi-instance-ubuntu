#!/usr/bin/env bash
#
# mssql-instance-remove.sh -- stop and disable an additional SQL Server instance.
#
#   sudo ./mssql-instance-remove.sh mssql2            # keep the data directory
#   sudo ./mssql-instance-remove.sh mssql2 --purge    # delete it as well
#
set -euo pipefail

INSTANCE_ROOT="/var/opt/mssql-instances"
TEMPLATE_UNIT="/etc/systemd/system/mssql-server@.service"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

NAME="${1:-}"
MODE="${2:-}"

if [[ -z "$NAME" || "$NAME" == "-h" || "$NAME" == "--help" ]]; then
    cat <<EOF
Usage: sudo $0 <instance-name> [--purge]

  --purge   also delete $INSTANCE_ROOT/<instance-name> (all databases in it)
EOF
    exit 1
fi

[[ "${EUID}" -eq 0 ]] || die "must run as root (use sudo)"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]] || die "invalid instance name '$NAME'"

DIR="$INSTANCE_ROOT/$NAME"
UNIT="mssql-server@$NAME.service"

info "stopping and disabling $UNIT"
systemctl disable --now "$UNIT" >/dev/null 2>&1 || true

if [[ "$MODE" == "--purge" ]]; then
    info "deleting $DIR"
    rm -rf -- "$DIR"
    rmdir "$INSTANCE_ROOT" 2>/dev/null || true
else
    info "keeping $DIR (use --purge to delete it)"
fi

systemctl daemon-reload

# The template is shared by every additional instance, so only drop it when no
# instance is left behind.
if [[ -f "$TEMPLATE_UNIT" ]] && ! compgen -G "/var/opt/mssql-instances/*" >/dev/null; then
    info "no instances left; removing $TEMPLATE_UNIT"
    rm -f -- "$TEMPLATE_UNIT"
    systemctl daemon-reload
fi

info "done - instance '$NAME' removed (the packaged instance on port 1433 is untouched)"
