# ArmbianEmmcProtect

用于从 eMMC、U 盘或 SD 卡启动的 Armbian、DietPi 等 systemd Linux，减少日志、访问时间和后台任务造成的写入。默认只巡检；适合边缘设备的激进配置通过 `--edge` 明确启用。请保留整个仓库目录，脚本需要 `lib/` 中的辅助文件。

```bash
# 只读巡检，不要求 root
bash protectemmc.sh --check

# 推荐先预演极端边缘设备配置
sudo bash protectemmc.sh --apply --edge --dry-run

# 执行，随后在维护窗口重启使挂载和服务配置生效
sudo bash protectemmc.sh --apply --edge

# 可选：/tmp 内存化，并修改 Docker 的默认日志驱动
sudo bash protectemmc.sh --apply --edge --tmp-size 64M --docker-journald

# 启用/复用 zram，再停用磁盘 swap，删除确认安全的普通 swapfile
sudo bash protectemmc.sh --apply --edge --remove-disk-swap --dry-run
sudo bash protectemmc.sh --apply --edge --remove-disk-swap
```

执行和预演要求 root、Bash、systemd、util-linux（`findmnt`、`flock`）、GNU coreutils。fstab 修改和 Armbian ramlog 补丁需要 Python 3；Docker 配置需要支持 `dockerd --validate` 的 Docker 版本。预演仅创建 `/run` 下的临时文件和锁，不修改持久配置或重启服务。

## 配置范围

| 设置 | `--apply` | 增加 `--edge` |
| --- | --- | --- |
| journald | 内存日志，32 MiB 限额、单文件 4 MiB、保留 16 MiB 空间；30 秒 1000 条速率限制；关闭向 syslog 转发 | 相同 |
| 根分区访问时间 | 保持现状，可单独使用 `--noatime` | fstab 根条目加入 `noatime`，保留其他选项 |
| `fstrim.timer` | 保持现状 | 阻止定时任务启动，重启生效 |
| man-db 自动更新 | 保持现状 | 跳过 service 和已有 daily/weekly cron 脚本；手动 mandb 仍可用 |
| systemd-timesyncd | 保持时间持久化 | 时间状态使用内存，继续网络校时，重启生效 |
| fake-hwclock | 保持现状 | 已知脚本的 save 入口提前退出，覆盖定时和关机保存，保留 load |
| core dump | 保持现状 | 禁止 systemd-coredump 存储和处理；重启后内核不再交给原崩溃收集器 |
| APT 缓存 | 保持现状 | 不生成持久二进制索引缓存、不保留下载包；保留软件源列表和自动更新 |
| Armbian ramlog | 保持现状 | 在识别的同步入口加入 `return 0`，保留内存日志挂载 |
| `/tmp` | 仅 `--tmp-size` 开启 | 相同 |
| Docker | 仅 `--docker-journald` 开启 | 相同 |

不支持 TRIM 的 U 盘通常拒绝或跳过 discard，并非每次调用都会产生闪存擦写。`--edge` 停止无用的定时活动，也会停止支持 TRIM 设备的定时清理；若需要保留定期 TRIM，请使用基础配置。手动调用 fstrim 不受影响。

`noatime` 减少访问时间更新，但不能消除文件内容、修改时间或文件系统元数据写入。无法明确识别 fstab 根条目、重复条目或不支持的文件系统时，整个配置准备阶段失败，不猜测根设备，不在线执行 `mount -a`。

## 日志及发行版差异

内存 journal 在重启后丢失，容量和速率限制也会丢弃日志。仍保留错误诊断能力，不直接禁用 journald 或 logrotate。其他优先级更高的 journald drop-in 可能覆盖设置，巡检会列出相关配置；可用 `systemd-analyze cat-config systemd/journald.conf` 检查合并结果。

