#!/usr/bin/env bash
# Reversible flash-write reduction for Armbian, DietPi and Debian/systemd.
set -Eeuo pipefail
umask 077

BACKUP_ROOT=/var/backups/emmc-protect
JOURNAL_CONF=/etc/systemd/journald.conf.d/99-emmc-protect.conf
FSTAB=/etc/fstab
DOCKER_CONF=/etc/docker/daemon.json
MODE=check
DRY_RUN=0
NOATIME=0
TMP_SIZE=
DOCKER_LOG=0
EDGE=0
ZRAM=0
REMOVE_DISK_SWAP=0
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RAMLOG_SCRIPT=/usr/lib/armbian/armbian-ramlog
RESTORE_DIR=
WORK=
BACKUP=
COMMITTING=0
JOURNAL_CHANGED=0
CHANGED=()

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
用法：sudo bash protectemmc.sh [选项]
  --check              只读巡检（默认，无需 root）
  --apply              设置 journald 为限额内存日志，关闭向 syslog 转发
  --edge               极端减写入：noatime、禁 TRIM/man-db 任务、timesyncd 状态内存化、ramlog 禁同步
  --dry-run            与 --apply / --restore 配合，仅预演，不修改配置
  --noatime            同时修改 fstab 中明确的根分区条目，重启生效
  --tmp-size SIZE      同时将 /tmp 配为 tmpfs，例如 64M、128M，重启生效
  --docker-journald    合并 Docker 默认日志配置，稍后手动重启并重建容器
  --zram               检测并通过 Armbian/DietPi 的机制启用 zram
  --remove-disk-swap   同时启用 zram，确认可用后停用磁盘 swap 并删除原 swapfile
  --restore DIR        恢复本工具的一次备份（按新到旧顺序恢复）
  -h, --help           显示帮助

默认保留 swap、TRIM、日志轮转、发行版 RAM 日志管理和时间持久化。
内存 journal 重启丢失；其他日志、数据库、容器数据仍可能写盘。
不在线覆盖 /var/log 或 /var/tmp，不延长文件系统 commit 时间。
EOF
}

parse_args() {
    local selected= arg
    while (($#)); do
        arg=$1
        case "$arg" in
            --check|--apply|--restore)
                [[ -z $selected ]] || die '只能选择一种操作模式'
                selected=$arg; MODE=${arg#--}
                if [[ $MODE == restore ]]; then
                    (($# >= 2)) || die '--restore 缺少备份目录'
                    RESTORE_DIR=$2; shift
                fi ;;
            --dry-run) DRY_RUN=1 ;;
            --noatime) NOATIME=1 ;;
            --tmp-size)
                (($# >= 2)) || die '--tmp-size 缺少大小'
                TMP_SIZE=$2; shift
                [[ $TMP_SIZE =~ ^[1-9][0-9]*[MG]$ ]] || die '大小格式应为 64M 或 1G' ;;
            --docker-journald) DOCKER_LOG=1 ;;
            --edge) EDGE=1; NOATIME=1 ;;
            --zram) ZRAM=1 ;;
            --remove-disk-swap) REMOVE_DISK_SWAP=1; ZRAM=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "未知参数：$arg" ;;
        esac
        shift
    done
    if [[ $MODE != apply ]] && ((NOATIME || DOCKER_LOG || ZRAM)); then
        die '配置选项仅用于 --apply'
    fi
    [[ $MODE == apply || -z $TMP_SIZE ]] || die '--tmp-size 仅用于 --apply'
    [[ $MODE != check || $DRY_RUN == 0 ]] || die '--check 已是只读，无需 --dry-run'
}

unit_status() {
    local unit=$1 enabled active
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || :
        active=$(systemctl is-active "$unit" 2>/dev/null) || :
        printf '%s: %s / %s\n' "$unit" "${enabled:-not-found}" "${active:-unknown}"
    fi
}

