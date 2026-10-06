#!/usr/bin/env bash
# Stage only: runtime sysctls and application data are never changed here.
CORE_CONF=/etc/systemd/coredump.conf.d/99-emmc-protect.conf
CORE_SYSCTL=/etc/sysctl.d/99-emmc-protect-coredump.conf
APT_CACHE_CONF=/etc/apt/apt.conf.d/99-emmc-protect-cache

prepare_background_settings() {
    stage_file "$CORE_CONF"
    cat > "$WORK/stage$CORE_CONF" <<'EOF'
# Managed by emmc-protect: do not store or process crash memory dumps.
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
    CHANGED+=("$CORE_CONF")
    # RLIMIT_CORE alone does not block a piped handler. This also covers other
    # crash handlers after reboot, without reloading unrelated host sysctls.
    [[ -x /bin/false ]] || die '缺少 /bin/false，无法安全配置 core dump 接收程序'
    stage_file "$CORE_SYSCTL"
    cat > "$WORK/stage$CORE_SYSCTL" <<'EOF'
# Managed by emmc-protect. No core payload is retained by the pipe handler.
kernel.core_pattern=|/bin/false
EOF
    CHANGED+=("$CORE_SYSCTL")
    info '禁用 core dump 存储和处理；内核设置在重启后生效，不删除已有崩溃文件'

    if command -v apt-config >/dev/null 2>&1; then
        stage_file "$APT_CACHE_CONF"
        cat > "$WORK/stage$APT_CACHE_CONF" <<'EOF'
// Managed by emmc-protect. Keep package lists and automatic security updates.
// Regenerate binary caches in memory; do not retain downloaded package archives.
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT::Keep-Downloaded-Packages "false";
Binary::apt::APT::Keep-Downloaded-Packages "false";
Binary::apt-get::APT::Keep-Downloaded-Packages "false";
EOF
        apt-config -c "$WORK/stage$APT_CACHE_CONF" dump >/dev/null || die 'APT 缓存配置验证失败，未修改配置'
        CHANGED+=("$APT_CACHE_CONF")
        info '减少 APT 二进制缓存及下载包保留；仍保留软件源列表、安全更新和安装所需写入'
    else
        info '未找到 apt-config，跳过 APT 缓存配置'
    fi
    return 0
}
