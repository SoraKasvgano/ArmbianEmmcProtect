#!/usr/bin/env bash
# Run with bash tests/test_protectemmc.sh. All configuration lives in a sandbox.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ${1:-} != --case ]]; then
    failures=0
    for test in journal_only staging tmp_conflict root_conflict docker_merge docker_duplicates dry_run commit_restore restore_transaction cron cron_unknown rollback swap_activation_failure swap_health_failure swap_dry_run swap_off_failure swap_success swap_repeat_off_failure swap_delete_failure; do
        if bash "$0" --case "$test"; then
            printf 'PASS %s\n' "$test"
        else
            printf 'FAIL %s\n' "$test" >&2
            failures=$((failures + 1))
        fi
    done
    exit "$failures"
fi

source "$ROOT/protectemmc.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
JOURNAL_CONF=$SANDBOX/etc/systemd/journald.conf.d/99-emmc-protect.conf
FSTAB=$SANDBOX/etc/fstab
DOCKER_CONF=$SANDBOX/etc/docker/daemon.json
BACKUP_ROOT=$SANDBOX/backups
WORK=$SANDBOX/work
MODE=apply
mkdir -p "$WORK" "$(dirname "$FSTAB")" "$(dirname "$DOCKER_CONF")"
CALLS=$SANDBOX/calls
: > "$CALLS"

