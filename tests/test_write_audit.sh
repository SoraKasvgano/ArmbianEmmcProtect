#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/write-audit.sh"
AUDIT_TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$AUDIT_TEST_DIR"' EXIT
mkdir -p "$AUDIT_TEST_DIR"/{etc/redis,etc/docker,etc/cron.hourly,proc/sys/kernel,proc/sys/vm,var/lib/redis,var/log}
printf 'appendonly yes\nrequirepass NEVER_PRINT_THIS_SECRET\n' > "$AUDIT_TEST_DIR/etc/redis/redis.conf"
printf '{"log-driver":"json-file","secret":"NEVER_PRINT_THIS_SECRET"}\n' > "$AUDIT_TEST_DIR/etc/docker/daemon.json"
printf '#!/bin/sh\n/usr/sbin/fake-hwclock save\n' > "$AUDIT_TEST_DIR/etc/cron.hourly/fake-hwclock"
printf '|/usr/bin/handler NEVER_PRINT_THIS_SECRET\n' > "$AUDIT_TEST_DIR/proc/sys/kernel/core_pattern"
printf '500\n' > "$AUDIT_TEST_DIR/proc/sys/vm/dirty_writeback_centisecs"
info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*"; }
systemctl() {
    [[ $1 == show && $2 == --property=LoadState,ActiveState,UnitFileState ]] || exit 98
    case "$3" in
        redis-server.service) printf 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n' ;;
        *) return 1 ;;
    esac
}
findmnt() {
    [[ $# == 4 && $1 == -T && $3 == -o && $4 == TARGET,SOURCE,FSTYPE,OPTIONS ]] || exit 97
    printf '/ ext4 rw,noatime\n'
}
forbidden() { printf 'Unexpected mutation\n' >&2; exit 96; }
sysctl() { forbidden; }
service() { forbidden; }
mount() { forbidden; }
du() { forbidden; }
output=$(scan_write_sources "$AUDIT_TEST_DIR")
[[ $output != *NEVER_PRINT_THIS_SECRET* ]]
[[ $output == *'/etc/redis/redis.conf'* && $output == *'/etc/docker/daemon.json'* ]]
[[ $output == *'/etc/cron.hourly/fake-hwclock'* ]]
[[ $output == *'vm.dirty_writeback_centisecs=500'* && $output == *'redis-server.service'* ]]
# Strict mode must survive errors from every optional external reader.
systemctl() { return 1; }
findmnt() { return 1; }
grep() { return 2; }
scan_write_sources "$AUDIT_TEST_DIR" > /dev/null
unset -f systemctl findmnt grep
# The scan has a builtin-only fallback when optional commands are absent.
PATH=/nonexistent scan_write_sources "$AUDIT_TEST_DIR" > /dev/null
PATH=/nonexistent scan_write_sources "$AUDIT_TEST_DIR/missing" > /dev/null
printf 'write source audit tests passed\n'