原脚本把 `syncToDisk`、`syncFromDisk` 的空函数放到 `/etc/default/armbian-ramlog`，当前 Armbian 上游随后重新定义这两个函数，会覆盖空函数。新版在已识别的程序入口加入带标记的提前返回，并检查 Shell 语法；未知结构拒绝修改。此补丁不会停用 ramlog 的内存挂载服务。发行版升级可能覆盖补丁，升级后请重新预演并执行。

man-db 的自动更新通过 service 条件和 cron 入口的 `exit 0` 阻止，不写无效的 `ExecStart` 覆盖。软件包升级也可能覆盖 cron 补丁；手动运行 mandb、安装软件包触发的索引更新不在此范围内。

DietPi 的 RAM 日志实现不同，本工具不会伪造 Armbian 配置。请通过 `dietpi-ramlog` 使用不将日志保存到磁盘的模式，并检查本机实际版本和定时任务。rsyslog、syslog-ng、应用自己的文件日志、journal namespace、容器数据、数据库和 logrotate 状态仍可能写盘；本工具不承诺全系统零写入。现有磁盘日志不会被删除。

Docker 配置按 JSON 合并，保留存储、网络等其他配置；切换驱动时替换不兼容的旧 `log-opts`。脚本验证配置但不自动重启 Docker。请在维护窗口重启 daemon，再重建已有容器；容器级 `logging` 配置也需要同步调整。仅重启现有容器不会改变日志驱动。

## 内存与时间

`/tmp` 的大小是上限，并非预先分配；请给业务、软件安装和解压预留内存。已有 tmpfs 挂载选项会保留，只调整大小；其他文件系统的 `/tmp` 不会被覆盖。`/var/tmp` 保留跨重启语义。存在磁盘 swap 时，tmpfs 仍可能经 swap 写盘。基础模式只报告 swap；只有显式指定 `--remove-disk-swap` 才会尝试迁移和删除。

极端模式将 timesyncd 状态放入内存，并在已识别的 fake-hwclock 脚本 save 入口加入 `exit 0`，覆盖无参数保存、定时保存及关机保存；保留 load 和已有时间文件，不禁用网络校时。没有 RTC 的设备冷启动时间可能回退，网络校时成功后恢复。未知 fake-hwclock 脚本结构拒绝修改，发行版升级后需重新预演核验。chrony、ntpd 有各自的持久化机制，仍需按实际配置检查。

## 崩溃转储、缓存与应用写入

`--edge` 配置 `Storage=none` 和 `ProcessSizeMax=0`，使 systemd-coredump 不存储或处理进程内存转储；再用独立 sysctl 配置将 `kernel.core_pattern` 设为 `|/bin/false`，重启后也不再调用其他崩溃收集器。不会在线加载全系统 sysctl 或删除现有转储。普通 journal 错误日志仍保留，但无法依赖新的 core 文件调试崩溃。恢复 sysctl 配置同样需要重启；其他优先级更高的配置可能覆盖设置，巡检会报告当前 core handler。

检测到 APT 时，独立配置关闭持久 `pkgcache/srcpkgcache` 并关闭 apt/apt-get 的下载包保留。不会清空缓存目录，不将软件包目录挂到 tmpfs，也不禁用安全更新。下载、解压、软件源列表、dpkg 数据库和安装日志仍有必要写入。缓存不保留可能增加后续重复下载及索引解析开销。

`--check` 增加只读写入源巡检：fake-hwclock、core handler、APT 更新定时器、Docker/Redis/MariaDB/PostgreSQL/nginx 等服务、常见缓存与数据目录实际挂载，以及内核脏页参数。只显示配置路径和建议，不输出配置中的密码，不递归扫描数据库和缓存目录。

应用数据需按业务语义处理：可丢失的应用缓存可单独放入受容量限制的 tmpfs；数据库可考虑应用端批量提交、减少无用查询日志、迁移到独立存储。脚本不自动关闭数据库 fsync、Redis 持久化或统一改大脏页回写周期，避免把必要的业务数据当作缓存丢弃。

## zram 与磁盘 swap 迁移

