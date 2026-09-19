#!/usr/bin/env bash
#
# mssql-instance-manage.sh -- inspect and control the SQL Server instances on
# this host: the packaged one (mssql-server.service) plus every extra instance
# created by mssql-instance-add.sh (mssql-server@<name>.service).
#
# Instance names:
#   base     the packaged instance   (/var/opt/mssql, port 1433 by default)
#   <name>   an extra instance       (/var/opt/mssql-instances/<name>)
#   all      every instance (start / stop / restart only)
#
# Examples:
#   ./mssql-instance-manage.sh                          # interactive menu
#   ./mssql-instance-manage.sh list                     # table of instances
#   ./mssql-instance-manage.sh status mssql2
#   sudo ./mssql-instance-manage.sh restart mssql2
#   sudo ./mssql-instance-manage.sh stop all
#   ./mssql-instance-manage.sh logs mssql2 -f           # journal, follow
#   ./mssql-instance-manage.sh logs mssql2 -e -n 200    # engine errorlog
#
set -euo pipefail

INSTANCE_ROOT="/var/opt/mssql-instances"
BASE_UNIT="mssql-server.service"
BASE_DIR="/var/opt/mssql"

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

# --- colours ----------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

usage() {
    cat <<EOF
Usage: $0 [<command> [arguments]]

  (no command)                 interactive menu (requires a TTY)
  list                         table of every instance and its state
  status <name>                systemctl status for one instance
  start   <name|all>           start one instance (or all)
  stop    <name|all>           stop one instance (or all)      [root]
  restart <name|all>           restart one instance (or all)   [root]
  logs    <name> [-f] [-e] [-n <lines>]
                               journal for the unit; -e = engine errorlog,
                               -f = follow, -n = how many lines (default 100)

Names:
  base    the packaged instance (mssql-server.service, /var/opt/mssql)
  <name>  an extra instance created by mssql-instance-add.sh
  all     every instance (start / stop / restart only)

Examples:
  $0                                   # pick an instance, then an action
  $0 list
  sudo $0 restart mssql2
  sudo $0 stop all
  $0 logs mssql2 -f
  $0 logs mssql2 -e -n 200
EOF
}

# --- instance discovery -----------------------------------------------------
# The packaged instance is always called "base"; extra instances come from
# their data directories and from loaded units (they may disagree if an add
# failed halfway, and the union shows both).
instance_names() {
    printf 'base\n'
    {
        if [[ -d "$INSTANCE_ROOT" ]]; then
            find "$INSTANCE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
                2>/dev/null || true
        fi
        systemctl list-units --all --no-legend --plain --type=service \
            'mssql-server@*.service' 2>/dev/null \
            | sed -n 's/^[[:space:]]*mssql-server@\(.*\)\.service.*/\1/p' || true
        true
    } | sort -u
}

# /var/opt/mssql-instances and /var/opt/mssql are 0770 mssql:mssql, so only root
# can enumerate them and read their mssql.conf. Non-root listings still report
# state from systemd, and fall back to the listening ports seen by ss.
warn_unreadable_root() {
    local ports
    if [[ "${EUID}" -eq 0 ]]; then return 0; fi
    if [[ ! -d "$INSTANCE_ROOT" || -r "$INSTANCE_ROOT" ]]; then return 0; fi
    printf '%snote: not running as root - extra instances and their ports may be hidden; use sudo%s\n' \
        "$C_DIM" "$C_RESET" >&2
    ports="$(ss -lntH 2>/dev/null | awk '{ print $4 }' | sed 's/.*[:.]//' \
        | sort -un | awk '$1 >= 1024' | tr '\n' ' ' || true)"
    if [[ -n "${ports// /}" ]]; then
        printf '%s      listening TCP ports >= 1024: %s%s\n' \
            "$C_DIM" "$ports" "$C_RESET" >&2
    fi
}

valid_instance() {
    local n
    while read -r n; do
        [[ "$n" == "$1" ]] && return 0
    done < <(instance_names)
    return 1
}

unit_for() {
    if [[ "$1" == "base" ]]; then printf '%s\n' "$BASE_UNIT"
    else printf 'mssql-server@%s.service\n' "$1"
    fi
}

dir_for() {
    if [[ "$1" == "base" ]]; then printf '%s\n' "$BASE_DIR"
    else printf '%s/%s\n' "$INSTANCE_ROOT" "$1"
    fi
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "must run as root (use sudo)"
}

