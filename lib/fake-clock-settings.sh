#!/usr/bin/env bash
# Sourced by protectemmc.sh; preserve loading the last saved clock at boot.
# Verified against Debian fake-hwclock 0.12, 0.14 and 0.15 source tarballs.
fake_clock_stage() {
    local path=$1
    stage_file "$path"
    python3 - "$WORK/stage$path" <<'PY'
import pathlib
import re
import sys

p = pathlib.Path(sys.argv[1])
raw = p.read_bytes()
if not raw or b'\r' in raw or b'\x00' in raw:
    sys.exit('Empty or non-Unix fake-hwclock script; refusing to modify')
try:
    text = raw.decode('utf-8')
except UnicodeDecodeError:
    sys.exit('Unknown fake-hwclock encoding; refusing to modify')
marker = '        exit 0 # emmc-protect: disable fake-hwclock save\n'
if text.splitlines()[0] not in ('#!/bin/sh', '#!/bin/bash', '#!/usr/bin/bash', '#!/usr/bin/env bash'):
    sys.exit('Unknown fake-hwclock interpreter; refusing to modify')
# Restrict changes to the known top-level Debian command dispatcher. A changed
# package must be reviewed before it is patched; never suppress the load action.
patterns = [r'^COMMAND=\$1$', r'^case \$COMMAND in$', r'^    save\)$',
            r'^    load\)$', r'^esac$']
matches = [list(re.finditer(pattern, text, re.M)) for pattern in patterns]
if any(len(items) != 1 for items in matches):
    sys.exit('Unknown fake-hwclock dispatcher; refusing to modify')
positions = [items[0].start() for items in matches]
if positions != sorted(positions):
    sys.exit('Unknown fake-hwclock command order; refusing to modify')
save_end = matches[2][0].end()
if text[save_end:save_end + 1] != '\n':
    sys.exit('Unknown fake-hwclock save branch; refusing to modify')
insertion = save_end + 1
if 'emmc-protect: disable fake-hwclock save' in text:
    if text.count(marker) != 1 or not text[insertion:].startswith(marker):
        sys.exit('Unexpected fake-hwclock protection marker; refusing to modify')
else:
    p.write_bytes((text[:insertion] + marker + text[insertion:]).encode('utf-8'))
PY
    bash -n "$WORK/stage$path"
    CHANGED+=("$path")
}

prepare_fake_clock_settings() {
    local path resolved previous=
    for path in /sbin/fake-hwclock /usr/sbin/fake-hwclock; do
        [[ -e $path || -L $path ]] || continue
        [[ -f $path && ! -L $path ]] || die "拒绝修改非普通文件 fake-hwclock：$path"
        resolved=$(readlink -f -- "$path") || die "无法解析 fake-hwclock 路径：$path"
        case "$resolved" in
            /sbin/fake-hwclock|/usr/sbin/fake-hwclock) ;;
            *) die "未知 fake-hwclock 实际路径：$resolved" ;;
        esac
        [[ $resolved != "$previous" ]] || continue
        fake_clock_stage "$resolved"
        previous=$resolved
    done
    if [[ -n $previous ]]; then
        info 'fake-hwclock：禁用 save 写入，保留 load；软件包升级后请重新运行保护脚本'
    else
        info '未安装 fake-hwclock，跳过其保存保护'
    fi
    return 0
}
