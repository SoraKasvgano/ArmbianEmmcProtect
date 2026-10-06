#!/usr/bin/env bash
# Read-only, bounded inspection. Optional root is for isolated fixtures only.
# Never print configuration contents: application files can contain credentials.

write_audit_unit() {
    local unit=$1 state
    if command -v systemctl >/dev/null 2>&1; then
        state=$(systemctl show --property=LoadState,ActiveState,UnitFileState "$unit" 2>/dev/null) || state=
        if [[ $state == *LoadState=loaded* || $state == *LoadState=masked* ]]; then
            printf '%s\n' "  $unit"
            while IFS= read -r state; do
                case "$state" in
                    LoadState=*|ActiveState=*|UnitFileState=*) printf '    %s\n' "$state" ;;
                esac
            done <<< "$state"
        fi
    fi
    return 0
}

write_audit_config() {
    local root=$1 pattern=$2 advice=$3 file
    shift 3
    if command -v grep >/dev/null 2>&1; then
        for file in "$@"; do
            if [[ -f $file && -r $file ]] && grep -Eq -- "$pattern" "$file" 2>/dev/null; then
                info "配置线索：${file#"$root"}；$advice（仅为静态线索，需核验实际生效配置）"
            fi
        done
    fi
    return 0
}

scan_write_sources() {
    local root=${1:-} path file value pattern
    root=${root%/}
    info '其他写入源巡检：仅读取状态，不启动服务，不修改配置，不扫描目录大小'
    info '时间保存、崩溃转储、包更新及应用服务（已安装的 unit）'
    for path in fake-hwclock.service fake-hwclock-save.service fake-hwclock-save.timer \
        systemd-coredump.socket apport.service apt-daily.timer apt-daily-upgrade.timer \
        redis-server.service redis.service postgresql.service mariadb.service mysql.service \
        nginx.service docker.service; do
        write_audit_unit "$path"
    done

    write_audit_config "$root" '^[[:space:]]*[^#[:space:]].*(fake-hwclock|hwclock.*--systohc)' \
        '检查周期性时钟保存任务；服务停用不一定会停用 cron' \
        "$root"/etc/crontab "$root"/etc/cron.d/* "$root"/etc/cron.hourly/* \
        "$root"/etc/cron.daily/* "$root"/etc/cron.weekly/* "$root"/etc/cron.monthly/*
    # A command may start at column 1 (e.g. an hourly shell script).
    write_audit_config "$root" '^[[:space:]]*(/[^[:space:]]*/)?(fake-hwclock|hwclock)([[:space:]]|$)' \
        '检查脚本中的时钟保存行为' \
        "$root"/etc/cron.hourly/* "$root"/etc/cron.daily/* "$root"/etc/init.d/fake-hwclock

    path="$root/proc/sys/kernel/core_pattern"
    if [[ -r $path ]]; then
        pattern=
        IFS= read -r pattern < "$path" || :
        case "$pattern" in
            '|/bin/false') info 'core_pattern：已使用 emmc-protect 的丢弃处理器，不保存 core 文件' ;;
            '|'*) info 'core_pattern：交给用户态处理器；需检查处理器是否保存转储' ;;
            '') info 'core_pattern：空值；仍需结合进程 core 限额及 core_uses_pid 判断' ;;
            *) info 'core_pattern：文件转储模式；崩溃可能写盘，需结合进程 core 限额判断' ;;
        esac
    fi
    write_audit_config "$root" '^[[:space:]]*(Storage|ProcessSizeMax|ExternalSizeMax|JournalSizeMax)[[:space:]]*=' \
        '检查 core dump 的存储与处理限额' \
        "$root"/etc/systemd/coredump.conf "$root"/etc/systemd/coredump.conf.d/*.conf \
        "$root"/usr/lib/systemd/coredump.conf.d/*.conf "$root"/run/systemd/coredump.conf.d/*.conf
    write_audit_config "$root" '^[[:space:]]*(save|appendonly|appendfsync|logfile)[[:space:]]' \
        '检查 Redis RDB/AOF 和文件日志；持久化策略需按业务数据要求决定' \
        "$root"/etc/redis/*.conf
    write_audit_config "$root" '^[[:space:]]*(fsync|synchronous_commit|logging_collector|log_statement|log_directory|checkpoint_timeout)[[:space:]]*=' \
        '检查 PostgreSQL 日志及检查点频率；保留事务持久性' \
        "$root"/etc/postgresql/*/*/*.conf
    write_audit_config "$root" '^[[:space:]]*(general_log|slow_query_log|log_bin|log-bin|innodb_flush_log_at_trx_commit|sync_binlog)([[:space:]=]|$)' \
        '检查 MySQL/MariaDB 查询日志与持久化；不要盲目关闭事务刷新' \
        "$root"/etc/mysql/my.cnf "$root"/etc/mysql/conf.d/*.cnf "$root"/etc/mysql/mariadb.conf.d/*.cnf \
        "$root"/etc/mysql/mysql.conf.d/*.cnf
    write_audit_config "$root" '^[[:space:]]*(access_log|error_log|proxy_cache_path|fastcgi_cache_path)[[:space:]]' \
        '检查 Nginx 访问日志和缓存；可按业务关闭访问日志或限制缓存' \
        "$root"/etc/nginx/nginx.conf "$root"/etc/nginx/conf.d/* "$root"/etc/nginx/sites-enabled/*
    write_audit_config "$root" '"(log-driver|log-opts|data-root)"[[:space:]]*:' \
        '检查 Docker 日志驱动和数据目录；默认日志设置不会自动更新已有容器' \
        "$root"/etc/docker/daemon.json

    info '写入目录的实际承载挂载（含挂载选项；不统计文件大小）'
    if command -v findmnt >/dev/null 2>&1; then
        for path in /var/cache/apt /var/lib/docker /var/lib/redis /var/lib/mysql \
            /var/lib/postgresql /var/log /var/lib/systemd/coredump; do
            if [[ -d $root$path ]]; then
                info "$path"
                findmnt -T "$root$path" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || :
            fi
        done
    else
        info '缺少 findmnt，跳过目录挂载检查'
    fi
    info '当前脏页回写参数（仅读取；不自动延长回写周期）'
    for file in dirty_background_bytes dirty_background_ratio dirty_bytes dirty_ratio \
        dirty_expire_centisecs dirty_writeback_centisecs; do
        path="$root/proc/sys/vm/$file"
        if [[ -r $path ]]; then
            value=
            IFS= read -r value < "$path" || :
            [[ ! $value =~ ^[0-9]+$ ]] || printf '  vm.%s=%s\n' "$file" "$value"
        fi
    done
    warn '应用目录位于 tmpfs 时仍需检查磁盘 swap；数据库 fsync/事务持久化不会自动禁用。'
    info '缓存、数据库和容器数据是否迁入 RAM，需结合容量与重启后丢失数据的影响决定。'
    return 0
}
