#!/usr/bin/env bash
#
# mssql-base-install.sh -- install and initialize the packaged ("base") SQL
# Server engine, i.e. mssql-server.service with its data root at /var/opt/mssql.
#
# Every other script in this directory assumes that instance exists:
# mssql-instance-add.sh refuses to run when /opt/mssql/bin/sqlservr is missing,
# and mssql-instance-manage.sh always shows a "base" row. Run this one first on a
# fresh host; on a host that is already set up it just reports what is there and
# changes nothing.
#
# Order of operations:
#   1. work out whether mssql-server is installed and whether it is configured;
#   2. if apt has no candidate for mssql-server, add the Microsoft repository and
#      signing key, auto-detecting the distro release and the SQL Server release
#      (Ubuntu 24.04 -> mssql-server-2025, 22.04 -> mssql-server-2022, ...);
#   3. stop the extra instances (an install replaces the /opt/mssql they share),
#      install the package, then start them again;
#   4. run `mssql-conf -n setup` with ACCEPT_EULA / MSSQL_PID /
#      MSSQL_SA_PASSWORD / MSSQL_TCP_PORT, and make sure mssql-server.service is
#      enabled, running and listening on the requested port.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ROOT="/var/opt/mssql-instances"
BASE_UNIT="mssql-server.service"
BASE_DIR="/var/opt/mssql"
MSSQL_CONF="/opt/mssql/bin/mssql-conf"
KEYRING="/usr/share/keyrings/microsoft-prod.gpg"
SQL_YEARS="2025 2022 2019"      # probed newest-first when apt has no candidate

EDITION="${MSSQL_PID:-Express}"
PORT="${MSSQL_TCP_PORT:-1433}"
SA_PASSWORD="${MSSQL_SA_PASSWORD:-}"
WANT_YEAR="${MSSQL_VERSION:-}"
REPO_OVERRIDE=""
FORCE=0
ASSUME_YES=0
STOPPED_EXTRAS=()

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Installs the packaged SQL Server engine ("base" instance) when it is missing,
and (re)configures it when it is not set up yet. Does nothing if the base
instance is already installed and configured.

Options:
  --pid <edition>     Express|Developer|Standard|Enterprise|Evaluation (default
                      Express), a product key, or \$MSSQL_PID
  --port <n>          TCP port for the base instance (default 1433)
  --password <pw>     sa password, or \$MSSQL_SA_PASSWORD, or prompted
  --version <year>    SQL Server apt release to add: 2019|2022|2025
                      (default: newest one Microsoft publishes for this distro)
  --repo <family/rel> use this Microsoft repo path instead of auto-detection,
                      e.g. --repo ubuntu/22.04
  --force             run the setup step again on a configured instance
                      (resets the sa password and re-applies edition/port)
  --yes               answer yes to every question (repo changes, apt install)
  -h, --help          this text

Environment:
  MSSQL_PID           edition (same as --pid)
  MSSQL_TCP_PORT      port (same as --port)
  MSSQL_SA_PASSWORD   sa password (same as --password)
  MSSQL_VERSION       SQL Server release (same as --version)

Examples:
  sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' $0
  sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' $0 --pid Developer --port 1433 --yes
  sudo $0 --version 2022 --repo ubuntu/22.04
EOF
}

# --- arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid)      EDITION="${2:-}";      [[ -n "$EDITION" ]] || die "--pid needs a value"; shift 2 ;;
        --port)     PORT="${2:-}";         [[ -n "$PORT" ]] || die "--port needs a value"; shift 2 ;;
        --password) SA_PASSWORD="${2:-}";  [[ -n "$SA_PASSWORD" ]] || die "--password needs a value"; shift 2 ;;
        --version)  WANT_YEAR="${2:-}";    [[ -n "$WANT_YEAR" ]] || die "--version needs a value"; shift 2 ;;
        --repo)     REPO_OVERRIDE="${2:-}"; [[ -n "$REPO_OVERRIDE" ]] || die "--repo needs a value"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) printf 'error: unknown argument %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "port '$PORT' must be numeric"
(( PORT >= 1 && PORT <= 65535 )) || die "port must be between 1 and 65535"

case "$EDITION" in
    Express|Developer|Standard|Enterprise|Evaluation|Web|Embedded) ;;
    *) warn "'$EDITION' is not a standard edition name; passing it to mssql-conf as a product key" ;;
