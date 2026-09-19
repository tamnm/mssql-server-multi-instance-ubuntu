#!/usr/bin/env bash
#
# mssql-base-remove.sh -- take the host back to "no SQL Server at all", so that
# mssql-base-install.sh can be exercised from a clean slate.
#
# This deletes data. What it is about to do is printed first, and the data
# directories are only removed after an explicit yes (or --yes). The unit files,
# the apt source and the signing key are only removed when they belong to this
# setup - the VS Code repository uses its own keyring and is left alone.
#
#   sudo ./mssql-base-remove.sh --dry-run     # show the plan, change nothing
#   sudo ./mssql-base-remove.sh               # ask about the data, then remove
#   sudo ./mssql-base-remove.sh --yes         # remove everything, no questions
#   sudo ./mssql-base-remove.sh --keep-data   # uninstall, keep every database
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKG="mssql-server"
BASE_UNIT="mssql-server.service"
BASE_DIR="/var/opt/mssql"
INSTANCE_ROOT="/var/opt/mssql-instances"
TEMPLATE_UNIT="/etc/systemd/system/mssql-server@.service"
KEYRING="/usr/share/keyrings/microsoft-prod.gpg"

KEEP_DATA=0
KEEP_REPO=0
ASSUME_YES=0
DRY_RUN=0

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: sudo $0 [options]

Uninstalls the packaged SQL Server engine and cleans up what this project put on
the host, so mssql-base-install.sh can be tested from scratch.

Removed:
  - every mssql-server@* instance: stopped, disabled, unit and data directory
  - mssql-server.service: stopped, disabled, package purged (removes /opt/mssql)
  - the unit template $TEMPLATE_UNIT
  - /var/opt/mssql and $INSTANCE_ROOT   (ALL databases)
  - the Microsoft apt source and signing key added for mssql-server

Kept:
  - the mssql user and group (harmless; the package recreates them if missing)
  - sqlcmd / unixodbc packages, if they happen to be installed
  - the keyring if another apt source still refers to it

Options:
  --keep-data   keep the data directories (uninstall only)
  --keep-repo   keep the Microsoft apt source and the signing key
  --yes         do not ask about deleting data
  --dry-run     print the plan and exit without changing anything
  -h, --help    this text

Examples:
  sudo $0 --dry-run
  sudo $0 --yes
  sudo $0 --keep-data
EOF
}

# --- arguments --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-data) KEEP_DATA=1; shift ;;
        --keep-repo) KEEP_REPO=1; shift ;;
        --yes|-y)    ASSUME_YES=1; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) printf 'error: unknown argument %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    if (( DRY_RUN )); then
        warn "not running as root: root-owned paths cannot be listed, so the plan may be incomplete"
    else
        die "must run as root (use sudo)"
    fi
fi
for tool in systemctl apt-get dpkg-query; do
    command -v "$tool" >/dev/null || die "$tool not found"
done

package_installed() {
    dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q '^install ok installed$'
}

unit_exists() {
    [[ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" != "not-found" ]]
}

# Additional instances: data directories and loaded units can disagree, so both
# are collected and both are cleaned up.
extra_dirs() {
    if [[ -d "$INSTANCE_ROOT" ]]; then
        find "$INSTANCE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | sort || true
    fi
}

extra_units() {
    systemctl list-units --all --no-legend --plain --type=service 'mssql-server@*.service' \
        2>/dev/null \
        | sed -n 's/^[[:space:]]*\(mssql-server@[^[:space:]]*\.service\).*/\1/p' || true
}

# --- inventory --------------------------------------------------------------
PKG_INSTALLED=0; package_installed && PKG_INSTALLED=1
PKG_VERSION="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true)"

mapfile -t DIRS < <(extra_dirs)
mapfile -t UNITS < <(extra_units)
RUNNING_UNITS="$(systemctl list-units --no-legend --plain --type=service 'mssql-server@*.service' \
    2>/dev/null | awk '{ print $1 }' || true)"
DIRS_UNREADABLE=0
if [[ -d "$INSTANCE_ROOT" && ! -r "$INSTANCE_ROOT" ]]; then DIRS_UNREADABLE=1; fi

mapfile -t REPO_FILES < <(compgen -G "/etc/apt/sources.list.d/mssql-server*.list" || true)
KEYRING_PRESENT=0
if [[ -e "$KEYRING" ]]; then KEYRING_PRESENT=1; fi

# Another apt source (VS Code, for instance) may point at the same keyring.
KEYRING_SHARED=0
if (( KEYRING_PRESENT )); then
    if grep -rls -- "$KEYRING" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
        | grep -qv '/etc/apt/sources.list.d/mssql-server'; then
        KEYRING_SHARED=1
    fi
fi

if (( ! PKG_INSTALLED )) && [[ "${#DIRS[@]}" -eq 0 ]] && [[ "${#UNITS[@]}" -eq 0 ]] \
    && [[ ! -e "$BASE_DIR" ]] && [[ "${#REPO_FILES[@]}" -eq 0 ]] && (( ! KEYRING_PRESENT )); then
    info "nothing to remove - no mssql-server package, instances, data or apt source found"
    exit 0
fi

# --- decide about the data (the question comes after the plan) --------------
# ask = the plan is printed first and the data question is asked afterwards, so
# --dry-run can show the whole picture without asking anything.
DATA_MODE="ask"
if (( KEEP_DATA )); then DATA_MODE="no"
elif (( ASSUME_YES )); then DATA_MODE="yes"
fi

DATA_PATHS="$BASE_DIR"
if [[ -d "$INSTANCE_ROOT" ]]; then DATA_PATHS="$DATA_PATHS, $INSTANCE_ROOT"; fi

# --- plan -------------------------------------------------------------------
printf '\nPlan\n'
printf '  running now    : %s\n' "${RUNNING_UNITS:-nothing}"
if (( DIRS_UNREADABLE )); then
    printf '                   (%s cannot be listed without root)\n' "$INSTANCE_ROOT"
fi
printf '  stop + disable : '
if (( PKG_INSTALLED )) || [[ "${#UNITS[@]}" -gt 0 ]]; then
    printf '%s%s\n' "$BASE_UNIT" \
        "$( [[ "${#UNITS[@]}" -gt 0 ]] && printf ' %s' "${UNITS[*]}" || true )"
else
    printf '(nothing found)\n'
fi
if (( PKG_INSTALLED )); then
    printf '  purge package  : %s %s   (removes /opt/mssql)\n' "$PKG" "${PKG_VERSION:-?}"
else
    printf '  purge package  : (not installed)\n'
fi
printf '  delete data    : '
case "$DATA_MODE" in
    no)  printf 'no (--keep-data)\n' ;;
    yes) printf '%s   (every database in them)\n' "$DATA_PATHS" ;;
    ask) printf '%s   (asks first: type "erase")\n' "$DATA_PATHS" ;;
