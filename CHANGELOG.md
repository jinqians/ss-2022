# 更新日志

## v5.0（2026-10-07）

ss-2022.sh 2.0 → 3.0，block-mainland.sh 1.1 → 2.0；menu.sh、shadowtls.sh 换成 jinqians/snell 的同名脚本（4.6）

### 跟进 shadowsocks-rust 1.22 – 1.25
- **单端口多用户**（1.25 的 Extensible Identity Header）：几个人共用一个端口、各用各的密钥，可以单独删人、换密钥。只支持 `2022-blake3-aes-128-gcm` / `aes-256-gcm`。ssserver 只在 `servers` 数组里认用户，所以 `config.json` 仍保持单服务器格式（PSM、ShadowTLS 与大陆屏蔽都按它读端口），有用户时另外生成 `config-eih.json` 给主服务跑。
- **出口代理**（1.25）：服务器的出站 TCP 经 SOCKS5 / HTTP / HTTPS 代理（可多跳）；设置时从服务器经代理试连并显示出口 IP。UDP 不经代理。
- **日志**（1.24）：级别；另写到 `/var/log/ss-rust/`，按天分文件、保留 7 个。
- **入站 UDP 分片**（1.25 起默认不分片）：在「修改配置」里可以打开。
- 加密方式菜单去掉了官方发布版不支持的 `2022-blake3-chacha8-poly1305`（选了它服务就起不来）和不安全的流加密；已经在用的配置照常能跑。

### 安装
- 装官方发布的静态链接版（musl），不再依赖系统的 glibc；下载到临时目录，核对官方的 SHA-256 后才换上（以前下到当前目录、不校验，还关了证书检查）。
- armv7 以前总是装成软浮点的 `arm-gnueabi` 版（检测写成了在 /proc/cpuinfo 里找 `gnueabihf`，永远找不到）。现在按 CPU 选 armv7 / arm / aarch64 / x86_64 / i686 / riscv64 / loongarch64。
- 不再把时区改成 Asia/Shanghai（2022 系列校验的是时间戳，与时区无关；开时间同步就够了）。
- **Alpine**（OpenRC）：用 `sh` 运行时脚本自己装 bash；服务、日志、屏蔽中国大陆都支持 OpenRC。
- 管理命令 `ssrust` 每次运行都取最新的脚本，取不到时用本机保存的那份；旧版的 `ssrust`（链接）打开菜单时自动换成新的。
- 配置里不再写 `"user": "nobody"`：ssserver 在配置文件里不认这个键，从来没有降过权限。

### 菜单与结构
- 菜单换成与 PSM、snell 一致的样子：顶上是状态栏（服务、IP、版本、加密方式、端口、用户、ShadowTLS、出口、大陆屏蔽），下面两列的选项，0 退出。
- 代码拆成模块：`src/ss-2022.sh`、`src/block-mainland.sh` 与 `src/lib/`，由 `tools/build.sh` 合成根目录的单个文件（raw 地址不变）。与 snell 共用的系统识别、装包、防火墙、公网地址，以及 `shadowtls.sh`、`menu.sh`，由 `tools/sync-shared.sh` 从 snell 仓库拷过来，两边是同一份。
- 改配置只改动那一项，别的键原样保留；改主端口时防火墙、ShadowTLS 的后端、大陆屏蔽的规则跟着改。
- 卸载时问是否一起删 ShadowTLS（shadowtls-ss）与大陆屏蔽，端口都关掉。

### 屏蔽中国大陆（block-mainland.sh 2.0）
- IP 库直接下纯文本的 CIDR 列表（IPv4 与旧版同一份数据），不再需要 Python、pip、maxminddb 与编译工具；新增 IPv6（china-operator-ip）。
- 用 `ipset restore` 一次导入（以前每行起一个 `xargs`，七千多行要很久）。
- 开机恢复支持 OpenRC；定时更新用 systemd 定时器或 Alpine 的 `/etc/periodic`，不再依赖 cron 软件包。
- 「更新 IP 库」在屏蔽关着时只更新文件，不会替你打开。
- 旧版存进 `/etc/iptables/rules.v4` 的屏蔽规则会让 netfilter-persistent 开机恢复整个失败（集合那时还不存在）：只删掉这几行。

### ShadowTLS
- 监听地址：内核能双栈（有 IPv6、`bindv6only=0`）时 `::0`，否则 `0.0.0.0`（v4.4 的 #13 修复在双栈机器上丢了 IPv6 入口）；读服务文件不再用 BusyBox 没有的 `grep -P`。