esac

# --- environment checks -----------------------------------------------------
[[ "${EUID}" -eq 0 ]] || die "must run as root (use sudo)"
[[ -r /etc/os-release ]] || die "/etc/os-release not found; unsupported host"
[[ "$(uname -m)" == "x86_64" ]] \
    || die "SQL Server for Linux is x86_64 only (this host is $(uname -m))"
for tool in systemctl apt-get dpkg-query curl gpg ss; do
    command -v "$tool" >/dev/null || die "$tool not found; install it first"
done

confirm() {   # confirm "<question>" -> 0 = yes
    local reply
    if (( ASSUME_YES )); then return 0; fi
    [[ -t 0 ]] || die "not a TTY to ask '$1' on; pass --yes to accept non-interactively"
    read -r -p "$1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

# --- current state ----------------------------------------------------------
package_installed() {
    dpkg-query -W -f='${Status}' mssql-server 2>/dev/null | grep -q '^install ok installed$'
}

# mssql.conf is INI-ish: [section] headers and "key = value" pairs, with the
# value possibly followed by a # or ; comment. Sections and keys are compared
# case-insensitively, and a key outside any section is matched too.
conf_get() {
    local file="$1" section="$2" key="$3"
    [[ -r "$file" ]] || return 1
    awk -F= -v want_section="[$section]" -v want_key="$key" '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*\[/ { sec = $1; gsub(/[[:space:]]/, "", sec); next }
        {
            k = $1; v = $2
            sub(/[#;].*$/, "", v)
            gsub(/[[:space:]]/, "", k); gsub(/[[:space:]]/, "", v)
            if ((tolower(sec) == tolower(want_section) || sec == "") &&
                tolower(k) == tolower(want_key)) last = v
        }
        END { if (last != "") print last }
    ' "$file"
}

conf_port() {
    local dir="$1" conf="$1/mssql.conf" p
    [[ -r "$dir" ]] || return 1
    [[ -f "$conf" ]] || { printf '1433'; return 0; }
    [[ -r "$conf" ]] || return 1
    p="$(conf_get "$conf" network tcpport || true)"
    if [[ -z "$p" ]]; then p="$(conf_get "$conf" "" network.tcpport || true)"; fi
    printf '%s' "${p:-1433}"
}

# Installed is not the same as configured. The package can leave an mssql.conf
# behind - `mssql-conf set <anything>` writes one, and the debconf postinst does
# exactly that for sqlagent/setEnable - while the instance has never been
# initialized, in which case the engine just fails with "the EULA must be
# accepted". So test what the package itself tests: the master database file
# (plus the EULA flag, without which the engine will not start either).
base_initialized() {
    local conf="$BASE_DIR/mssql.conf" master eula
    [[ -f "$conf" ]] || return 1
    master="$(conf_get "$conf" filelocation masterdatafile || true)"
    [[ -n "$master" ]] || master="$BASE_DIR/data/master.mdf"
    [[ -f "$master" ]] || return 1
    eula="$(conf_get "$conf" EULA accepteula || true)"
    case "${eula,,}" in
        y|yes|true|1) return 0 ;;
        *) return 1 ;;
    esac
}

unit_state() {
    local active
    active="$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)"
    [[ -z "$active" ]] && printf 'unknown' || printf '%s' "$active"
}

# Additional instances created by mssql-instance-add.sh.
extra_instances() {
    if [[ -d "$INSTANCE_ROOT" ]]; then
        find "$INSTANCE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | sort || true
    fi
}

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

# The password is not echoed, which makes typos easy and invisible, so a bad
# entry just asks again instead of making you restart the script. Nothing on
# disk has been touched while this runs, so giving up here is always safe.
resolve_password() {
    local confirm_pw attempt

    if [[ -n "$SA_PASSWORD" ]]; then
        check_password_strength "$SA_PASSWORD" \
            || die "password must be >= 8 characters and use 3 of: uppercase, lowercase, digits, symbols"
        return 0
    fi

    [[ -t 0 ]] || die "no TTY to prompt on; set MSSQL_SA_PASSWORD or pass --password"

    for attempt in 1 2 3; do
        read -rs -p "SA password for the base instance (not shown, attempt $attempt/3): " SA_PASSWORD \
            || die "aborted before anything was changed"
        echo
        read -rs -p "Confirm SA password: " confirm_pw \
            || die "aborted before anything was changed"
        echo

        if [[ "$SA_PASSWORD" != "$confirm_pw" ]]; then
            warn "the two entries do not match - try again (attempt $attempt of 3)"
            SA_PASSWORD=""
            continue
        fi
        if ! check_password_strength "$SA_PASSWORD"; then
            printf 'warning: password must be >= 8 characters and use 3 of: uppercase, lowercase, digits, symbols - try again\n' >&2
            SA_PASSWORD=""
            continue
        fi
        return 0
    done

    die "no usable password after 3 attempts; nothing has been changed on this host"
}

# --- Microsoft apt repository -----------------------------------------------
# => "<family> <release>", e.g. "ubuntu 24.04"
#
# Only the distributions Microsoft ships the engine for are known here (Ubuntu
# and its derivatives; the engine is not packaged for Debian, unlike sqlcmd).
# Anything else has to pass --repo <family>/<release>.
detect_repo_path() {
    local id like ver codename mapped=""
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; like="${ID_LIKE:-}"
    ver="${VERSION_ID:-}"
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

    case "$id $like" in
        *ubuntu*)
            # Ubuntu derivatives (Pop!_OS, Mint, ...) report their own VERSION_ID,
            # so prefer the Ubuntu codename when it is one we know.
            case "$codename" in
                xenial) mapped="16.04" ;; bionic) mapped="18.04" ;;
                focal)  mapped="20.04" ;; jammy)  mapped="22.04" ;;
                noble)  mapped="24.04" ;;
            esac
            printf 'ubuntu %s' "${mapped:-$ver}"
            ;;
        *)
            die "'$id' is not a distribution Microsoft packages the SQL Server engine for
       (Debian, for instance, only gets the tools); pass --repo <family>/<release>
       to point at a repository yourself, or run one container per instance.
       Docs: https://learn.microsoft.com/sql/linux/sql-server-linux-setup"
            ;;
    esac
}

