#!/bin/bash
# Armbian U盘/闪存盘写入保护自动巡检&加固脚本
# 修订：保留logrotate做内存日志轮转；Docker日志转发journald
# 新增：man-db拦截 + systemd-timesync /var/lib/systemd/timesync tmpfs挂载
# 新增：ramlog syncToDisk/syncFromDisk空函数注入
# 适用：USB介质启动，减少闪存写入，延长寿命
# 说明：日志全部在内存，logrotate仅对内存中日志做清理轮转，不写U盘
# 警告：重启日志丢失；commit拉长，意外断电有文件系统损坏风险
set -euo pipefail
if [ "$(id -u)" -ne 0 ];then
    echo "❌ 必须使用root运行！"
    exit 1
fi

# 全局变量
SYS_DEV="sda"
FSTAB_FILE="/etc/fstab"
JOURNALD_CONF="/etc/systemd/journald.conf"
RAMLOG_CRON="/etc/cron.daily/armbian-ram-logging"
LOGROTATE_CRON="/etc/cron.daily/logrotate"
FSTRIM_SERVICE="fstrim.timer"
LOGROTATE_MAIN="/etc/logrotate.conf"
DOCKER_DAEMON="/etc/docker/daemon.json"
TIMESYNC_MOUNT="/etc/systemd/system/var-lib-systemd-timesync.mount"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info(){ echo -e "${GREEN}[INFO] $*${NC}"; }
warn(){ echo -e "${YELLOW}[WARN] $*${NC}"; }
err(){ echo -e "${RED}[ERROR] $*${NC}"; }

banner(){
cat <<EOF
====================================================
     Armbian USB闪存盘 寿命保护巡检&加固脚本
     介质: /dev/${SYS_DEV} 系统U盘
     ✅修订：保留logrotate内存轮转、Docker→journald
     ✅新增：ramlog sync空函数、man-db拦截、timesync tmpfs
====================================================
EOF
}

scan_system(){
    echo -e "\n===== 【1.磁盘TRIM支持检测】 ====="
    echo "lsblk -D 检测 ${SYS_DEV}:"
    lsblk -D | grep -E "${SYS_DEV}|NAME"
    DISC_GRAN=$(cat /sys/block/${SYS_DEV}/queue/discard_granularity 2>/dev/null || echo 0)
    if [ "$DISC_GRAN" = "0" ];then
        warn ">> 该U盘不支持TRIM，fstrim无意义，建议关闭fstrim.timer"
    else
        info ">> 设备上报支持TRIM，本方案依然关闭自动定时trim"
    fi

    echo -e "\n===== 【2.根分区挂载参数检查】 ====="
    mount | grep ' / '
    if mount | grep ' / ' | grep -q discard;then
        err ">> 根分区挂载带 discard 参数！危险！"
    else
        info ">> 根分区无 discard 参数 ✔"
    fi
    if mount | grep ' / ' | grep -q noatime;then
        info ">> 已启用 noatime ✔"
    else
        warn ">> 根分区未启用 noatime"
    fi

    echo -e "\n===== 【3.fstab内容检查】 ====="
    grep -E 'ext4|vfat|tmpfs' ${FSTAB_FILE}
    if grep -q discard ${FSTAB_FILE};then
        err ">> fstab里面存在 discard 参数！"
    else
        info ">> fstab 无 discard ✔"
    fi

    echo -e "\n===== 【4. journald日志模式】 ====="
    JOURNAL_MODE=$(grep '^Storage=' ${JOURNALD_CONF} | cut -d= -f2 || echo unset)
    echo "Storage=$JOURNAL_MODE"
    if [ "$JOURNAL_MODE" = "volatile" ];then
        info ">> journald volatile(纯内存日志) ✔"
    else
        warn ">> journald 日志会落盘，需要修改为 volatile"
    fi

    echo -e "\n===== 【5. cron定时任务检查】 ====="
    if [ -f "${RAMLOG_CRON}" ];then
        warn ">> armbian-ram-logging cron脚本存在"
    else
        info ">> armbian-ram-logging cron已改名禁用 ✔"
    fi
    if [ -f "${LOGROTATE_CRON}" ];then
        info ">> logrotate cron脚本存在，保留用于内存日志轮转 ✔"
    else
        warn ">> logrotate cron脚本不存在，无法自动轮转内存日志"
    fi

    echo -e "\n===== 【6. fstrim.timer状态】 ====="
    FSTRIM_EN=$(systemctl is-enabled ${FSTRIM_SERVICE})
    echo "$FSTRIM_SERVICE: $FSTRIM_EN"
    if [ "$FSTRIM_EN" = "enabled" ];then
        warn ">> fstrim.timer 启用中，U盘不支持trim，建议关闭"
    else
        info ">> fstrim.timer 已经disabled ✔"
    fi

    echo -e "\n===== 【7. tmpfs挂载检查】 ====="
    mount | grep -E '/tmp|/var/tmp'
    if mount | grep -q '/var/tmp';then
        info ">> /var/tmp tmpfs已挂载 ✔"
    else
        warn ">> /var/tmp 未挂载tmpfs，临时文件会写入U盘"
    fi

    echo -e "\n===== 【8. Swap检查】 ====="
    swapon --show
    if swapon --show | grep -v zram | grep -q /dev;then
        err ">> 存在磁盘swap！会持续写U盘，必须删除！"
    else
        info ">> 仅zram swap，无磁盘swap ✔"
    fi

    echo -e "\n===== 【9. Docker日志驱动检测】 ====="
    if command -v docker &>/dev/null;then
        DOCKER_LOGDRV=$(docker info 2>/dev/null | grep "Logging Driver" | awk '{print $3}')
        echo "Docker Logging Driver: $DOCKER_LOGDRV"
        if [ "$DOCKER_LOGDRV" = "journald" ];then
            info ">> Docker日志驱动journald ✔"
        else
            warn ">> Docker当前不是journald，容器日志会写入U盘json文件"
        fi
    else
        info ">> 系统未安装docker，跳过docker日志检测"
    fi

    echo -e "\n===== 【10. man-db定时任务检查】 ====="
    MANDB_TIMER=$(systemctl is-enabled man-db.timer)
    echo "man-db.timer status: $MANDB_TIMER"
    if [ "$MANDB_TIMER" = "disabled" ];then
        info ">> man-db.timer已禁用 ✔"
    else
        warn ">> man-db.timer启用，会定时重建man数据库写入U盘"
    fi

    echo -e "\n===== 【11. systemd-timesync tmpfs挂载检查】 ====="
    if mount | grep -q "/var/lib/systemd/timesync";then
        info ">> /var/lib/systemd/timesync tmpfs已挂载 ✔"
    else
        warn ">> /var/lib/systemd/timesync 未挂载tmpfs，时钟状态文件写入U盘"
    fi

    echo -e "\n===== 【12. 当前U盘累计写入统计】 ====="
    awk '/'${SYS_DEV}' /{print ">> 累计写入扇区:"$7"  ("$7" * 512Byte)"}' /proc/diskstats

    echo -e "\n===== 【巡检完成，请审阅上面风险项】 ====="
}