## v4.4（2026-08-25）

ss-2022.sh 1.9 → 2.0，menu.sh 4.3 → 4.4，block-mainland.sh 1.0 → 1.1

### 严重：`set -e` 导致交互菜单在正常失败路径下直接退出
- `ss-2022.sh` 是交互式菜单，多处用 `return 1` 表示"本次操作未成功"，但脚本开头的 `set -e` 会让这些裸调用直接杀掉整个进程。
- 实际表现：菜单选「5. 停止」而服务本就没运行、选「4. 启动」而服务已在运行、选「8. 查看配置」而公网 IP 获取失败——都会打印一行错误后**退回 shell**。
- 更隐蔽的是 `Install()`：`start_service` 失败时脚本立即退出，用于打印排错日志的 `else` 分支**从来没有被执行过**。
- 已移除 `set -e`（含 `getipv4`/`getipv6` 里配套的 `set +e`/`set -e`），改为在依赖安装、服务安装等关键步骤显式判错并 `error_exit`。

### 严重：ShadowTLS 安装全程不放行防火墙
- `shadowtls.sh` 此前没有任何防火墙操作，而 ShadowTLS 的监听端口才是客户端实际连接的入口，在启用了 ufw / firewalld 的机器上装完直接连不上。
- 新增 `open_firewall_port()` / `close_firewall_port()`，覆盖 ufw、firewalld、iptables（firewalld 激活时跳过 iptables 避免规则冲突），安装后自动放行、卸载时自动回收。

### 严重：大陆屏蔽规则重启后静默失效
- ipset 集合是内核内存态，重启必然清空；原实现只做了 `iptables-save > /etc/iptables/rules.v4`（且未 `mkdir -p`，非 Debian 机器上被 `|| true` 静默吞掉）。重启后屏蔽完全失效，而且若装有 netfilter-persistent，恢复的规则引用一个不存在的 set 会让整条 `iptables-restore` 失败。
- 新增 `block-mainland.service`（`Type=oneshot` + `RemainAfterExit`），开机重跑规则脚本重建 ipset 并重新下规则；`disable` 时一并移除。
- `show_status` 新增「开机自动恢复」一项，未启用时明确警告。

### 严重：修改加密方式不校验密码，服务直接起不来
- 「修改配置 → 3. 修改加密配置」原先只改 method 不动 password，从 `2022-blake3-aes-128-gcm`（16 字节）改到 `-256-gcm`（32 字节）后密钥长度不匹配，ss-rust 启动失败。
- 新增 `ensure_password_matches_method()`，加密方式变更后自动校验密钥长度，不匹配时强制重新设置密码。
- `Restart()` 原先无条件打印"重启完毕"，服务挂了用户毫无察觉；现在校验 `is-active` 并在失败时输出最近 20 行日志和常见原因提示。

### 大陆屏蔽只覆盖主端口
- 规则此前只针对 `detect_ss_port` 拿到的主端口，v3.3 引入的多端口节点（`/etc/ss-rust/ports/*.json`）和 ShadowTLS 监听端口都还对大陆开放，屏蔽等于被绕过。
- 新增 `collect_protected_ports()`；生成的规则脚本改为在**运行时**自行探测端口，因此新增节点后开机自动恢复也能覆盖到。
- 新增 `flush_mainland_rules()`：从 `iptables-save` 解析删除所有引用 `mainland_cn_src` 的规则，改过端口后的旧规则也能清干净（原实现按当前端口删，会永久残留）。
- `show_status` 会列出实际生效的端口，并提示尚未纳入屏蔽的节点端口。

### ShadowTLS 其他修复
- `get_available_port()` 靠 stdout 返回端口，但失败时的错误信息也写 stdout，被 `$(...)` 一并吞掉，用户只看到"请重新输入端口"却不知道原因——错误信息改走 stderr；并补上 1-65535 范围校验。
- `create_shadowtls_service()` 写完 service 文件后立即 `daemon-reload`。原先 `daemon-reload` 在所有 `systemctl start` 之后，覆盖已有 unit（如重装换端口）时 systemd 仍用旧配置启动。
- `check_port_usage()` 改用 `ss`（`netstat` 在 Debian 12 / Ubuntu 22+ / AlmaLinux 9 默认不存在，命令找不到时一律返回"未占用"，检测形同虚设）；并改为精确匹配端口，修复 1000 被 10000 误判为占用的问题。
- 新增 `verify_shadowtls_service()`：启动后校验服务是否真的在运行，失败时输出日志，不再装完就宣告成功。
- systemd 单元里名为"性能优化"的参数实际在限制性能：移除 `CPUAffinity=0`（锁死单核）和 `CPUQuota=50%`（限制半核）；`MemoryLimit` 已废弃，改为 `MemoryMax`；`IOSchedulingClass` 由 `realtime` 降为 `best-effort`。
- 卸载时一并清理日志文件。