# Download the official Microsoft repo config and drop it into
# /etc/apt/sources.list.d, trying the wanted release first and then the newest
# ones Microsoft publishes for this distro. Prints the release it installed.
install_repo_config() {
    local family="$1" release="$2" year years tmp url
    years="$SQL_YEARS"
    if [[ -n "$WANT_YEAR" ]]; then years="$WANT_YEAR"; fi

    for year in $years; do
        url="https://packages.microsoft.com/config/$family/$release/mssql-server-$year.list"
        tmp="$(mktemp)"
        if curl -fsSL --max-time 30 "$url" -o "$tmp"; then
            # Microsoft's newer config files carry signed-by=...; the older ones
            # (22.04 and before) rely on apt-key-era trust, which no longer works
            # on a modern apt. Point them at the keyring we install, which also
            # keeps the key scoped to this source instead of trusting it globally.
            if ! grep -q 'signed-by=' "$tmp"; then
                sed -i -E \
                    -e "s@^(deb[[:space:]]+\[)([^]]*)\]@\1\2 signed-by=$KEYRING]@" \
                    -e "s@^(deb[[:space:]]+)(https?://)@\1[signed-by=$KEYRING] \2@" \
                    -e '$a\' "$tmp"
            fi
            install -m 0644 "$tmp" "/etc/apt/sources.list.d/mssql-server-$year.list"
            rm -f "$tmp"
            printf '%s' "$year"
            return 0
        fi
        rm -f "$tmp"
    done

    if [[ -n "$WANT_YEAR" ]]; then
        die "Microsoft publishes no SQL Server $WANT_YEAR repository for $family $release"
    fi
    die "no Microsoft SQL Server repository for $family $release (tried $SQL_YEARS); use --repo and --version"
}

add_microsoft_repo() {
    local family="$1" release="$2" year

    if [[ ! -s /usr/share/keyrings/microsoft-prod.gpg ]]; then
        info "installing the Microsoft signing key"
        curl -fsSL --max-time 30 https://packages.microsoft.com/keys/microsoft.asc \
            | gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
            || die "could not download or convert the Microsoft signing key"
        chmod 0644 /usr/share/keyrings/microsoft-prod.gpg
    fi

    year="$(install_repo_config "$family" "$release")"
    info "added the Microsoft apt repository (SQL Server $year for $family $release)"
}

