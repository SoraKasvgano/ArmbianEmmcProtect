#!/bin/bash
# Sourced by protectemmc.sh. Native distro setup only; never deletes swap.
ZRAM_BACKEND=unsupported
ZRAM_SIZE_MIB=0
ZRAM_DIETPI_MARKER='# emmc-protect: native DietPi zram'

zram_dietpi_config_owned() {
    local path=$1
    [[ ! -L $path ]] || return 1
    [[ ! -e $path ]] || { [[ -f $path ]] && grep -Fxq -- "$ZRAM_DIETPI_MARKER" "$path"; }
}

zram_stage_text() {
    local path=$1
    stage_file "$path"
    cat > "$WORK/stage$path"
    CHANGED+=("$path")
}

zram_stage_assignments() {
    local path=$1
    shift
    stage_file "$path"
    python3 - "$WORK/stage$path" "$@" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
assignments = dict(item.split('=', 1) for item in sys.argv[2:])
lines = p.read_text().splitlines() if p.exists() else []
pattern = re.compile(r'^\s*(?:export\s+)?(' + '|'.join(map(re.escape, assignments)) + r')\s*=')
lines = [line for line in lines if not pattern.match(line)]
lines.extend(key + '=' + value for key, value in assignments.items())
p.write_text('\n'.join(lines) + '\n')
PY
    CHANGED+=("$path")
}

zram_other_manager() {
    local service path
    for path in /etc/systemd/zram-generator.conf /usr/lib/systemd/zram-generator.conf \
        /etc/systemd/zram-generator.conf.d/*.conf /usr/lib/systemd/zram-generator.conf.d/*.conf; do
        if [[ -f $path ]]; then warn "发现其他 zram 管理配置：$path"; return 0; fi
    done
    for service in zramswap.service zram-config.service systemd-zram-setup@zram0.service; do
        if systemctl is-active --quiet "$service" 2>/dev/null || systemctl is-enabled --quiet "$service" 2>/dev/null; then
            warn "发现其他 zram 管理服务：$service"; return 0
        fi
    done
    return 1
}

zram_devices_unused() {
    local path size backing
    for path in /sys/block/zram*/disksize; do
        [[ -f $path ]] || continue
        read -r size < "$path"
        if [[ ! $size =~ ^[0-9]+$ || $size != 0 ]]; then
            warn "已分配的 zram 设备不予重置或接管：${path%/disksize}"
            return 1
        fi
        if [[ -f ${path%/disksize}/backing_dev ]]; then
            read -r backing < "${path%/disksize}/backing_dev"
            if [[ $backing != none ]]; then
                warn "zram 设备已配置磁盘写回，不予接管：${path%/disksize}"
                return 1
            fi
        fi
    done
}

