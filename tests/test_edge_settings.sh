#!/usr/bin/env bash
# Run with bash tests/test_edge_settings.sh; no root or running systemd needed.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ${1:-} != --case ]]; then
    failures=0
    for test in installed absent old_systemd masked unknown_version query_failure; do
        if bash "$0" --case "$test"; then
            printf 'PASS %s\n' "$test"
        else
            printf 'FAIL %s\n' "$test" >&2
            failures=$((failures + 1))
        fi
    done
    exit "$failures"
fi

source "$ROOT/lib/edge-settings.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
WORK=$SANDBOX/work
CHANGED=()
MOCK_STATE=loaded
MOCK_VERSION=252
MOCK_QUERY_RC=0
: > "$SANDBOX/calls"
: > "$SANDBOX/unexpected"
info() { printf '%s\n' "$*" >> "$SANDBOX/messages"; }
warn() { printf '%s\n' "$*" >> "$SANDBOX/messages"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
contains() { grep -Fqx -- "$2" "$1" || fail "Missing line: $2"; }

stage_file() {
    case "$1" in
        "$EDGE_TIMESYNC_CONF"|"$EDGE_FSTRIM_CONF"|"$EDGE_MANDB_CONF") ;;
        *) fail "Unexpected staged target: $1" ;;
    esac
    mkdir -p -- "$WORK/stage$(dirname -- "$1")"
}

# The mock never delegates to the host. Record forbidden calls even if the
# implementation swallows their failure (e.g. systemctl stop ... || return 0).
systemctl() {
    printf '%s\n' "$*" >> "$SANDBOX/calls"
    case "$*" in
        --version) printf 'systemd %s (mock)\n+PAM +AUDIT\n' "$MOCK_VERSION" ;;
        'show --property=LoadState --value systemd-timesyncd.service'|\
        'show --property=LoadState --value fstrim.timer'|\
        'show --property=LoadState --value man-db.service')
            printf '%s\n' "$MOCK_STATE"
            return "$MOCK_QUERY_RC" ;;
        *) printf 'systemctl %s\n' "$*" >> "$SANDBOX/unexpected"; return 1 ;;
    esac
}
mount() { printf 'mount %s\n' "$*" >> "$SANDBOX/unexpected"; return 1; }
umount() { printf 'umount %s\n' "$*" >> "$SANDBOX/unexpected"; return 1; }

case "$2" in
    installed) ;;
    absent) MOCK_STATE=not-found ;;
    old_systemd) MOCK_VERSION=232 ;;
    masked) MOCK_STATE=masked ;;
    unknown_version) MOCK_VERSION=unknown ;;
    query_failure) MOCK_QUERY_RC=1 ;;
    *) fail "Unknown case: $2" ;;
esac

# Run unconditionally under errexit: optional skips must explicitly succeed.
prepare_edge_settings
[[ ! -s $SANDBOX/unexpected ]] || fail 'Attempted a live service/mount operation'
case "$2" in
    installed|masked)
        [[ ${#CHANGED[@]} == 3 && ${CHANGED[2]} == "$EDGE_MANDB_CONF" ]]
        [[ ${CHANGED[0]} == "$EDGE_TIMESYNC_CONF" && ${CHANGED[1]} == "$EDGE_FSTRIM_CONF" ]]
        contains "$WORK/stage$EDGE_TIMESYNC_CONF" 'StateDirectory='
        contains "$WORK/stage$EDGE_TIMESYNC_CONF" 'RuntimeDirectory=emmc-protect-timesync'
        contains "$WORK/stage$EDGE_TIMESYNC_CONF" 'RuntimeDirectoryMode=0755'
        contains "$WORK/stage$EDGE_TIMESYNC_CONF" 'BindPaths=/run/emmc-protect-timesync:/var/lib/systemd/timesync'
        contains "$WORK/stage$EDGE_FSTRIM_CONF" 'ConditionPathExists=!/'
        contains "$WORK/stage$EDGE_MANDB_CONF" 'ConditionPathExists=!/'
        ;;
    absent|query_failure)
        [[ ${#CHANGED[@]} == 0 && ! -e $WORK ]]
        ! grep -Fqx -- '--version' "$SANDBOX/calls"
        ;;
    old_systemd|unknown_version)
        [[ ${#CHANGED[@]} == 2 && ${CHANGED[0]} == "$EDGE_FSTRIM_CONF" && ${CHANGED[1]} == "$EDGE_MANDB_CONF" ]]
        [[ ! -e $WORK/stage$EDGE_TIMESYNC_CONF ]]
        contains "$WORK/stage$EDGE_FSTRIM_CONF" 'ConditionPathExists=!/'
        contains "$WORK/stage$EDGE_MANDB_CONF" 'ConditionPathExists=!/'
        ;;
esac