# --- extra instances --------------------------------------------------------
# An install replaces /opt/mssql, which every instance shares, so stop them
# first (this is what the README tells you to do before `apt upgrade`) and put
# them back afterwards.
stop_extra_instances() {
    local name
    STOPPED_EXTRAS=()
    while read -r name; do
        if systemctl is-active --quiet "mssql-server@$name.service"; then
            STOPPED_EXTRAS+=("$name")
        fi
    done < <(extra_instances)

    if [[ "${#STOPPED_EXTRAS[@]}" -eq 0 ]]; then return 0; fi

    warn "extra instances are running: ${STOPPED_EXTRAS[*]}"
    warn "installing replaces /opt/mssql, which they share with the base instance"
    confirm "Stop them now and start them again after the install?" \
        || die "stopped by user; run '$SCRIPT_DIR/mssql-instance-manage.sh stop all' yourself and retry"

    for name in "${STOPPED_EXTRAS[@]}"; do
        info "stopping mssql-server@$name"
        systemctl stop "mssql-server@$name.service" || warn "could not stop mssql-server@$name"
    done
    trap restore_extra_instances EXIT
}

restore_extra_instances() {
    local name
    if [[ "${#STOPPED_EXTRAS[@]}" -eq 0 ]]; then return 0; fi
    for name in "${STOPPED_EXTRAS[@]}"; do
        info "starting mssql-server@$name again"
        systemctl start "mssql-server@$name.service" || warn "could not start mssql-server@$name"
    done
    STOPPED_EXTRAS=()
}

# --- install / setup --------------------------------------------------------
# A version in apt's cache is not enough to go on: mssql-base-remove.sh removes
# the source file, and indexes that no longer belong to a configured source can
# still linger until the next apt-get update. Ask apt whether it can actually
# resolve the package with the sources that are configured right now.
apt_can_install_mssql() {
    apt-get install --simulate --yes mssql-server >/dev/null 2>&1
}