# --- state and port ---------------------------------------------------------
# => active | stopped | failed | activating | deactivating | no unit
unit_state() {
    local unit load active
    unit="$(unit_for "$1")"
    load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    [[ "$load" == "not-found" ]] && { printf 'no unit'; return 0; }
    active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)"
    [[ -z "$active" ]] && { printf 'unknown'; return 0; }
    [[ "$active" == "inactive" ]] && { printf 'stopped'; return 0; }
    printf '%s' "$active"
}

unit_enabled() {
    local state
    state="$(systemctl show -p UnitFileState --value "$(unit_for "$1")" 2>/dev/null || true)"
    case "$state" in
        enabled)  printf 'enabled' ;;
        disabled) printf 'disabled' ;;
        "")       printf '-' ;;
        *)        printf '%s' "$state" ;;
    esac
}

unit_pid() {
    local pid
    pid="$(systemctl show -p MainPID --value "$(unit_for "$1")" 2>/dev/null || true)"
    [[ -z "$pid" || "$pid" == "0" ]] && printf '-' || printf '%s' "$pid"
}

# TCP port from the instance's own mssql.conf ([network] tcpport), 1433 if unset.
# Returns non-zero when the file cannot be read as this user.
conf_port() {
    local dir="$1" conf="$1/mssql.conf" p
    [[ -r "$dir" ]] || return 1
    [[ -f "$conf" ]] || { printf '1433'; return 0; }
    [[ -r "$conf" ]] || return 1
    # mssql.conf is INI-ish: [section] headers and "key = value" pairs.
    p="$(awk -F= '
        /^[[:space:]]*[#;]/ { next }
        /^[[:space:]]*\[/ { sec = $1; gsub(/[[:space:]]/, "", sec); next }
        {
            k = $1; v = $2
            sub(/[#;].*$/, "", v)
            gsub(/[[:space:]]/, "", k); gsub(/[[:space:]]/, "", v)
            if ((sec == "[network]" || sec == "") &&
                (k == "tcpport" || k == "network.tcpport")) last = v
        }
        END { print last }
    ' "$conf")"
    printf '%s' "${p:-1433}"
}

# The port the process is actually listening on (needs root to read the PID map).
listen_port() {
    command -v ss >/dev/null || return 1
    ss -lntpH 2>/dev/null | grep -F "pid=$1," | awk '{ print $4 }' \
        | sed 's/.*[:.]//' | head -n1
}

instance_port() {
    local name="$1" pid lp
    pid="$(unit_pid "$name")"
    if [[ "$pid" != "-" ]]; then
        lp="$(listen_port "$pid" || true)"
        [[ -n "$lp" ]] && { printf '%s' "$lp"; return 0; }
    fi
    conf_port "$(dir_for "$name")" || printf '?'
}

# --- rendering helpers ------------------------------------------------------
colour_for_state() {
    case "$1" in
        active|enabled)      printf '%s' "$C_GREEN" ;;
        failed|no\ unit)     printf '%s' "$C_RED" ;;
        unknown|disabled|-)  printf '%s' "$C_DIM" ;;
        *)                   printf '%s' "$C_YELLOW" ;;
    esac
}

# Pad to the given width *before* adding colour so columns stay aligned.
pad_coloured() {
    local text="$1" width="$2" padded
    padded="$(printf "%-${width}s" "$text")"
    printf '%s%s%s' "$(colour_for_state "$text")" "$padded" "$C_RESET"
}

terminal_width() {
    local cols=""
    # Ask the controlling terminal first: COLUMNS is not exported to children
    # and tput fails when stdout is a pipe (e.g. `... list | less`).
    if [[ -r /dev/tty ]]; then
        cols="$(stty size < /dev/tty 2>/dev/null | awk '{ print $2 }' || true)"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ || "$cols" -le 0 ]]; then
        cols="$(tput cols 2>/dev/null || true)"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ || "$cols" -le 0 ]]; then
        cols="${COLUMNS:-}"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ || "$cols" -le 0 ]]; then
        cols=120
    fi
    printf '%s' "$cols"
}