# No commands in this suite contact a real service or validate host mounts.
systemctl() { printf '%s\n' "$*" >> "$CALLS"; }
findmnt() { [[ $1 == --verify && $2 == --tab-file && -f $3 ]]; }
dockerd() { [[ $1 == --validate && $2 == --config-file && -f $3 ]]; }
# Simulate root-owned backups, also allowing unprivileged Linux and Git Bash runs.
stat() {
    if [[ $1 == -c && $2 == %u ]]; then printf '0\n'
    elif [[ $1 == -c && $2 == %a ]]; then printf '700\n'
    else command stat "$@"; fi
}
if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* ]]; then
    # Windows Python needs native paths for argv; stdin is still ordinary Python.
    python3() {
        local arg args=()
        for arg in "$@"; do
            if [[ $arg == /* ]]; then arg=$(cygpath -m "$arg"); fi
            args+=("$arg")
        done
        command python "${args[@]}"
    }
fi
fail() { printf '%s\n' "$*" >&2; exit 1; }
contains() { grep -Fqx -- "$2" "$1" || fail "Missing expected line in $1: $2"; }
fresh_stage() { WORK=$(mktemp -d "$SANDBOX/stage.XXXXXX"); CHANGED=(); JOURNAL_CHANGED=0; }
swap_mocks() {
    ZRAM=1 REMOVE_DISK_SWAP=1
    SWAP_CALLS=$SANDBOX/swap-calls
    : > "$SWAP_CALLS"
    activate_zram() { printf 'activate\n' >> "$SWAP_CALLS"; return "${ACTIVATE_RC:-0}"; }
    healthy_zram() { printf 'healthy\n' >> "$SWAP_CALLS"; return "${HEALTH_RC:-0}"; }
    prepare_disk_swap_removal() {
        printf 'prepare\n' >> "$SWAP_CALLS"
        stage_file "$FSTAB"
        printf '# swap removed\n' >> "$WORK/stage$FSTAB"
        CHANGED+=("$FSTAB")
        printf '{}\n' > "$WORK/disk-swaps.json"
    }
    if declare -F python3 >/dev/null; then
        eval "$(declare -f python3 | sed '1s/python3/python3_original/')"
    else
        python3_original() { command python3 "$@"; }
    fi
    python3() {
        if [[ $1 == "$SCRIPT_DIR/lib/swap-protect.py" ]]; then
            printf '%s\n' "$2" >> "$SWAP_CALLS"
            case "$2" in
                off)
                    contains "$FSTAB" '# swap removed'
                    return "${OFF_RC:-0}"
                    ;;
                delete)
                    [[ $(tail -n 2 "$SWAP_CALLS" | head -n 1) == off ]] || fail 'Delete ran before off'
                    return "${DELETE_RC:-0}"
                    ;;
                *) fail "Unexpected swap command: $2" ;;
            esac
        else
            python3_original "$@"
        fi
    }
}
printf '# preserve me\nUUID=root / ext4 defaults,relatime,errors=remount-ro,commit=5 0 1\n' > "$FSTAB"
cp "$FSTAB" "$SANDBOX/original-fstab"

case "$2" in
journal_only)
    # Optional features disabled must still return success under errexit.
    prepare_apply
    [[ ${#CHANGED[@]} == 1 && ${CHANGED[0]} == "$JOURNAL_CONF" ]]
    DRY_RUN=1
    commit_changes
    [[ ! -e $JOURNAL_CONF && ! -e $BACKUP_ROOT && ! -s $CALLS ]]
    ;;
staging)
    NOATIME=1 TMP_SIZE=64M
    prepare_apply
    contains "$WORK/stage$JOURNAL_CONF" 'Storage=volatile'
    contains "$WORK/stage$JOURNAL_CONF" 'ForwardToSyslog=no'
    contains "$WORK/stage$JOURNAL_CONF" 'RuntimeMaxUse=32M'
    contains "$WORK/stage$FSTAB" '# preserve me'
    grep -q 'defaults,errors=remount-ro,commit=5,noatime' "$WORK/stage$FSTAB"
    grep -q 'mode=1777,size=64M' "$WORK/stage$FSTAB"
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    cp "$WORK/stage$FSTAB" "$FSTAB"
    cp "$FSTAB" "$SANDBOX/expected-fstab"
    fresh_stage
    prepare_apply
    cmp "$WORK/stage$FSTAB" "$SANDBOX/expected-fstab"
    [[ $(grep -c $'\t/tmp\t' "$WORK/stage$FSTAB") == 1 ]]
    ;;
tmp_conflict)
    printf '/dev/example /tmp ext4 defaults 0 2\n' >> "$FSTAB"
    TMP_SIZE=64M
    # A child shell retains errexit; an `if prepare_apply` would suppress it.
    set +e
    (set -e; prepare_apply) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]]
    grep -q '/tmp' "$SANDBOX/error"
    [[ ! -e $JOURNAL_CONF && ! -e $BACKUP_ROOT ]]
    ;;
root_conflict)
    printf 'UUID=other / ext4 defaults 0 1\n' >> "$FSTAB"
    NOATIME=1
    set +e
    (set -e; prepare_apply) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 && ! -e $JOURNAL_CONF ]]
    ;;
docker_merge)
    printf '{"data-root":"/srv/docker","registry-mirrors":["https://example.invalid"],"log-driver":"json-file","log-opts":{"max-size":"10m"}}\n' > "$DOCKER_CONF"
    DOCKER_LOG=1
    prepare_apply
    python3 - "$WORK/stage$DOCKER_CONF" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d['data-root'] == '/srv/docker'
assert d['registry-mirrors'] == ['https://example.invalid']
assert d['log-driver'] == 'journald'
assert d['log-opts'] == {'tag': '{{.Name}}'}
PY
    printf '{"log-driver":"journald","log-opts":{"tag":"custom"},"debug":false}\n' > "$DOCKER_CONF"
    fresh_stage
    prepare_apply
    python3 - "$WORK/stage$DOCKER_CONF" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d['log-opts'] == {'tag': 'custom'}
assert d['debug'] is False
PY
    ;;
docker_duplicates)
    printf '{"debug":true,"debug":false}\n' > "$DOCKER_CONF"
    DOCKER_LOG=1
    set +e
    (set -e; prepare_apply) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 && ! -e $JOURNAL_CONF && ! -e $BACKUP_ROOT ]]
    ;;
dry_run)
    NOATIME=1 TMP_SIZE=64M DOCKER_LOG=1 DRY_RUN=1
    prepare_apply
    atomic_copy() { fail 'Dry run attempted a configuration write'; }
    commit_changes
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    [[ ! -e $JOURNAL_CONF && ! -e $DOCKER_CONF && ! -e $BACKUP_ROOT && ! -s $CALLS ]]
    ;;
commit_restore)
    NOATIME=1 TMP_SIZE=64M DOCKER_LOG=1
    prepare_apply
    commit_changes
    first_backup=$BACKUP
    cp "$CALLS" "$SANDBOX/first-calls"
    contains "$CALLS" 'daemon-reload'
    contains "$CALLS" 'restart systemd-journald.service'
    fresh_stage
    prepare_apply
    (atomic_copy() { fail 'Repeated apply attempted a configuration write'; }; commit_changes)
    [[ $BACKUP == "$first_backup" ]]
    [[ $(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]]
    cmp "$CALLS" "$SANDBOX/first-calls"
    restore_files "$first_backup"
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    [[ ! -e $JOURNAL_CONF && ! -e $DOCKER_CONF ]]
    ;;
restore_transaction)
    NOATIME=1 DOCKER_LOG=1
    prepare_apply
    commit_changes
    apply_backup=$BACKUP
    cp "$FSTAB" "$SANDBOX/applied-fstab"
    fresh_stage
    MODE=restore RESTORE_DIR=$apply_backup
    prepare_restore
    # Preparation alone does not change the applied configuration.
    cmp "$FSTAB" "$SANDBOX/applied-fstab"
    [[ -f $JOURNAL_CONF && -f $DOCKER_CONF ]]
    commit_changes
    restore_backup=$BACKUP
    [[ $restore_backup != "$apply_backup" ]]
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    [[ ! -e $JOURNAL_CONF && ! -e $DOCKER_CONF ]]
    # Restore is itself reversible using the new backup it creates.
    fresh_stage
    RESTORE_DIR=$restore_backup
    prepare_restore
    commit_changes
    cmp "$FSTAB" "$SANDBOX/applied-fstab"
    [[ -f $JOURNAL_CONF && -f $DOCKER_CONF ]]
    ;;
cron)
    cron=$SANDBOX/man-db
    printf '#!/bin/sh\nprintf executed > "$1"\n' > "$cron"
    stage_man_db_cron "$cron"
    contains "$WORK/stage$cron" 'exit 0 # emmc-protect: disable periodic man-db writes'
    bash "$WORK/stage$cron" "$SANDBOX/marker"
    [[ ! -e $SANDBOX/marker ]]
    cp "$WORK/stage$cron" "$cron"
    fresh_stage
    stage_man_db_cron "$cron"
    cmp "$cron" "$WORK/stage$cron"
    [[ $(grep -c 'exit 0 # emmc-protect:' "$WORK/stage$cron") == 1 ]]
    stage_man_db_cron "$SANDBOX/nonexistent-cron"
    [[ ${#CHANGED[@]} == 1 ]]
    ;;
cron_unknown)
    cron=$SANDBOX/man-db
    printf '#!/usr/bin/python3\nprint("unexpected")\n' > "$cron"
    cp "$cron" "$SANDBOX/original-cron"
    set +e
    (set -e; stage_man_db_cron "$cron") > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]]
    cmp "$cron" "$SANDBOX/original-cron"
    grep -q 'man-db cron' "$SANDBOX/error"
    ;;
rollback)
    NOATIME=1 DOCKER_LOG=1
    prepare_apply
    systemctl() {
        printf '%s\n' "$*" >> "$CALLS"
        if [[ $1 == restart && ! -f $SANDBOX/restart-failed ]]; then
            touch "$SANDBOX/restart-failed"
            return 42
        fi
        return 0
    }
    set +e
    (set -e; trap 'on_failure $?' ERR; commit_changes) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc == 42 ]] || fail "Expected injected failure 42, got $rc"
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    [[ ! -e $JOURNAL_CONF && ! -e $DOCKER_CONF ]]
    [[ $(grep -c '^restart ' "$CALLS") == 2 ]]
    ;;
swap_activation_failure|swap_health_failure)
    swap_mocks
    if [[ $2 == swap_activation_failure ]]; then ACTIVATE_RC=9; else HEALTH_RC=8; fi
    set +e
    (set -e; trap 'on_failure $?' ERR; manage_swap) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc != 0 ]]
    ! grep -Eq '^(prepare|off|delete)$' "$SWAP_CALLS"
    [[ ! -e $BACKUP_ROOT ]]
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    ;;
swap_dry_run)
    swap_mocks
    DRY_RUN=1
    manage_swap
    contains "$SWAP_CALLS" prepare
    ! grep -Eq '^(activate|healthy|off|delete)$' "$SWAP_CALLS"
    [[ ! -e $BACKUP_ROOT && ! -s $CALLS ]]
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    ;;
swap_off_failure)
    swap_mocks
    OFF_RC=43
    set +e
    (set -e; trap 'on_failure $?' ERR; manage_swap) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc == 43 ]]
    contains "$SWAP_CALLS" off
    ! grep -qx delete "$SWAP_CALLS"
    cmp "$FSTAB" "$SANDBOX/original-fstab"
    [[ $(grep -c '^daemon-reload$' "$CALLS") == 2 ]]
    ;;
swap_success)
    swap_mocks
    manage_swap
    printf 'activate\nhealthy\nprepare\noff\ndelete\n' > "$SANDBOX/expected-swap-calls"
    cmp "$SWAP_CALLS" "$SANDBOX/expected-swap-calls"
    contains "$FSTAB" '# swap removed'
    [[ $COMMITTING == 0 ]]
    ;;
swap_repeat_off_failure)
    swap_mocks
    manage_swap
    cp "$FSTAB" "$SANDBOX/applied-fstab"
    cp "$CALLS" "$SANDBOX/first-calls"
    prepare_disk_swap_removal() {
        stage_file "$FSTAB"
        CHANGED+=("$FSTAB")
        printf '{}\n' > "$WORK/disk-swaps.json"
    }
    OFF_RC=43
    set +e
    (set -e; trap 'on_failure $?' ERR; manage_swap) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc == 43 ]]
    # A no-change second transaction must never roll back the first backup.
    cmp "$FSTAB" "$SANDBOX/applied-fstab"
    cmp "$CALLS" "$SANDBOX/first-calls"
    [[ $(grep -c '^delete$' "$SWAP_CALLS") == 1 ]]
    ;;
swap_delete_failure)
    swap_mocks
    DELETE_RC=44
    set +e
    (set -e; trap 'on_failure $?' ERR; manage_swap) > "$SANDBOX/error" 2>&1
    rc=$?
    set -e
    [[ $rc == 44 ]]
    # Some files may already be deleted, so never restore swap references here.
    contains "$FSTAB" '# swap removed'
    [[ $(grep -c '^daemon-reload$' "$CALLS") == 1 ]]
    ;;
*) fail "Unknown test: $2" ;;
esac
