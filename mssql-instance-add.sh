#!/usr/bin/env bash
#
# mssql-instance-add.sh -- add another native SQL Server instance to a host that
# already runs the packaged one, using nothing but systemd.
#
# Microsoft does not support multiple SQL Server instances on one Linux host
# (https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-faq -> Administration).
# This script works around that by giving each extra instance a private mount
# namespace over /var/opt/mssql, which is the hard-coded root of every path the
# engine uses. The new instance therefore gets its own mssql.conf, data/, log/,
# secrets/ and .system/, while the packaged instance is left untouched.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_TEMPLATE="$SCRIPT_DIR/mssql-server@.service"
UNIT_DIR="/etc/systemd/system"
INSTANCE_ROOT="/var/opt/mssql-instances"
BASE_UNIT="mssql-server.service"
EDITION="${MSSQL_PID:-Express}"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

usage() {
    cat <<EOF
Usage: sudo $0 <instance-name> <tcp-port>

  instance-name   short name for the new instance, e.g. mssql2
  tcp-port        TCP port it listens on (the packaged instance keeps 1433)

Environment:
  MSSQL_SA_PASSWORD   sa password for the new instance (prompted if unset)
  MSSQL_PID           edition for the new instance (default: Express)

Example:
  sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' $0 mssql2 1434
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

NAME="${1:-}"
PORT="${2:-}"
[[ -n "$NAME" && -n "$PORT" ]] || { usage; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "must run as root (use sudo)"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,30}$ ]] \
    || die "invalid instance name '$NAME': use lowercase letters, digits, '-' and '_'"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "port '$PORT' must be numeric"
(( PORT >= 1 && PORT <= 65535 )) || die "port must be between 1 and 65535"
[[ -f "$UNIT_TEMPLATE" ]] || die "unit template not found next to this script: $UNIT_TEMPLATE"
[[ -x /opt/mssql/bin/sqlservr ]] || die "SQL Server is not installed (/opt/mssql/bin/sqlservr missing)"
getent passwd mssql >/dev/null || die "user 'mssql' does not exist; is mssql-server installed?"

DIR="$INSTANCE_ROOT/$NAME"
UNIT="mssql-server@$NAME.service"
INIT_UNIT="mssql-init-$NAME.service"

[[ -e "$DIR" ]] && die "$DIR already exists - run mssql-instance-remove.sh first"
if systemctl is-enabled "$UNIT" >/dev/null 2>&1; then
    die "$UNIT is already enabled - run mssql-instance-remove.sh first"
fi
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
    die "TCP port $PORT is already in use"
fi