scan_system() {
    local name options
    info '根文件系统（自动识别，不假定 sda）'
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -T / -o TARGET,SOURCE,FSTYPE,OPTIONS || :
        options=$(findmnt -nro OPTIONS --target /) || options=unknown
        if [[ ,$options, != *,noatime,* ]]; then
            info '可用 --noatime 减少访问时间更新（需 fstab 中有根分区条目）'
        fi
        info '日志及临时文件的实际承载文件系统'
        for name in /var/log /tmp /var/tmp /var/lib/systemd/timesync; do
            [[ ! -e $name ]] || findmnt -T "$name" -o TARGET,SOURCE,FSTYPE,OPTIONS || :
        done
    else
        warn '缺少 findmnt，跳过挂载诊断'
    fi
    if command -v lsblk >/dev/null 2>&1; then
        info '块设备及 TRIM 能力（定期 TRIM 通常有益，保持现有策略）'
        lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,DISC-GRAN,DISC-MAX || :
    fi
    info '本次开机各设备累计写入（512 字节/扇区；磁盘与分区数据不可相加）'
    if [[ -r /proc/diskstats ]]; then
        awk '$3 !~ /^(loop|ram|zram)/ {printf "%s: %s sectors\n", $3, $10}' /proc/diskstats
    fi
    info 'Swap：不自动 swapoff，避免内存不足；tmpfs 也可能经磁盘 swap 写盘'
    if [[ -r /proc/swaps ]]; then
        cat /proc/swaps
        while read -r name; do
            [[ $name == /dev/zram* ]] || warn "磁盘 swap：$name（请结合可用内存及发行版工具调整）"
        done < <(awk 'NR > 1 {print $1}' /proc/swaps)
    fi
    if command -v zramctl >/dev/null 2>&1; then
        info 'zram 容量、实际占用及压缩状态'
        zramctl || :
    fi
    for name in /sys/block/zram*/backing_dev; do
        [[ ! -r $name ]] || printf '%s: %s\n' "$name" "$(cat "$name")"
    done
    info '相关服务（缺失或 disabled 不影响巡检）'
    for name in systemd-journald.service rsyslog.service syslog-ng.service \
        armbian-ramlog.service armbian-ram-logging.service dietpi-ramlog.service \
        logrotate.timer fstrim.timer man-db.timer docker.service; do
        unit_status "$name"
    done
    info 'journald 配置候选项（最终值还受同名 drop-in 屏蔽及文件名排序影响）'
    for name in /usr/lib/systemd/journald.conf /etc/systemd/journald.conf \
        /usr/lib/systemd/journald.conf.d/*.conf /usr/local/lib/systemd/journald.conf.d/*.conf \
        /run/systemd/journald.conf.d/*.conf /etc/systemd/journald.conf.d/*.conf; do
        [[ ! -f $name ]] || grep -H -E '^[[:space:]]*(Storage|RuntimeMaxUse|RuntimeKeepFree|ForwardToSyslog)=' "$name" || :
    done
    if command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
        timeout 5 docker info --format 'Docker default logging driver: {{.LoggingDriver}}' 2>/dev/null || warn 'Docker 不可用或无访问权限，已跳过'
    fi
    warn '检查应用自有日志和 RAM 日志同步任务；volatile journald 不等于全系统零写入'
    if [[ -f $RAMLOG_SCRIPT ]]; then
        if grep -q 'flashprotect: no persistent log synchronization' "$RAMLOG_SCRIPT"; then
            info 'Armbian ramlog 存在减写入补丁标记（升级系统后请重新执行 --edge 预演核验）'
        else
            warn 'Armbian ramlog 未检测到补丁，可能将内存日志同步到介质'
        fi
    fi
    if [[ -f /etc/cron.hourly/fake-hwclock ]] || command -v fake-hwclock >/dev/null 2>&1; then
        warn '检测到 fake-hwclock：其持久化独立于 timesyncd，请检查发行版的保存任务'
    fi
}

allowed_path() {
    case "$1" in
        "$JOURNAL_CONF"|"$FSTAB"|"$DOCKER_CONF"|"$RAMLOG_SCRIPT"|\
        /etc/systemd/system/systemd-timesyncd.service.d/99-emmc-protect.conf|\
        /etc/systemd/system/fstrim.timer.d/99-emmc-protect.conf|\
        /etc/systemd/system/man-db.service.d/99-emmc-protect.conf|\
        /etc/cron.daily/man-db|/etc/cron.weekly/man-db|\
        /etc/default/armbian-zram-config|/etc/modules-load.d/dietpi-zram-swap.conf|\
        /etc/udev/rules.d/98-dietpi-zram-swap.rules|/etc/sysctl.d/98-dietpi-zram-swap.conf|\
        /etc/systemd/system/systemd-udevd.service.d/dietpi-zram.conf|/boot/dietpi.txt|\
        /etc/systemd/system/dphys-swapfile.service.d/99-emmc-protect.conf) return 0 ;;
        /etc/systemd/system/*.swap.d/99-emmc-protect.conf)
            local unit=${1#/etc/systemd/system/}
            unit=${unit%/99-emmc-protect.conf}
            [[ $unit != */* && $unit != *..* ]] ;;
        *) return 1 ;;
    esac
}
check_target() {
    local path=$1 parent
    [[ ! -L $path ]] || die "拒绝覆盖符号链接：$path"
    [[ ! -e $path || -f $path ]] || die "目标不是普通文件：$path"
    parent=$(dirname "$path")
    while [[ $parent != / ]]; do
        [[ ! -L $parent ]] || die "拒绝通过符号链接目录修改：$parent"
        parent=$(dirname "$parent")
    done
}
stage_file() {
    local path=$1
    check_target "$path"
    mkdir -p "$WORK/stage$(dirname "$path")"
    if [[ -f $path ]]; then cp -p -- "$path" "$WORK/stage$path"; fi
}