# The table drops columns instead of wrapping on a narrow terminal:
#   wide   NAME UNIT STATE ENABLED PORT PID DATA-DIRECTORY
#   medium NAME UNIT STATE PORT ENABLED
#   narrow NAME STATE PORT
table_layout() {
    local cols
    cols="$(terminal_width)"
    if (( cols >= 112 )); then printf 'wide'
    elif (( cols >= 80 )); then printf 'medium'
    else printf 'narrow'
    fi
}

print_header() {
    case "$1" in
        wide)
            printf '%s%-10s %-29s %-19s %-10s %-6s %-8s %s%s\n' \
                "$C_BOLD" NAME UNIT STATE ENABLED PORT PID DATA-DIRECTORY "$C_RESET"
            printf '%s%-10s %-29s %-19s %-10s %-6s %-8s %s%s\n' \
                "$C_DIM" ---- ---- ----- ------- ---- --- -------------- "$C_RESET" ;;
        medium)
            printf '%s%-10s %-29s %-19s %-6s %s%s\n' \
                "$C_BOLD" NAME UNIT STATE PORT ENABLED "$C_RESET"
            printf '%s%-10s %-29s %-19s %-6s %s%s\n' \
                "$C_DIM" ---- ---- ----- ---- ------- "$C_RESET" ;;
        narrow)
            printf '%s%-10s %-19s %s%s\n' "$C_BOLD" NAME STATE PORT "$C_RESET"
            printf '%s%-10s %-19s %s%s\n' "$C_DIM" ---- ----- ---- "$C_RESET" ;;
    esac
}

print_row() {
    local name="$1" layout="$2"
    case "$layout" in
        wide)
            printf '%-10s %-29s %s %s %-6s %-8s %s\n' \
                "$name" "$(unit_for "$name")" \
                "$(pad_coloured "$(unit_state "$name")" 19)" \
                "$(pad_coloured "$(unit_enabled "$name")" 10)" \
                "$(instance_port "$name")" "$(unit_pid "$name")" "$(dir_for "$name")" ;;
        medium)
            printf '%-10s %-29s %s %-6s %s\n' \
                "$name" "$(unit_for "$name")" \
                "$(pad_coloured "$(unit_state "$name")" 19)" \
                "$(instance_port "$name")" \
                "$(pad_coloured "$(unit_enabled "$name")" 10)" ;;
        narrow)
            printf '%-10s %s %s\n' \
                "$name" "$(pad_coloured "$(unit_state "$name")" 19)" \
                "$(instance_port "$name")" ;;
    esac
}

do_list() {
    local name layout
    layout="$(table_layout)"
    print_header "$layout"
    while read -r name; do
        print_row "$name" "$layout"
    done < <(instance_names)
    warn_unreadable_root
}

# --- actions ----------------------------------------------------------------
do_status() {
    local name="$1" unit
    valid_instance "$name" || die "no such instance: $name"
    unit="$(unit_for "$name")"
    systemctl status --no-pager -l "$unit" 2>&1 || true
    printf '\nport: %s   data: %s\n' "$(instance_port "$name")" "$(dir_for "$name")"
}

do_action() {
    local verb="$1" name="$2" n rc=0
    if [[ "$name" == "all" ]]; then
        while read -r n; do
            do_action "$verb" "$n" || rc=1
        done < <(instance_names)
        return "$rc"
    fi
    valid_instance "$name" || die "no such instance: $name"
    info "$verb $name ($(unit_for "$name"))"
    systemctl "$verb" "$(unit_for "$name")"
    sleep 1
    printf '    -> %s, port %s\n' "$(unit_state "$name")" "$(instance_port "$name")"
}

follow_cmd() {
    trap 'printf "\n"' INT
    "$@" || true
    trap - INT
}

do_logs() {
    local name="$1" engine="$2" follow="$3" lines="$4" unit file
    valid_instance "$name" || die "no such instance: $name"
    unit="$(unit_for "$name")"
    if (( engine )); then
        file="$(dir_for "$name")/log/errorlog"
        [[ -f "$file" ]] || die "no errorlog yet: $file"
        [[ -r "$file" ]] || die "cannot read $file (try sudo)"
        if (( follow )); then follow_cmd tail -n "$lines" -f "$file"
        else tail -n "$lines" "$file"
        fi
    else
        command -v journalctl >/dev/null || die "journalctl not found"
        if (( follow )); then follow_cmd journalctl -u "$unit" -n "$lines" -f
        else journalctl -u "$unit" --no-pager -n "$lines"
        fi
    fi
}