`--zram` 单独启用/复用 zram，不删除磁盘 swap。检测不仅看服务状态，还检查实际活动的 zram swap 及 `backing_dev`，防止 zram 的 writeback 继续写介质。新配置默认使用约一半物理内存作为逻辑容量，上限 2 GiB；这不是预分配内存，也不保证实际压缩比。

- Armbian：使用 `/etc/default/armbian-zram-config` 和原生 `armbian-zram-config.service`。如果服务已运行但未提供 zram swap，仅准备下次启动配置，要求重启后重跑，避免重启服务影响它同时管理的日志和临时目录。
- DietPi：复用原生 modules-load、udev 和 `dietpi.txt` 配置，先启用 zram。不会直接调用 `dietpi-set_swapfile 1 zram`，因为该命令先关闭并删除原 swap，还会调整 `/tmp`。运行时需要重启 udev 服务以使其 swap 系统调用设置生效。
- 已有 zram 管理器、非空设备、未知配置或不支持的内核会被保留，不会强制 reset 或与其他管理器争抢。已有健康 zram 保持原管理方式；其重启后的启用由原管理器负责。

`--remove-disk-swap` 隐含 `--zram`。只有 zram 已实际可用，才进入独立的磁盘 swap 配置事务：注释 fstab 中的磁盘 swap 条目、阻止已发现的磁盘 `.swap` unit 和 dphys-swapfile 服务自动启用；再逐个 `swapoff`。要求 `MemAvailable` 至少容纳当前磁盘 swap 已用量，加上 `64 MiB` 与物理内存 `10%` 两者较大的余量。预检仍不能代替业务负载管理，迁移期间应避免大量新分配内存。

只有全部停用成功后才删除原快照中的普通 swapfile，并复核设备号、inode、链接数和活动状态；绝不删除 swap 分区或块设备，不遍历磁盘猜测“疑似 swap 文件”。停用阶段失败会尝试回滚这一阶段的配置，已停用的 swap 不会自动重新启用。删除阶段失败则保留已经禁用的配置并报告错误。自定义 cron、rc.local 和第三方 swap 管理器仍需核查。

swapfile 内容不会复制到备份。恢复旧配置前需要自行重新创建删除的 swapfile；脚本验证待恢复 fstab 并拒绝无效挂载。zram 启用属于运行状态变更，配置恢复不会自动 reset zram、恢复已删除文件或撤销 Armbian `systemctl enable` 产生的链接。

## 备份与恢复

所有配置先准备和验证，再写入。每次实际变更备份到 `/var/backups/emmc-protect/时间戳.随机串`，重复执行相同配置不生成新备份、不重启服务。文件以同目录原子重命名替换；遇到可捕获的提交错误或信号会尝试回滚。断电或 `SIGKILL` 无法保证整批事务回滚，可用已输出的备份恢复。

```bash
sudo bash protectemmc.sh --restore /var/backups/emmc-protect/实际备份目录 --dry-run
sudo bash protectemmc.sh --restore /var/backups/emmc-protect/实际备份目录
```

恢复前会再次备份当前配置。按从新到旧的顺序恢复；恢复会覆盖备份之后对相同文件的手动修改。journald 配置立即重载，fstab、timesyncd、timer 和 Docker 的恢复还需重启相应服务或系统。旧版脚本已做的 `nocreate`、ramlog 配置注入、timesync tmpfs、timer override 等没有可信原件，本版不会猜测并删除，请按原备份逐项清理，特别是旧 timesync 挂载单元。

## 验证

```bash
bash -n protectemmc.sh
bash tests/test_protectemmc.sh
bash tests/test_edge_settings.sh
bash tests/test_zram_settings.sh
bash tests/test_background_settings.sh
bash tests/test_fake_clock_settings.sh
bash tests/test_write_audit.sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

回归测试在隔离目录模拟配置和服务调用，不修改宿主系统。真实 Armbian/DietPi 的启动、挂载、systemd 和容器行为仍需在目标设备验证。