stage_man_db_cron() {
    local path=$1 first
    [[ -f $path ]] || return 0
    stage_file "$path"
    IFS= read -r first < "$path"
    case "$first" in
        '#!/bin/sh'|'#!/bin/bash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash') ;;
        *) die "未知 man-db cron 解释器，拒绝修改：$path" ;;
    esac
    if ! grep -Fxq 'exit 0 # emmc-protect: disable periodic man-db writes' "$path"; then
        awk 'NR == 1 {print; print "exit 0 # emmc-protect: disable periodic man-db writes"; next} {print}' "$path" > "$WORK/stage$path"
    fi
    bash -n "$WORK/stage$path"
    CHANGED+=("$path")
}

prepare_apply() {
    stage_file "$JOURNAL_CONF"
    cat > "$WORK/stage$JOURNAL_CONF" <<'EOF'
# Managed by emmc-protect. Applications may still write their own logs.
[Journal]
Storage=volatile
RuntimeMaxUse=32M
RuntimeKeepFree=16M
RuntimeMaxFileSize=4M
ForwardToSyslog=no
RateLimitIntervalSec=30s
RateLimitBurst=1000
EOF
    CHANGED+=("$JOURNAL_CONF")
    if ((NOATIME)) || [[ -n $TMP_SIZE ]]; then
        command -v python3 >/dev/null 2>&1 || die '修改 fstab 需要 python3；未修改配置'
        [[ -f $FSTAB ]] || die '缺少 /etc/fstab'
        if [[ -n $TMP_SIZE ]]; then
            [[ ! -e /etc/systemd/system/tmp.mount && ! -L /etc/systemd/system/tmp.mount && ! -e /run/systemd/system/tmp.mount ]] || die '/tmp 存在管理员自定义或屏蔽的挂载单元，请先协调该配置'
        fi
        stage_file "$FSTAB"
        python3 - "$WORK/stage$FSTAB" "$NOATIME" "$TMP_SIZE" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
noatime, tmp_size = sys.argv[2] == '1', sys.argv[3]
lines = p.read_text().splitlines(keepends=True)
roots, tmps = [], []
for i, line in enumerate(lines):
    fields = line.split()
    if not fields or fields[0].startswith('#'):
        continue
    if len(fields) < 4:
        raise SystemExit(f'fstab 第 {i+1} 行字段不足，停止修改')
    if fields[1] == '/':
        roots.append((i, fields))
    if fields[1] == '/tmp':
        tmps.append((i, fields))
if noatime:
    if len(roots) != 1:
        raise SystemExit('fstab 必须有且仅有一个明确的 / 条目；不猜测 overlay 或自动生成的根挂载')
    i, fields = roots[0]
    if fields[2] not in ('ext2', 'ext3', 'ext4', 'btrfs', 'xfs', 'f2fs'):
        raise SystemExit('根文件系统类型不在支持列表，请手动检查 noatime')
    opts = [x for x in fields[3].split(',') if x not in ('atime', 'relatime', 'strictatime', 'noatime')]
    fields[3] = ','.join(opts + ['noatime'])
    lines[i] = '\t'.join(fields) + '\n'
if tmp_size:
    if len(tmps) > 1:
        raise SystemExit('fstab 有多个 /tmp 条目，停止修改')
    if tmps:
        i, fields = tmps[0]
        if fields[2] != 'tmpfs':
            raise SystemExit('/tmp 已由其他文件系统管理，拒绝覆盖')
        opts = [x for x in fields[3].split(',') if not x.startswith('size=')]
        fields[3] = ','.join(opts + ['size=' + tmp_size])
        lines[i] = '\t'.join(fields) + '\n'
    else:
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        lines.extend(['# emmc-protect: temporary files in RAM\n',
            f'tmpfs\t/tmp\ttmpfs\trw,nosuid,nodev,mode=1777,size={tmp_size}\t0\t0\n'])
p.write_text(''.join(lines))
PY
        findmnt --verify --tab-file "$WORK/stage$FSTAB" || die 'fstab 验证失败；未修改配置'
        CHANGED+=("$FSTAB")
    fi
    if ((DOCKER_LOG)); then
        command -v python3 >/dev/null 2>&1 || die '合并 Docker 配置需要 python3'
        command -v dockerd >/dev/null 2>&1 || die '未找到 dockerd；未修改配置'
        stage_file "$DOCKER_CONF"
        python3 - "$WORK/stage$DOCKER_CONF" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
def unique(pairs):
    result = {}
    for k, v in pairs:
        if k in result:
            raise ValueError('Docker JSON 存在重复键: ' + k)
        result[k] = v
    return result
data = json.loads(p.read_text(), object_pairs_hook=unique) if p.exists() else {}
if not isinstance(data, dict):
    raise SystemExit('Docker 配置必须是 JSON 对象')
# Options for json-file/local are incompatible with journald.
if data.get('log-driver') != 'journald':
    data['log-opts'] = {'tag': '{{.Name}}'}
data['log-driver'] = 'journald'
p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
PY
        dockerd --validate --config-file "$WORK/stage$DOCKER_CONF" || die 'Docker 配置验证失败（需要支持 --validate 的版本）；未修改配置'
        CHANGED+=("$DOCKER_CONF")
    fi
    if ((EDGE)); then
        [[ -f $SCRIPT_DIR/lib/edge-settings.sh && -f $SCRIPT_DIR/lib/ramlog-protect.py ]] || die '缺少 lib 辅助文件，请保留完整仓库目录'
        # shellcheck source=lib/edge-settings.sh
        source "$SCRIPT_DIR/lib/edge-settings.sh"
        prepare_edge_settings
        stage_man_db_cron /etc/cron.daily/man-db
        stage_man_db_cron /etc/cron.weekly/man-db
        if [[ -f $RAMLOG_SCRIPT ]]; then
            stage_file "$RAMLOG_SCRIPT"
            python3 "$SCRIPT_DIR/lib/ramlog-protect.py" "$WORK/stage$RAMLOG_SCRIPT" "$WORK/stage$RAMLOG_SCRIPT"
            bash -n "$WORK/stage$RAMLOG_SCRIPT"
            CHANGED+=("$RAMLOG_SCRIPT")
        else
            info '未安装已知路径的 Armbian ramlog；未创建伪造配置。DietPi 请用 dietpi-ramlog 选择不保存日志的模式'
        fi
    fi
    if ((ZRAM)); then
        command -v python3 >/dev/null 2>&1 || die 'zram 管理需要 python3'
        [[ -f $SCRIPT_DIR/lib/zram-settings.sh && -f $SCRIPT_DIR/lib/swap-protect.py ]] || die '缺少 zram/swap 辅助文件，请使用完整仓库'
        # shellcheck source=lib/zram-settings.sh
        source "$SCRIPT_DIR/lib/zram-settings.sh"
        prepare_zram_settings
        [[ $ZRAM_BACKEND != unsupported ]] || die '无法安全配置 zram；未写入配置，请先解决上述检测问题'
    fi
}

