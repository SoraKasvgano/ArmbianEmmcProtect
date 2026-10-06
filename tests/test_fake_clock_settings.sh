#!/usr/bin/env bash
# Isolated behavior checks: never invoke the host clock or host fake-hwclock.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/fake-clock-settings.sh"
if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* ]]; then
    python3() {
        local arg args=()
        for arg in "$@"; do
            if [[ $arg == /* ]]; then arg=$(cygpath -m "$arg"); fi
            args+=("$arg")
        done
        command python "${args[@]}"
    }
fi
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
WORK=$SANDBOX/work
CHANGED=()
stage_file() {
    mkdir -p -- "$WORK/stage$(dirname -- "$1")"
    cp -p -- "$1" "$WORK/stage$1"
}
fixture=$SANDBOX/fake-hwclock
# Keep upstream dispatch shape, replace clock operations with observable writes.
cat > "$fixture" <<'EOF'
#!/bin/sh
COMMAND=$1
if [ "$COMMAND"x = ""x ] ; then
    COMMAND="save"
fi
case $COMMAND in
    save)
        printf 'saved\n' >> "$FILE"
        ;;
    load)
        cat "$FILE"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 755 "$fixture"
fake_clock_stage "$fixture"
protected=$WORK/stage$fixture
export FILE=$SANDBOX/saved-clock
printf 'original\n' > "$FILE"
for args in '' save 'save force'; do
    # Intentional splitting exercises the three argument forms.
    sh "$protected" $args
    [[ $(cat "$FILE") == original ]]
done
[[ $(sh "$protected" load) == original ]]
[[ $(sh "$protected" load force) == original ]]
if sh "$protected" unknown; then exit 1; fi
[[ -x $protected ]]
[[ ${CHANGED[0]} == "$fixture" ]]
cp -- "$protected" "$fixture"
fake_clock_stage "$fixture"
cmp -- "$fixture" "$protected"
# Unknown or corrupted layouts must fail, before changing the input file.
for mutation in dispatcher duplicate marker interpreter empty crlf; do
    cp -- "$protected" "$SANDBOX/unknown"
    python3 - "$SANDBOX/unknown" "$mutation" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
kind = sys.argv[2]
if kind == 'dispatcher': s = s.replace('case $COMMAND in', 'case "$COMMAND" in')
if kind == 'duplicate': s += '\ncase $COMMAND in\n    save) exit 1 ;;\nesac\n'
if kind == 'marker': s = s.replace('exit 0 # emmc-protect:', 'exit 1 # emmc-protect:')
if kind == 'interpreter': s = s.replace('#!/bin/sh', '#!/usr/bin/python3')
if kind == 'empty': s = ''
if kind == 'crlf': s = s.replace('\n', '\r\n')
p.write_bytes(s.encode('utf-8'))
PY
    cp -- "$SANDBOX/unknown" "$SANDBOX/before"
    if bash -Eeuo pipefail -c '
        source "$1/lib/fake-clock-settings.sh"
        WORK=$2/work-reject
        CHANGED=()
        stage_file() { mkdir -p -- "$WORK/stage$(dirname -- "$1")"; cp -p -- "$1" "$WORK/stage$1"; }
        fake_clock_stage "$2/unknown"
    ' -- "$ROOT" "$SANDBOX" 2>/dev/null; then
        printf 'Unexpected acceptance: %s\n' "$mutation" >&2
        exit 1
    fi
    cmp -- "$SANDBOX/unknown" "$SANDBOX/before"
done
printf 'PASS fake-hwclock save/load, idempotence, mode, unknown-layout rejection\n'