apply_protect(){
    info "开始执行保护策略......"
    #1.关闭fstrim.timer
    systemctl disable --now ${FSTRIM_SERVICE}
    info "✅ fstrim.timer 已关闭"

    #2. journald 设置 volatile
    sed -i 's/^#Storage=.*/Storage=volatile/' ${JOURNALD_CONF}
    sed -i 's/^Storage=.*/Storage=volatile/' ${JOURNALD_CONF}
    systemctl restart systemd-journald
    info "✅ journald 设置 volatile 内存日志"

    #3. ramlog cron 改名禁用；【保留logrotate cron！不改名】
    if [ -f "${RAMLOG_CRON}" ];then
        mv ${RAMLOG_CRON} ${RAMLOG_CRON}.disabled
        info "✅ armbian-ram-logging cron 改名禁用"
    fi
    info "✅ logrotate cron保留，用于内存日志轮转"

    # 注入空syncToDisk syncFromDisk函数，禁用ramlog磁盘同步，时间标记仅内存
    if ! grep -q "syncToDisk () { return 0;" /etc/default/armbian-ramlog;then
        cat >> /etc/default/armbian-ramlog <<'EOF'
# flashprotect: disable ramlog log sync to disk
syncToDisk () { return 0; }
syncFromDisk () { return 0; }
EOF
        info "✅ 注入 syncToDisk / syncFromDisk 空函数，彻底禁止ramlog落盘；同步时间仅保存在内存"
    fi

    # 移除旧的logrotate.service override（如果存在），允许logrotate正常运行
    if [ -d /etc/systemd/system/logrotate.service.d ];then
        rm -rf /etc/systemd/system/logrotate.service.d
        systemctl daemon-reload
        info "✅ 删除logrotate.service旧拦截override，允许logrotate执行"
    fi

    #4. logrotate全局加固：禁止创建持久文件，仅操作内存文件，不写U盘
    # 备份原配置
    cp ${LOGROTATE_MAIN} ${LOGROTATE_MAIN}.bak
    # 追加全局规则：不创建新持久文件；轮转文件不落地磁盘（内存内操作）
    if ! grep -q "#flashprotect_no_create" ${LOGROTATE_MAIN};then
        cat >> ${LOGROTATE_MAIN} <<'EOF'
#flashprotect_no_create -- added by usb flash protect script
nocreate
# 可选：内存日志可以开启压缩（在内存中压缩），按需启用
#compress
#delaycompress
EOF
    fi
    info "✅ logrotate.conf 添加nocreate，禁止轮转时创建持久文件，仅操作内存日志"

    #5. 添加/var/tmp 到fstab（不存在才追加）
    if ! grep -q '/var/tmp' ${FSTAB_FILE};then
        echo "tmpfs /var/tmp tmpfs defaults,nosuid,size=100M 0 0" >> ${FSTAB_FILE}
        info "✅ fstab新增 /var/tmp tmpfs"
    fi
    # 挂载
    mount -a
    info "✅ mount -a 测试挂载"

    #6. armbian-ram-logging.timer 兜底拦截
    mkdir -p /etc/systemd/system/armbian-ram-logging.timer.d
    cat > /etc/systemd/system/armbian-ram-logging.timer.d/override.conf <<EOF
[Service]
ExecStart=/bin/sh -c "exit 0"
EOF
    systemctl daemon-reload
    info "✅ armbian-ram-logging.timer override兜底"

    #7. Docker日志驱动修改为journald（如果docker已安装）
    if command -v docker &>/dev/null;then
        info ">> 检测到Docker，配置daemon.json，日志驱动journald"
        mkdir -p /etc/docker
        cat > ${DOCKER_DAEMON} <<EOF
{
  "log-driver": "journald",
  "log-opts": {
    "tag": "{{.Name}}"
  }
}
EOF
        systemctl restart docker
        info "✅ Docker 日志切换journald，不再生成磁盘json日志"
    fi

    # ========== 新增1：拦截 man-db 定时更新数据库，避免写U盘 ==========
    info "✅ 配置man-db.timer override，禁止man数据库定时更新写入U盘"
    mkdir -p /etc/systemd/system/man-db.timer.d
    cat > /etc/systemd/system/man-db.timer.d/override.conf <<EOF
[Timer]
Persistent=false
OnCalendar=
EOF
    mkdir -p /etc/systemd/system/man-db.service.d
    cat > /etc/systemd/system/man-db.service.d/override.conf <<EOF
[Service]
ExecStart=/bin/sh -c "exit 0"
EOF
    systemctl daemon-reload
    systemctl stop man-db.timer
    systemctl disable --now man-db.timer

    # ========== 新增2：systemd-timesyncd 状态目录挂载tmpfs 8M ==========
    info "✅ 创建 var-lib-systemd-timesync.mount，/var/lib/systemd/timesync 使用tmpfs内存挂载"
    mkdir -p /etc/systemd/system
    cat > ${TIMESYNC_MOUNT} <<'EOF'
[Unit]
Description=tmpfs mount for systemd-timesync state
Before=systemd-timesyncd.service

[Mount]
What=tmpfs
Where=/var/lib/systemd/timesync
Type=tmpfs
Options=size=8M,mode=0700

[Install]
WantedBy=multi-user.target
EOF
    # 启用挂载单元
    systemctl daemon-reload
    systemctl enable --now var-lib-systemd-timesync.mount
    info "✅ timesyncd状态目录已挂载到内存tmpfs"

    info -e "\n===== 全部加固完成！ ====="
    warn "⚠️ 重要提醒："
    warn "1. 所有日志在内存，logrotate仅在内存内轮转清理，重启日志全部丢失"
    warn "2. commit=600 拉长元数据刷盘，意外断电可能损坏文件系统"
    warn "3. 业务数据库/网站数据，请放在第二块硬盘（sdb），不要放在sda系统U盘！"
    warn "4. 建议新开终端运行写入监控脚本持续观察："
    cat <<'EOF'
#!/bin/bash
PREV=$(awk '/sda /{print $7}' /proc/diskstats)
while true;do
    CUR=$(awk '/sda /{print $7}' /proc/diskstats)
    DELTA=$((CUR - PREV))
    echo "[$(date +%H:%M:%S)] U盘sda 新增写入扇区：$DELTA｜累计写入：$CUR"
    PREV=$CUR
    sleep 10
done
EOF
}

# 主流程
banner
scan_system

read -p $'\n是否确认执行闪存保护加固？[y/N] ' ans
case "$ans" in
y|Y)
    apply_protect
    ;;
*)
    info "用户取消，脚本退出，没有修改系统"
    exit 0
    ;;
esac
