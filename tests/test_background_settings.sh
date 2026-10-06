#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/protectemmc.sh"
source "$ROOT/lib/background-settings.sh"
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
WORK=$SANDBOX/work
mkdir -p "$WORK"
CORE_CONF=$SANDBOX/etc/systemd/coredump.conf.d/99-emmc-protect.conf
CORE_SYSCTL=$SANDBOX/etc/sysctl.d/99-emmc-protect-coredump.conf
APT_CACHE_CONF=$SANDBOX/etc/apt/apt.conf.d/99-emmc-protect-cache
systemctl() { echo 'Unexpected live systemctl call' >&2; return 99; }
sysctl() { echo 'Unexpected live sysctl call' >&2; return 99; }
apt-config() {
    [[ $1 == -c && -f $2 && $3 == dump ]]
    grep -Fq 'Dir::Cache::pkgcache "";' "$2"
    grep -Fq 'APT::Keep-Downloaded-Packages "false";' "$2"
}
prepare_background_settings
[[ ${#CHANGED[@]} == 3 ]]
grep -Fxq 'Storage=none' "$WORK/stage$CORE_CONF"
grep -Fxq 'ProcessSizeMax=0' "$WORK/stage$CORE_CONF"
grep -Fxq 'kernel.core_pattern=|/bin/false' "$WORK/stage$CORE_SYSCTL"
! grep -Eq 'Periodic|Unattended|Pre-Invoke|Post-Invoke' "$WORK/stage$APT_CACHE_CONF"
[[ ! -e $CORE_CONF && ! -e $CORE_SYSCTL && ! -e $APT_CACHE_CONF ]]
cp "$WORK/stage$APT_CACHE_CONF" "$SANDBOX/expected"
CHANGED=()
prepare_background_settings
cmp "$SANDBOX/expected" "$WORK/stage$APT_CACHE_CONF"

# Failed validation never writes host configuration or mutates services.
apt-config() { return 42; }
set +e
(set -e; prepare_background_settings) > "$SANDBOX/error" 2>&1
rc=$?
set -e
[[ $rc != 0 && ! -e $APT_CACHE_CONF && ! -e $CORE_CONF ]]

# Optional APT is absent on other distributions.
command() {
    if [[ ${1:-} == -v && ${2:-} == apt-config ]]; then return 1; fi
    builtin command "$@"
}
CHANGED=()
prepare_background_settings
[[ ${#CHANGED[@]} == 2 ]]
atomic_copy "$WORK/stage$CORE_CONF" "$CORE_CONF"
cmp "$WORK/stage$CORE_CONF" "$CORE_CONF"
if [[ $(uname -s) == Linux ]]; then
    [[ $(stat -c %a "$(dirname "$CORE_CONF")") == 755 ]]
fi
echo 'background settings tests passed'