### 分享链接与其他
- 分享链接的 userinfo 改用 websafe base64（SIP002 规定），原先用标准 `base64 -w 0`，2022 系列密码编码后会出现 `+` `/` `=`，严格解析的客户端会失败。新增 `b64_url()`，并删除定义了却从未被调用的 `Link_QR()` / `urlsafe_base64()`。
- 修改 SS 端口后同步 ShadowTLS 后端端口：`shadowtls-ss.service` 里 `--server 127.0.0.1:<端口>` 是写死的，不同步会导致改完端口 ShadowTLS 直接失联（新增 `sync_shadowtls_backend_port()`）。
- `Update()` 升级二进制后一并重启多端口节点服务（`ss-rust-<端口>`），此前它们会继续跑旧版本进程。
- `set_port()` 新增端口占用校验，并在端口变更时回收旧端口的防火墙放行规则；`generate_random_port()` 自动跳过已被占用的端口。
- 卸载 Shadowsocks Rust、删除多端口节点时回收防火墙规则（此前 `iptables -I INPUT ... ACCEPT` 只加不删，会持续堆积）。
- `Update_Shell()` 修复以 `bash <(curl ...)` 方式运行时的更新路径：此时 `SCRIPT_PATH` 是 `/dev/fd`、`SCRIPT_NAME` 是文件描述符号，会把脚本写到错误位置；现在这种情况统一更新 `/usr/local/bin/ss-2022.sh`。
- `menu.sh` 卸载 ShadowTLS 改为遍历 service 文件：`systemctl list-units` 只列出已加载的 unit，已停止的服务会被漏掉，导致卸载不干净。
- `view_config` 中"端口被多个服务占用"的告警是误报（同一服务的 tcp/udp、IPv4/IPv6 本就会产生多行），改为单纯列出监听情况供排查。

## v4.3（2026-07-18）

menu.sh 3.4 → 4.3：与 snell 项目的 menu.sh（v4.2）合并功能，两个仓库统一为同一份文件、同一版本号。

### menu.sh 合并回 snell 项目 menu.sh（v4.2）中被删减的功能
- 新增 `close_port()` / `close_nftables_port()` / `save_nftables_rules()`：卸载时自动清理 ufw / iptables / nftables 中放行的端口规则。
- `uninstall_snell()` 补全：卸载前先停止并删除依赖 Snell 后端的 `shadowtls-snell-*` 服务；清理 `snell.socket`、`snell-netns` 服务及 `snell-netns-setup.sh`；各端口同步关闭防火墙；无其余 ShadowTLS 服务时顺带删除 `shadow-tls` 二进制。修复原实现中 `${service_name}` 未定义导致主服务文件删不掉的问题。
- `uninstall_shadowtls()` 补全：从 service 文件解析 `--listen` 端口并关闭防火墙。
- `uninstall_ss_rust()` 增强（menu.sh 独有）：清理 v3.3 引入的多端口节点服务（`ss-rust-<端口>`），并关闭主端口及各多端口的防火墙规则。
- 定义 `SYSTEMD_DIR=/etc/systemd/system`（此前被引用但从未定义）。
- 保留 ss-2022 版独有功能：中国大陆屏蔽管理（选项 10）、VLESS Reality 由 PSM 提供。

## v3.4（2026-07-18）