healthy_zram() {
    python3 "$SCRIPT_DIR/lib/swap-protect.py" healthy-zram
}

stage_swap_unit() {
    local unit=$1 path
    [[ $unit == *.swap && $unit != */* && $unit != *..* ]] || die "不支持的 swap unit 名称：$unit"
    path=/etc/systemd/system/$unit.d/99-emmc-protect.conf
    stage_file "$path"
    printf '[Unit]\n# emmc-protect: disk swap disabled\nConditionPathExists=!/\n' > "$WORK/stage$path"
    CHANGED+=("$path")
}

prepare_disk_swap_removal() {
    local path unit what state
    python3 "$SCRIPT_DIR/lib/swap-protect.py" inspect > "$WORK/disk-swaps.json"
    [[ -f $FSTAB ]] || die '缺少 fstab，不能安全禁用持久 swap 配置'
    stage_file "$FSTAB"
    python3 "$SCRIPT_DIR/lib/swap-protect.py" disable-fstab "$WORK/stage$FSTAB" "$WORK/stage$FSTAB"
    findmnt --verify --tab-file "$WORK/stage$FSTAB" || die '禁用 swap 后 fstab 验证失败'
    CHANGED+=("$FSTAB")
    # Cover active devices, including GPT auto-generated swap units.
    python3 - "$WORK/disk-swaps.json" > "$WORK/swap-paths" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1]))['disk_swaps']:
    sys.stdout.buffer.write(item['path'].encode(errors='surrogateescape') + b'\0')
PY
    while IFS= read -r -d '' path; do
        unit=$(systemd-escape --path --suffix=swap "$path")
        stage_swap_unit "$unit"
    done < "$WORK/swap-paths"
    # Also cover inactive native units, whose What may use a /dev/disk alias.
    systemctl list-units --all --type=swap --plain --no-legend > "$WORK/swap-units"
    systemctl list-unit-files --type=swap --no-legend --no-pager >> "$WORK/swap-units"
    awk '{print $1}' "$WORK/swap-units" | sort -u > "$WORK/swap-unit-names"
    while read -r unit _; do
        [[ -n $unit ]] || continue
        what=$(systemctl show --property=What --value "$unit")
        if [[ -z $what ]]; then
            state=$(systemctl show --property=LoadState --value "$unit")
            [[ $state != masked ]] || continue
            die "无法解析 swap unit：$unit"
        fi
        path=$(realpath -m -- "$what")
        [[ $path == /dev/zram* ]] || stage_swap_unit "$unit"
    done < "$WORK/swap-unit-names"
    state=$(systemctl show --property=LoadState --value dphys-swapfile.service 2>/dev/null) || state=not-found
    if [[ $state == loaded ]]; then
        path=/etc/systemd/system/dphys-swapfile.service.d/99-emmc-protect.conf
        stage_file "$path"
        printf '[Unit]\n# emmc-protect: do not recreate disk swap\nConditionPathExists=!/\n' > "$WORK/stage$path"
        CHANGED+=("$path")
    fi
}

manage_swap() {
    if ((DRY_RUN)); then
        info '预演：不会启动 zram、执行 swapoff 或删除 swapfile'
    else
        if ! activate_zram; then
            warn 'zram 尚未就绪，保留所有磁盘 swap；按上述提示处理后重跑'
            return 1
        fi
        healthy_zram || { warn '未检测到无磁盘 writeback 的活动 zram，保留磁盘 swap'; return 1; }
    fi
    if ((REMOVE_DISK_SWAP)); then
        # A second transaction starts only after zram has been verified.
        # Dry-run can stage this plan without activating anything.
        CHANGED=(); JOURNAL_CHANGED=0; BACKUP=
        prepare_disk_swap_removal
        commit_changes
        if ((DRY_RUN)); then
            info '预演：磁盘 swap 仅在内存预检和逐项 swapoff 全部成功后才删除普通文件'
            return 0
        fi
        # No files are deleted during off; configuration rollback remains safe.
        if [[ -n $BACKUP ]]; then COMMITTING=1; fi
        python3 "$SCRIPT_DIR/lib/swap-protect.py" off "$WORK/disk-swaps.json"
        COMMITTING=0
        python3 "$SCRIPT_DIR/lib/swap-protect.py" delete "$WORK/disk-swaps.json"
        info '已停用快照中的磁盘 swap；符合检查条件的普通 swapfile 已删除，swap 分区未删除'
        warn 'swapfile 内容不备份；恢复旧 swap 配置前须重新创建对应 swapfile。请检查自定义启动脚本是否会重新启用 swap'
    fi
}

# Same-directory rename prevents readers from observing partially written files.
atomic_copy() {
    local source=$1 target=$2 tmp
    mkdir -p -- "$(dirname "$target")" || return 1
    tmp=$(mktemp "$(dirname "$target")/.emmc-protect.XXXXXX") || return 1
    if ! cp -p -- "$source" "$tmp" || ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi
}
restore_files() {
    local dir=$1 state path failed=0
    while IFS=$'\t' read -r state path; do
        case "$state" in
            present) atomic_copy "$dir/files$path" "$path" || failed=1 ;;
            absent) rm -f -- "$path" || failed=1 ;;
            *) return 1 ;;
        esac
    done < "$dir/manifest"
    return "$failed"
}
cleanup() {
    # WORK is a private mktemp directory in /run, never a user-supplied path.
    [[ -z $WORK ]] || rm -rf -- "$WORK"
}
on_failure() {
    local rc=$1
    trap - ERR INT TERM
    if ((COMMITTING)); then
        warn "操作未完成，正在恢复备份：$BACKUP"
        if restore_files "$BACKUP"; then
            systemctl daemon-reload || :
            if ((JOURNAL_CHANGED)); then systemctl restart systemd-journald.service || :; fi
            warn '原配置已恢复；请检查服务状态'
        else
            warn "自动恢复不完整，请人工恢复：$BACKUP"
        fi
    fi
    exit "$rc"
}
prepare_restore() {
    local state path count=0
    RESTORE_DIR=$(realpath -e -- "$RESTORE_DIR")
    [[ $RESTORE_DIR == "$BACKUP_ROOT"/* && -d $RESTORE_DIR ]] || die '仅接受本工具备份根目录内的备份'
    [[ -f $RESTORE_DIR/manifest && ! -L $RESTORE_DIR/manifest ]] || die '备份 manifest 无效'
    [[ $(stat -c %u "$RESTORE_DIR") == 0 && $(stat -c %a "$RESTORE_DIR") == 700 ]] || die '备份目录必须由 root 拥有且权限为 700'
    while IFS=$'\t' read -r state path; do
        allowed_path "$path" || die "备份含未授权路径：$path"
        [[ ! " ${CHANGED[*]} " == *" $path "* ]] || die "备份含重复路径：$path"
        check_target "$path"
        case "$state" in
            present)
                [[ -f $RESTORE_DIR/files$path && ! -L $RESTORE_DIR/files$path ]] || die "备份文件缺失：$path"
                stage_file "$path"
                cp -p -- "$RESTORE_DIR/files$path" "$WORK/stage$path" ;;
            absent) ;;
            *) die "备份状态无效：$state" ;;
        esac
        CHANGED+=("$path")
        count=$((count + 1))
    done < "$RESTORE_DIR/manifest"
    ((count > 0)) || die '备份为空'
    if [[ -f $WORK/stage$FSTAB ]]; then
        findmnt --verify --tab-file "$WORK/stage$FSTAB" || die '待恢复 fstab 无效（可能含已删除的 swapfile），请先恢复必要的文件或设备'
    fi
}
commit_changes() {
    local path pending=() seen='|'
    for path in "${CHANGED[@]}"; do
        [[ $seen != *"|$path|"* ]] || continue
        seen+="$path|"
        if [[ -f $WORK/stage$path ]]; then
            if [[ -f $path ]] && cmp -s -- "$path" "$WORK/stage$path"; then continue; fi
            info "将更新：$path"
        else
            [[ -e $path ]] || continue
            info "将移除本工具新增的配置：$path"
        fi
        pending+=("$path")
    done
    if ((${#pending[@]} == 0)); then info '配置已符合要求，无需写入'; return; fi
    if ((DRY_RUN)); then info '预演完成，未修改配置或服务'; return; fi
    mkdir -p -- "$BACKUP_ROOT"
    [[ ! -L $BACKUP_ROOT && $(stat -c %u "$BACKUP_ROOT") == 0 ]] || die '备份根目录必须是 root 拥有的真实目录'
    BACKUP=$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    : > "$BACKUP/manifest"
    for path in "${pending[@]}"; do
        if [[ -f $path ]]; then
            mkdir -p -- "$BACKUP/files$(dirname "$path")"
            cp -p -- "$path" "$BACKUP/files$path"
            printf 'present\t%s\n' "$path" >> "$BACKUP/manifest"
        else
            printf 'absent\t%s\n' "$path" >> "$BACKUP/manifest"
        fi
    done
    info "恢复点：$BACKUP"
    COMMITTING=1
    for path in "${pending[@]}"; do
        [[ $path != "$JOURNAL_CONF" ]] || JOURNAL_CHANGED=1
        if [[ -f $WORK/stage$path ]]; then
            if [[ ! -f $path && $MODE == apply ]]; then chmod 0644 "$WORK/stage$path"; fi
            atomic_copy "$WORK/stage$path" "$path"
        else
            rm -f -- "$path"
        fi
    done
    systemctl daemon-reload
    if ((JOURNAL_CHANGED)); then systemctl restart systemd-journald.service; fi
    COMMITTING=0
    info "完成。恢复命令：sudo bash protectemmc.sh --restore '$BACKUP'"
}

main() {
    parse_args "$@"
    if [[ $MODE == check ]]; then scan_system; return; fi
    [[ $(id -u) == 0 ]] || die '修改或预演配置需要 root'
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '仅支持以 systemd 启动的 Linux 主机'
    local command
    for command in systemctl findmnt flock mktemp cmp cp mv stat realpath; do
        command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
    done
    if ((REMOVE_DISK_SWAP)); then
        for command in systemd-escape swapoff; do
            command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
        done
    fi
    exec 9>/run/lock/emmc-protect.lock
    flock -n 9 || die '已有另一个 emmc-protect 操作正在运行'
    WORK=$(mktemp -d /run/emmc-protect.XXXXXX)
    trap cleanup EXIT
    trap 'on_failure $?' ERR
    trap 'on_failure 130' INT
    trap 'on_failure 143' TERM
    if [[ $MODE == apply ]]; then prepare_apply; else prepare_restore; fi
    commit_changes
    if [[ $MODE == apply ]] && ((ZRAM)); then manage_swap; fi
    if [[ $MODE == apply ]]; then
        warn '内存 journal 重启丢失，且可能因容量或速率限制丢弃日志；其他应用日志仍需检查'
        if ((NOATIME)) || [[ -n $TMP_SIZE ]]; then
            info 'fstab 变更在重启后生效；未在线挂载或遮蔽正在使用的文件'
        fi
        if ((DOCKER_LOG)); then
            info '未重启 Docker。请在维护窗口重启 daemon 并重建容器；已有容器日志驱动不会自动改变'
        fi
        if ((EDGE)); then
            info '极端减写入设置需重启生效；网络校时保留，timesyncd 不再保存跨重启时间基线'
        fi
    elif ((DRY_RUN == 0)); then
        info 'fstab / Docker 配置恢复需要重启系统 / Docker 才能完全生效'
    fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