# --- interactive menu -------------------------------------------------------
instance_menu() {
    local name="$1" unit choice
    while true; do
        unit="$(unit_for "$name")"
        printf '\n%s%s%s\n' "$C_BOLD" "$name" "$C_RESET"
        printf '  unit  : %s\n' "$unit"
        printf '  state : %s%s%s\n' "$(colour_for_state "$(unit_state "$name")")" \
            "$(unit_state "$name")" "$C_RESET"
        printf '  port  : %s\n' "$(instance_port "$name")"
        printf '  data  : %s\n\n' "$(dir_for "$name")"
        printf '  1) status\n'
        printf '  2) start\n'
        printf '  3) stop\n'
        printf '  4) restart\n'
        printf '  5) logs\n'
        printf '  b) back    q) quit\n\n'
        read -r -p "Action: " choice || { printf '\n'; return 0; }
        case "$choice" in
            1) do_status "$name" ;;
            2) require_root; do_action start "$name" ;;
            3) require_root; do_action stop "$name" ;;
            4) require_root; do_action restart "$name" ;;
            5) logs_menu "$name" ;;
            b|B|"") return 0 ;;
            q|Q) exit 0 ;;
            *) printf 'invalid choice\n' >&2 ;;
        esac
    done
}

logs_menu() {
    local name="$1" choice
    while true; do
        printf '\n%slogs: %s%s\n\n' "$C_BOLD" "$name" "$C_RESET"
        printf '  1) journal    (last 100 lines)\n'
        printf '  2) journal    (follow, ^C to stop)\n'
        printf '  3) errorlog   (last 100 lines)\n'
        printf '  4) errorlog   (follow, ^C to stop)\n'
        printf '  b) back\n\n'
        read -r -p "Choice: " choice || { printf '\n'; return 0; }
        case "$choice" in
            1) do_logs "$name" 0 0 100 ;;
            2) do_logs "$name" 0 1 50 ;;
            3) do_logs "$name" 1 0 100 ;;
            4) do_logs "$name" 1 1 50 ;;
            b|B|"") return 0 ;;
            *) printf 'invalid choice\n' >&2 ;;
        esac
    done
}

interactive() {
    local names=() name choice count
    while true; do
        mapfile -t names < <(instance_names)
        printf '\n%sSQL Server instances%s\n\n' "$C_BOLD" "$C_RESET"
        count=0
        for name in "${names[@]}"; do
            count=$(( count + 1 ))
            printf '  %2d) %-10s port %-6s %s%s%s\n' \
                "$count" "$name" "$(instance_port "$name")" \
                "$(colour_for_state "$(unit_state "$name")")" \
                "$(unit_state "$name")" "$C_RESET"
        done
        printf '\n   r) refresh    q) quit\n\n'
        warn_unreadable_root
        read -r -p 'Select instance: ' choice || { printf '\n'; return 0; }
        case "$choice" in
            q|Q|quit|exit) return 0 ;;
            ''|r|R) continue ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            instance_menu "${names[choice-1]}"
        else
            printf 'invalid selection\n' >&2
        fi
    done
}

# --- command line -----------------------------------------------------------
cmd="${1:-}"
shift || true

case "$cmd" in
    "")
        [[ -t 0 ]] || die "no command given and stdin is not a TTY (try '$0 list')"
        interactive
        ;;
    list|ls|ps)
        do_list
        ;;
    status|st)
        if [[ $# -eq 0 ]]; then do_list; else do_status "$1"; fi
        ;;
    start|stop|restart)
        require_root
        do_action "$cmd" "${1:-all}"
        ;;
    logs|log)
        name="" follow=0 lines=100 engine=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -f|--follow)  follow=1; shift ;;
                -e|--errorlog) engine=1; shift ;;
                -n|--lines)
                    [[ "${2:-}" =~ ^[0-9]+$ ]] || die "-n needs a number"
                    lines="$2"; shift 2
                    ;;
                -h|--help) usage; exit 0 ;;
                -*) die "unknown option '$1'" ;;
                *) [[ -z "$name" ]] || die "unexpected argument '$1'"; name="$1"; shift ;;
            esac
        done
        [[ -n "$name" ]] || { usage; exit 1; }
        do_logs "$name" "$engine" "$follow" "$lines"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        printf 'error: unknown command %s\n\n' "$cmd" >&2
        usage >&2
        exit 1
        ;;
esac