install_package() {
    local candidate family release
    candidate="$(apt-cache policy mssql-server 2>/dev/null \
        | awk '/^[[:space:]]*Candidate:/ { print $2 }' || true)"

    if [[ -n "$candidate" && "$candidate" != "(none)" ]] && apt_can_install_mssql; then
        info "apt already offers mssql-server $candidate; using the configured sources"
        confirm "Install mssql-server $candidate with apt-get?" \
            || die "stopped by user; nothing was installed"
    else
        if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
            warn "apt still lists mssql-server $candidate but no configured source resolves it; adding the repository"
        fi
        if [[ -n "$REPO_OVERRIDE" ]]; then
            [[ "$REPO_OVERRIDE" == */* ]] || die "--repo wants <family>/<release>, e.g. ubuntu/22.04"
            family="${REPO_OVERRIDE%/*}"; release="${REPO_OVERRIDE##*/}"
        else
            read -r family release <<<"$(detect_repo_path)"
        fi
        confirm "Add the Microsoft repository for $family $release to /etc/apt and install mssql-server?" \
            || die "stopped by user; nothing was installed"
        add_microsoft_repo "$family" "$release"
        info "apt-get update"
        apt-get update
    fi

    info "apt-get install -y mssql-server"
    # The package's postinst runs mssql-conf setup by itself when these are set,
    # which is why they are passed here as well as to the explicit setup below.
    DEBIAN_FRONTEND=noninteractive ACCEPT_EULA=Y MSSQL_PID="$EDITION" \
        MSSQL_SA_PASSWORD="$SA_PASSWORD" MSSQL_TCP_PORT="$PORT" \
        apt-get install -y mssql-server
}

run_setup() {
    # A previous failed start leaves the unit in "start request repeated too
    # quickly" for a while; clear that before touching it.
    systemctl reset-failed "$BASE_UNIT" >/dev/null 2>&1 || true

    if systemctl is-active --quiet "$BASE_UNIT"; then
        info "stopping $BASE_UNIT (mssql-conf setup refuses to run while it is up)"
        systemctl stop "$BASE_UNIT"
    fi

    info "running mssql-conf -n setup (edition: $EDITION, port: $PORT)"
    if ! ACCEPT_EULA=Y MSSQL_PID="$EDITION" MSSQL_SA_PASSWORD="$SA_PASSWORD" \
            MSSQL_TCP_PORT="$PORT" "$MSSQL_CONF" -n setup; then
        printf '\nSetup failed. Where to look:\n' >&2
        printf '  journalctl -u %s --no-pager -n 100\n' "$BASE_UNIT" >&2
        printf '  tail -50 %s/log/errorlog\n' "$BASE_DIR" >&2
        printf '\nRe-run with --force to try the setup step again.\n' >&2
        exit 1
    fi
}

wait_for_port() {
    local port="$1" i
    for i in $(seq 1 120); do
        if ss -lntH 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]${port}\$"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# mssql-conf setup has been seen to ignore MSSQL_TCP_PORT when the package's own
# postinst already configured the instance; make sure we end up on the port we
# were asked for.
enforce_port() {
    local want="$1" have
    have="$(conf_port "$BASE_DIR")" || return 0
    [[ "$have" == "$want" ]] && return 0
    warn "mssql.conf says network.tcpport = $have, not $want; fixing it"
    if "$MSSQL_CONF" set network.tcpport "$want" >/dev/null; then
        systemctl restart "$BASE_UNIT"
        wait_for_port "$want" || warn "nothing is listening on port $want yet"
    else
        warn "could not set the port; do it by hand: sudo $MSSQL_CONF set network.tcpport $want"
    fi
}

print_summary() {
    local version port state enabled
    version="$(dpkg-query -W -f='${Version}' mssql-server 2>/dev/null || printf 'unknown')"
    port="$(conf_port "$BASE_DIR" || printf '?')"
    state="$(unit_state "$BASE_UNIT")"
    enabled="$(systemctl is-enabled "$BASE_UNIT" 2>/dev/null || printf 'disabled')"

    cat <<EOF

Base instance ready.

  package      : mssql-server $version
  edition      : $EDITION
  data dir     : $BASE_DIR
  systemd unit : $BASE_UNIT ($state, $enabled)
  TCP port     : $port
  connect      : sqlcmd -S localhost,$port -U sa -C

  list/control : sudo $SCRIPT_DIR/mssql-instance-manage.sh
  add instance : sudo MSSQL_SA_PASSWORD='...' $SCRIPT_DIR/mssql-instance-add.sh mssql2 1434
  change conf  : sudo $SCRIPT_DIR/mssql-instance-conf.sh <name> set <key> <value>
  sqlcmd       : sudo apt-get install -y mssql-tools18 unixodbc-dev
EOF
}

# --- main -------------------------------------------------------------------
INSTALLED=0; package_installed && INSTALLED=1
INITIALIZED=0; base_initialized && INITIALIZED=1

if (( INSTALLED && INITIALIZED && ! FORCE )); then
    info "mssql-server is already installed and initialized - nothing to do"
    print_summary
    printf '\nUse --force if you want to run the setup step again.\n'
    exit 0
fi

if (( ! INSTALLED )); then
    info "mssql-server is not installed; installing it"
    if ss -lntH 2>/dev/null | awk '{ print $4 }' | grep -qE "[:.]${PORT}\$"; then
        die "TCP port $PORT is already in use by another process"
    fi
fi

if (( ! INSTALLED || FORCE || ! INITIALIZED )); then
    resolve_password
fi

if (( ! INSTALLED )); then
    stop_extra_instances
    install_package

    # The postinst can leave an mssql.conf behind without the instance ever
    # having been initialized, so ask the real question again.
    if base_initialized; then INITIALIZED=1; fi
fi

if (( FORCE || ! INITIALIZED )); then
    run_setup
else
    info "the instance is already initialized; setup step skipped"
fi

info "enabling and starting $BASE_UNIT"
systemctl reset-failed "$BASE_UNIT" >/dev/null 2>&1 || true
systemctl enable --now "$BASE_UNIT" >/dev/null

if ! wait_for_port "$PORT"; then
    printf '\n' >&2
    printf 'error: %s is not listening on port %s.\n' "$BASE_UNIT" "$PORT" >&2
    printf 'It was installed, but it did not come up - check:\n' >&2
    printf '  systemctl status %s --no-pager -l\n' "$BASE_UNIT" >&2
    printf '  journalctl -u %s -n 100 --no-pager\n' "$BASE_UNIT" >&2
    printf '  tail -50 %s/log/errorlog\n' "$BASE_DIR" >&2
    printf '\nRe-run with --force to run the setup step again.\n' >&2
    exit 1
fi
info "listening on TCP port $PORT"

enforce_port "$PORT"
restore_extra_instances

print_summary