esac
if [[ -e "$TEMPLATE_UNIT" ]]; then printf '  remove unit    : %s\n' "$TEMPLATE_UNIT"; fi
if (( KEEP_REPO )); then
    printf '  remove repo    : no (--keep-repo)\n'
else
    if [[ "${#REPO_FILES[@]}" -gt 0 ]]; then
        printf '  remove repo    : %s\n' "${REPO_FILES[*]}"
    fi
    if (( KEYRING_PRESENT )); then
        if (( KEYRING_SHARED )); then
            printf '  remove keyring : no, %s is still used by another apt source\n' "$KEYRING"
        else
            printf '  remove keyring : %s\n' "$KEYRING"
        fi
    fi
fi
printf '  keep           : mssql user/group, sqlcmd tools\n\n'

if (( DRY_RUN )); then
    info "dry run - nothing was changed"
    if [[ "$DATA_MODE" == "ask" ]]; then
        printf '    a real run would ask you to type "erase" before deleting the data directories\n'
    fi
    exit 0
fi

# --- the data question ------------------------------------------------------
case "$DATA_MODE" in
    yes)
        PURGE_DATA=1
        ;;
    no)
        PURGE_DATA=0
        info "keeping $DATA_PATHS (--keep-data)"
        ;;
    ask)
        [[ -t 0 ]] || die "no TTY to ask about deleting data on; use --keep-data or --yes"
        printf 'The data directories above hold every database, the additional instances included.\n'
        read -r -p "Delete them as well? Type 'erase' to confirm: " reply
        if [[ "$reply" == "erase" ]]; then
            PURGE_DATA=1
        else
            PURGE_DATA=0
            info "keeping $DATA_PATHS"
        fi
        ;;
esac

# --- stop and disable -------------------------------------------------------
for unit in "${UNITS[@]}" "$BASE_UNIT"; do
    unit_exists "$unit" || continue
    info "stopping and disabling $unit"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

# --- purge the package ------------------------------------------------------
if (( PKG_INSTALLED )); then
    info "purging $PKG (its prerm stops/disables mssql-server itself)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PKG"
else
    info "$PKG is not installed; skipping apt"
fi

systemctl daemon-reload
systemctl reset-failed "$BASE_UNIT" >/dev/null 2>&1 || true

# --- remove the project's own files ----------------------------------------
if [[ -e "$TEMPLATE_UNIT" ]]; then
    info "removing $TEMPLATE_UNIT"
    rm -f -- "$TEMPLATE_UNIT"
fi

if (( PURGE_DATA )); then
    if [[ -d "$INSTANCE_ROOT" ]]; then
        info "deleting $INSTANCE_ROOT (all additional instances)"
        rm -rf -- "$INSTANCE_ROOT"
    fi
    if [[ -d "$BASE_DIR" ]]; then
        info "deleting $BASE_DIR (all databases of the base instance)"
        rm -rf -- "$BASE_DIR"
    fi
fi
rmdir "$INSTANCE_ROOT" 2>/dev/null || true

if (( ! KEEP_REPO )); then
    for f in "${REPO_FILES[@]}"; do
        info "removing $f"
        rm -f -- "$f"
    done
    if (( KEYRING_PRESENT && ! KEYRING_SHARED )); then
        info "removing $KEYRING"
        rm -f -- "$KEYRING"
    fi
fi

# --- what is left -----------------------------------------------------------
printf '\nLeftovers\n'
for path in /opt/mssql "$BASE_DIR" "$INSTANCE_ROOT" "$TEMPLATE_UNIT"; do
    if [[ -e "$path" ]]; then
        printf '  still there : %s\n' "$path"
    fi
done
if getent passwd mssql >/dev/null; then
    printf '  mssql user  : still there (fine, the package recreates it if needed)\n'
fi
if dpkg-query -W mssql-server >/dev/null 2>&1; then
    printf '  package     : still installed (the purge failed?)\n' >&2
else
    printf '  package     : gone\n'
fi

cat <<EOF

Next, to test the installer from this clean slate:

  sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' $SCRIPT_DIR/mssql-base-install.sh

Without a cached apt candidate it also adds the Microsoft repository and key
again, so it needs network access on the first run.
EOF