prepare_zram_settings() {
    local memory path
    ZRAM_BACKEND=unsupported
    if healthy_zram; then ZRAM_BACKEND=existing; info '保留现有无磁盘写回的 zram swap'; return 0; fi
    command -v python3 >/dev/null || { warn '缺少 python3，保留磁盘 swap'; return 0; }
    command -v modprobe >/dev/null || { warn '缺少 modprobe，无法启用原生 zram'; return 0; }
    if [[ ! -d /sys/module/zram ]] && ! modprobe --dry-run zram >/dev/null 2>&1; then
        warn '内核未提供可加载的 zram 模块，保留磁盘 swap'; return 0
    fi
    memory=$(awk '$1 == "MemTotal:" {print $2; exit}' /proc/meminfo)
    [[ $memory =~ ^[0-9]+$ ]] || { warn '无法确定内存大小，保留磁盘 swap'; return 0; }
    ZRAM_SIZE_MIB=$((memory / 2048))
    ((ZRAM_SIZE_MIB <= 2048)) || ZRAM_SIZE_MIB=2048
    ((ZRAM_SIZE_MIB >= 16)) || { warn '可用 RAM 总量过小，不自动启用 zram'; return 0; }
    if zram_other_manager; then warn '请由现有管理器启用 zram，未接管配置'; return 0; fi

    if [[ -f /boot/dietpi.txt && -x /boot/dietpi/func/dietpi-set_swapfile ]]; then
        command -v udevadm >/dev/null || { warn 'DietPi 缺少 udevadm'; return 0; }
        zram_devices_unused || return 0
        # Retry our own staged setup after activation failure; preserve other owners.
        for path in /etc/modules-load.d/dietpi-zram-swap.conf \
            /etc/udev/rules.d/98-dietpi-zram-swap.rules \
            /etc/sysctl.d/98-dietpi-zram-swap.conf \
            /etc/systemd/system/systemd-udevd.service.d/dietpi-zram.conf; do
            if ! zram_dietpi_config_owned "$path"; then
                warn "DietPi 已存在 zram 配置但没有健康的活动 zram，请先修复：$path"
                return 0
            fi
        done
        zram_stage_text /etc/modules-load.d/dietpi-zram-swap.conf <<'EOF'
# emmc-protect: native DietPi zram
zram
EOF
        zram_stage_text /etc/udev/rules.d/98-dietpi-zram-swap.rules <<EOF
# emmc-protect: native DietPi zram
SUBSYSTEM=="block", KERNEL=="zram0", ACTION=="add", ATTR{disksize}=="0", ATTR{disksize}="${ZRAM_SIZE_MIB}M", RUN+="/bin/chmod 0600 /dev/zram0", RUN+="/sbin/mkswap /dev/zram0", RUN+="/sbin/swapon /dev/zram0"
EOF
        zram_stage_text /etc/sysctl.d/98-dietpi-zram-swap.conf <<'EOF'
# emmc-protect: native DietPi zram
vm.swappiness=50
EOF
        zram_stage_text /etc/systemd/system/systemd-udevd.service.d/dietpi-zram.conf <<'EOF'
# emmc-protect: native DietPi zram
[Service]
SystemCallFilter=@swap
EOF
        zram_stage_assignments /boot/dietpi.txt "AUTO_SETUP_SWAPFILE_SIZE=$ZRAM_SIZE_MIB" AUTO_SETUP_SWAPFILE_LOCATION=zram
        ZRAM_BACKEND=dietpi
    elif [[ -f /etc/armbian-release && -x /usr/lib/armbian/armbian-zram-config ]] && \
        [[ $(systemctl show -p LoadState --value armbian-zram-config.service 2>/dev/null) == loaded ]]; then
        if systemctl is-active --quiet armbian-zram-config.service; then
            ZRAM_BACKEND=armbian-pending
        else
            zram_devices_unused || return 0
            ZRAM_BACKEND=armbian
        fi
        # The native service accepts percentage sizing, not a MiB cap.
        local percentage=$((ZRAM_SIZE_MIB * 102400 / memory))
        ((percentage >= 1)) || { warn '内存过大，原生百分比配置无法满足 2 GiB 上限'; ZRAM_BACKEND=unsupported; return 0; }
        zram_stage_assignments /etc/default/armbian-zram-config ENABLED=true SWAP=true \
            "ZRAM_PERCENTAGE=$percentage" MEM_LIMIT_PERCENTAGE=50 "ZRAM_BACKING_DEV=''"
        bash -n "$WORK/stage/etc/default/armbian-zram-config"
        if [[ $ZRAM_BACKEND == armbian-pending ]]; then
            warn 'Armbian zram 服务已运行但没有健康 zram swap；只更新下次启动设置，不重启 RAM 日志挂载'
        fi
    else
        warn '未识别受支持的 Armbian / DietPi 原生 zram 管理方式，保留磁盘 swap'
    fi
}

activate_zram() {
    if ((${DRY_RUN:-0})); then info "预演：zram backend=$ZRAM_BACKEND，不启动服务"; return 0; fi
    case "$ZRAM_BACKEND" in
        existing) healthy_zram || { warn '现有 zram 状态已变化，保留磁盘 swap'; return 1; } ;;
        armbian-pending) warn '需重启使 Armbian zram swap 生效；本次保留磁盘 swap'; return 1 ;;
        armbian)
            zram_devices_unused || return 1
            warn '将启用 Armbian 原生 zram 服务；enable 创建的启动链接不由普通配置恢复自动撤销'
            systemctl enable armbian-zram-config.service && systemctl start armbian-zram-config.service || {
                warn 'Armbian 原生 zram 启动失败，保留磁盘 swap'; return 1;
            }
            ;;
        dietpi)
            zram_devices_unused || return 1
            # The native Bookworm drop-in must affect the running udev daemon.
            systemctl daemon-reload && systemctl restart systemd-udevd.service && \
                udevadm control --reload-rules && modprobe zram && \
                udevadm settle --timeout=30 || { warn 'DietPi 原生 zram 初始化失败，保留磁盘 swap'; return 1; }
            if ! healthy_zram; then
                [[ -e /sys/block/zram0/disksize ]] || { warn '没有可用的 zram0，保留磁盘 swap'; return 1; }
                udevadm trigger --action=add /sys/block/zram0 && udevadm settle --timeout=30 || {
                    warn 'DietPi zram udev 规则执行失败，保留磁盘 swap'; return 1;
                }
            fi
            ;;
        *) warn '没有可用的原生 zram 后端，保留磁盘 swap'; return 1 ;;
    esac
    healthy_zram || { warn '未验证到健康的活动 zram swap，保留磁盘 swap'; return 1; }
    info '已验证无磁盘写回的活动 zram swap'
}
