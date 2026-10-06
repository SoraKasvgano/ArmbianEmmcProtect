#!/usr/bin/env bash
# Sourced by protectemmc.sh. Changes are staged for its backup/restore transaction.
EDGE_TIMESYNC_CONF=/etc/systemd/system/systemd-timesyncd.service.d/99-emmc-protect.conf
EDGE_FSTRIM_CONF=/etc/systemd/system/fstrim.timer.d/99-emmc-protect.conf
EDGE_MANDB_CONF=/etc/systemd/system/man-db.service.d/99-emmc-protect.conf

edge_unit_available() {
    local state
    state=$(systemctl show --property=LoadState --value "$1" 2>/dev/null) || return 1
    [[ $state == loaded || $state == masked ]]
}

prepare_edge_settings() {
    local version
    if edge_unit_available systemd-timesyncd.service; then
        # RuntimeDirectory, StateDirectory and BindPaths require systemd >= 235.
        # Do not silently install an unsupported directive and claim RAM storage.
        version=$(systemctl --version) || version=
        version=${version#systemd }
        version=${version%%[!0-9]*}
        if [[ $version =~ ^[0-9]+$ ]] && ((10#$version >= 235)); then
            stage_file "$EDGE_TIMESYNC_CONF"
            cat > "$WORK/stage$EDGE_TIMESYNC_CONF" <<'EOF'
# Managed by emmc-protect --edge; takes effect at the next service start/reboot.
# Keep network time synchronization, but lose its saved clock on restart.
[Service]
# Avoid creating/chowning the persistent state directory on each service start.
StateDirectory=
# systemd creates this RAM directory with the service's User/Group ownership.
# Append to vendor RuntimeDirectory entries (e.g. systemd/timesync).
RuntimeDirectory=emmc-protect-timesync
RuntimeDirectoryMode=0755
# Bind only inside the service mount namespace, without covering live host files.
# BindPaths creates a writable mount even with ProtectSystem=strict.
BindPaths=/run/emmc-protect-timesync:/var/lib/systemd/timesync
EOF
            CHANGED+=("$EDGE_TIMESYNC_CONF")
        else
            warn 'systemd 版本无法确认或低于 235，跳过 timesyncd 内存状态配置'
        fi
    else
        info '未发现可加载的 systemd-timesyncd，跳过其内存状态配置'
    fi

    if edge_unit_available fstrim.timer; then
        stage_file "$EDGE_FSTRIM_CONF"
        cat > "$WORK/stage$EDGE_FSTRIM_CONF" <<'EOF'
# Managed by emmc-protect --edge; takes effect at next timer start/reboot.
# / always exists: this additional condition prevents activation of the timer.
# Keep vendor schedules and administrator enable/disable state for restoration.
[Unit]
ConditionPathExists=!/
EOF
        CHANGED+=("$EDGE_FSTRIM_CONF")
    else
        info '未发现可加载的 fstrim.timer，跳过定时 TRIM 配置'
    fi
    if edge_unit_available man-db.service; then
        stage_file "$EDGE_MANDB_CONF"
        cat > "$WORK/stage$EDGE_MANDB_CONF" <<'EOF'
# Managed by emmc-protect --edge; takes effect at next service start/reboot.
# Skip the manual-page index update without changing vendor ExecStart commands.
[Unit]
ConditionPathExists=!/
EOF
        CHANGED+=("$EDGE_MANDB_CONF")
    else
        info '未发现可加载的 man-db.service，跳过手册索引服务配置'
    fi
    info 'edge 配置在重启后生效；现有 timesyncd 和 fstrim.timer 运行状态尚未改变'
    warn '此配置只处理 timesyncd、fstrim.timer 和 man-db.service；fake-hwclock、chrony、NTP 及其他 cron 定时任务需另行检查'
    return 0
}