### 修复：开启 obfs 混淆后节点连接失败
- 根因是 shadowsocks-rust 已知 bug（[issue #694](https://github.com/shadowsocks/shadowsocks-rust/issues/694)）：配置 `server` 为 `::`（双栈）且启用 obfs 插件时，ss-rust 只监听 IPv6、完全不监听 IPv4，导致 IPv4 客户端全部连不上。
- `get_ss_listen_addr()`：启用 obfs 插件且机器有 IPv4 时，监听地址强制用 `0.0.0.0`，规避该 bug（纯 IPv6 机器仍用 `::`）。
- 分享链接补上 `obfs-host`（http 模式的 Host 头 / tls 模式的 SNI），提升客户端兼容性；Surge 配置同步输出 `obfs-host`。
- 抽出 `build_plugin_param()` 统一生成插件参数，修复多端口额外节点的分享链接此前不带 obfs 参数的问题。

## v3.3（2026-07-18）

ss-2022.sh 1.7 → 1.8，menu.sh 3.2 → 3.3

### #13 ShadowTLS 默认监听 IPv6 导致不通
- `shadowtls.sh`：新增 `get_listen_address()`，机器有 IPv4 地址时监听 `0.0.0.0`（此前硬编码 `::0`，在某些IDC环境不接受 IPv4 连接），纯 IPv6 机器仍监听 `::0`。
- `shadowtls.sh` / `ss-2022.sh`：所有从 service 文件解析 ShadowTLS 端口的地方改为兼容任意监听地址（`::0` / `0.0.0.0` / 手动修改过的地址），解决"自行修改 service 文件后提示配置文件不完整或已损坏"的问题。
- `shadowtls.sh` / `menu.sh`：snell 配置 `listen` 行解析同样改为容错格式。
- 注意：双栈机器现在默认只监听 IPv4；如需 IPv6 入口，手动把 service 中 `--listen` 改为 `[::]:端口` 即可，脚本能正常解析。

### #12 创建多个 ss 节点
- `ss-2022.sh` 主菜单新增「11. 多端口管理」：新增/查看/删除端口节点。
- 每个额外端口使用独立配置（`/etc/ss-rust/ports/<端口>.json`）和独立 systemd 服务（`ss-rust-<端口>`），互不影响；沿用主配置的加密方式/TFO/DNS/插件，密码独立。
- 卸载 Shadowsocks Rust 时自动清理所有额外节点服务。

### #11 ss 增加 obfs 配置
- `ss-2022.sh` 安装流程和「修改配置」菜单新增混淆插件选项：simple-obfs（http/tls）。
- Debian/Ubuntu 自动 `apt install simple-obfs`；RHEL 系官方源无此包，会提示自行编译并自动跳过。
- 查看配置时输出带 `plugin` 参数的 SIP002 分享链接及 Surge `obfs=` 参数。

### #10 AlmaLinux 安装问题
- `detect_os()` 改为优先读取 `/etc/os-release`，识别 AlmaLinux/Rocky/RHEL/Fedora/Anolis 等（含 `ID_LIKE` 兜底）。
- RHEL 系使用 `dnf`（无则 `yum`）安装依赖，自动启用 EPEL（qrencode 需要）。
- 防火墙支持 firewalld（RHEL 系默认）；firewalld 激活时跳过 iptables 直改，避免规则冲突。
- `service iptables save` 失败不再中断脚本（RHEL 系默认无 iptables-services）。
- `shadowtls.sh` 依赖安装同样兼容 dnf/yum，并修复了 `install_requirements` 从未被调用的问题。

### #1 安装后显示未安装 / 自定义密码启动失败
- 密码校验覆盖全部 2022-blake3 系列：`aes-128-gcm` 要求 16 字节、其余要求 32 字节的 Base64 密钥（此前 128-gcm 无校验，手动输入短密码会导致服务启动失败）。
- 不合规时循环重新输入（原实现为递归），并提示可回车自动生成。
- （时区 `cp` 报错导致安装中断的问题此前版本已修复。）

### #4 service 文件加入环境变量
- v3.2 已包含 `Environment=MONOIO_FORCE_LEGACY_DRIVER=1`（shadowtls.sh service 模板），本次仅确认。

### 新增：强制时间同步
- SS2022（2022-blake3 系列）协议校验时间戳，服务器与客户端时间误差超过 30 秒无法连接；此前脚本只设置时区、不同步时钟。
- 新增 `ensure_time_sync()`（安装依赖时自动执行）：已有 NTP 服务在运行则跳过 → 优先启用 systemd-timesyncd → 回退安装 chrony（自动适配 Debian/RHEL 服务名差异）；全部失败时明确警告用户手动配置。

### 其他修复
- `write_config` 原写法在启用自定义 DNS 时会生成非法 JSON，改用 `jq` 生成（同时保证特殊字符转义正确）。
- 「修改全部配置」原先密码在加密方式之前设置，导致按旧加密方式校验密码，已调整顺序。
- `${Success}` 变量未定义导致安装成功提示缺少前缀，已补充定义。
- ss-rust 主配置监听地址：无 IPv6 协议栈的机器自动用 `0.0.0.0` 代替 `::`。