# --- sa password ------------------------------------------------------------
check_password_strength() {
    local pw="$1" classes=0
    if (( ${#pw} < 8 )); then return 1; fi
    if [[ "$pw" =~ [A-Z] ]]; then classes=$(( classes + 1 )); fi
    if [[ "$pw" =~ [a-z] ]]; then classes=$(( classes + 1 )); fi
    if [[ "$pw" =~ [0-9] ]]; then classes=$(( classes + 1 )); fi
    if [[ "$pw" =~ [^A-Za-z0-9] ]]; then classes=$(( classes + 1 )); fi
    (( classes >= 3 ))
}

SA_PASSWORD="${MSSQL_SA_PASSWORD:-}"
if [[ -n "$SA_PASSWORD" ]]; then
    check_password_strength "$SA_PASSWORD" \
        || die "password must be >= 8 characters and use 3 of: uppercase, lowercase, digits, symbols"
else
    [[ -t 0 ]] || die "no TTY to prompt on; set MSSQL_SA_PASSWORD in the environment"
    # Nothing is echoed while typing, so a typo is invisible. Ask again instead
    # of making the caller start over; nothing has been created until this
    # password is accepted.
    for attempt in 1 2 3; do
        read -rs -p "SA password for instance '$NAME' (not shown, attempt $attempt/3): " SA_PASSWORD \
            || die "aborted before anything was created"
        echo
        read -rs -p "Confirm SA password: " _confirm \
            || die "aborted before anything was created"
        echo
        if [[ "$SA_PASSWORD" != "$_confirm" ]]; then
            printf 'warning: the two entries do not match - try again (attempt %d of 3)\n' "$attempt" >&2
            SA_PASSWORD=""
            continue
        fi
        if check_password_strength "$SA_PASSWORD"; then
            break
        fi
        printf 'warning: password must be >= 8 characters and use 3 of: uppercase, lowercase, digits, symbols - try again\n' >&2
        SA_PASSWORD=""
    done
    [[ -n "$SA_PASSWORD" ]] || die "no usable password after 3 attempts; nothing has been created"
fi

# --- create the instance directory -----------------------------------------
info "creating $DIR"
install -d -o mssql -g mssql -m 0770 "$INSTANCE_ROOT"
install -d -o mssql -g mssql -m 0770 "$DIR"

# mssql-conf's setup refuses to run while mssql-server.service is active, so the
# packaged instance has to go down for the duration of the initialization.
BASE_WAS_ACTIVE=0
restore_base() {
    if (( BASE_WAS_ACTIVE )); then
        systemctl start "$BASE_UNIT" >/dev/null 2>&1 || true
    else
        # mssql-conf setup always starts (and enables) mssql-server.service, so
        # put the packaged instance back the way we found it.
        systemctl stop "$BASE_UNIT" >/dev/null 2>&1 || true
    fi
}
trap restore_base EXIT

if systemctl is-active --quiet "$BASE_UNIT"; then
    BASE_WAS_ACTIVE=1
    info "stopping $BASE_UNIT (mssql-conf will not initialize while an instance is running)"
    systemctl stop "$BASE_UNIT"
fi

# --- initialize the new instance inside its own namespace -------------------
# systemd-run creates a transient unit with the same BindPaths= the real unit
# will use, so mssql-conf (and the sqlservr --setup it spawns) sees the new
# directory as /var/opt/mssql. MSSQL_TCP_PORT is written into that instance's
# own mssql.conf by mssql-conf, so the two instances never share a port setting.
info "initializing instance '$NAME' on port $PORT (edition: $EDITION)"
systemctl reset-failed "$INIT_UNIT" >/dev/null 2>&1 || true
if ! systemd-run --pipe --collect --unit="$INIT_UNIT" \
        -p BindPaths="$DIR:/var/opt/mssql" \
        -p WorkingDirectory=/var/opt/mssql \
        --setenv=ACCEPT_EULA=Y \
        --setenv="MSSQL_PID=$EDITION" \
        --setenv="MSSQL_SA_PASSWORD=$SA_PASSWORD" \
        --setenv="MSSQL_TCP_PORT=$PORT" \
        /opt/mssql/bin/mssql-conf -n setup; then
    printf '\nInitialization failed. Engine log (from inside the namespace):\n' >&2
    printf '  journalctl -u %s --no-pager\n' "$INIT_UNIT" >&2
    printf '  tail -50 %s/log/errorlog\n' "$DIR" >&2
    printf '\nThe half-created directory was left in place. Remove it before retrying:\n' >&2
    printf '  sudo rm -rf %s\n' "$DIR" >&2
    exit 1
fi

# mssql-conf setup ends by enabling and starting mssql-server.service; make sure
# the packaged instance is up regardless of how we found it.
restore_base

# --- install and start the instance unit ------------------------------------
info "installing $UNIT_DIR/mssql-server@.service"
install -m 0644 "$UNIT_TEMPLATE" "$UNIT_DIR/mssql-server@.service"
systemctl daemon-reload

info "enabling and starting $UNIT"
systemctl enable --now "$UNIT"

info "waiting for TCP port $PORT"
for _ in $(seq 1 60); do
    if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
        break
    fi
    sleep 1
done

if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
    info "instance '$NAME' is listening on port $PORT"
else
    printf 'warning: nothing is listening on port %s yet; check:\n' "$PORT" >&2
    printf '  systemctl status %s\n' "$UNIT" >&2
    printf '  tail -50 %s/log/errorlog\n' "$DIR" >&2
fi

cat <<EOF

Instance '$NAME' created.

  data directory : $DIR   (appears as /var/opt/mssql to the engine)
  systemd unit   : $UNIT
  TCP port       : $PORT
  connect        : sqlcmd -S localhost,$PORT -U sa -C

  restart        : sudo systemctl restart $UNIT
  logs           : tail -f $DIR/log/errorlog
  configure      : sudo $SCRIPT_DIR/mssql-instance-conf.sh $NAME set network.tcpport <n>

The packaged instance is unchanged on port 1433.
EOF
