#!/usr/bin/env bash
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: Shadowsocks Rust（SS-2022）管理脚本
# =========================================
# 交互式菜单：多处用 return 1 表示「这次没做成」，所以不开 set -e。

# Alpine 默认没有 bash：用 sh 运行时先装上 bash 再换过去（这一段只用 POSIX sh 的写法）
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash >/dev/null 2>&1 || { echo "安装 bash 失败，请先执行 apk add bash"; exit 1; }
        else
            echo "请先安装 bash"; exit 1
        fi
    fi
    case "${0##*/}" in
        sh|ash|dash|busybox) exec bash -c "$(curl -fsSL "${SS_SCRIPT_URL:-https://ss.jinqians.com}")" ;;
        *) exec bash "$0" "$@" ;;
    esac
fi

SCRIPT_VERSION="3.0"

# 安装位置（与旧版、PSM 相同）
INSTALL_DIR="/etc/ss-rust"
BINARY_PATH="/usr/local/bin/ss-rust"
CONFIG_PATH="/etc/ss-rust/config.json"
PORTS_DIR="/etc/ss-rust/ports"
VERSION_FILE="/etc/ss-rust/ver.txt"

# 脚本的发布地址；可以用同名环境变量换成镜像（测试时指向本地的文件）
SS_SCRIPT_URL="${SS_SCRIPT_URL:-https://ss.jinqians.com}"
SS_RAW_BASE="${SS_RAW_BASE:-https://raw.githubusercontent.com/jinqians/ss-2022/main}"

SS_LIB="${SS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"  # @dev
. "$SS_LIB/common.sh"       # @bundle
. "$SS_LIB/firewall.sh"     # @bundle
. "$SS_LIB/netinfo.sh"      # @bundle
. "$SS_LIB/ss-ui.sh"        # @bundle
. "$SS_LIB/ss-service.sh"   # @bundle
. "$SS_LIB/ss-release.sh"   # @bundle
. "$SS_LIB/ss-config.sh"    # @bundle
. "$SS_LIB/ss-system.sh"    # @bundle
. "$SS_LIB/ss-links.sh"     # @bundle
. "$SS_LIB/ss-users.sh"     # @bundle
. "$SS_LIB/ss-ports.sh"     # @bundle
. "$SS_LIB/ss-outbound.sh"  # @bundle
. "$SS_LIB/ss-log.sh"       # @bundle
. "$SS_LIB/ss-mainland.sh"  # @bundle

ss_installed() { [ -x "$BINARY_PATH" ] && [ -f "$CONFIG_PATH" ]; }
ss_need_installed() { ss_installed || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }; }

# ── 安装、更新、卸载 ──────────────────────────────────────────────────────────
ss_install() {
    local port method key tfo dns ver
    if ss_installed; then
        ui_warn "已经安装了 Shadowsocks Rust。改设置用「5. 修改配置」，重装请先卸载。"
        return 0
    fi
    ss_install_deps || return 1
    echo
    ui_info "── 安装 Shadowsocks Rust ──"
    ss_ask_port || return 0; port="$ASK"
    ss_ask_method || return 0; method="$ASK"
    ss_ask_key "$method" || return 0; key="$ASK"
    ss_ask_tfo; tfo="$ASK"
    ss_ask_dns || return 0; dns="$ASK"
    ss_ask_plugin || return 0
    ss_is_2022 "$method" && ss_ensure_time_sync
    ver=$(ss_latest_version) || ui_warn "查不到最新版本，安装 ${ver}。"
    ss_install_binary "$ver" || return 1
    ss_new_config "$CONFIG_PATH" "$port" "$method" "$key" "$tfo" "$dns" "$ASK_PLUGIN" "$ASK_PLUGIN_OPTS" || { ui_err "写配置失败"; return 1; }
    ss_write_service ss-rust "$CONFIG_PATH" "Shadowsocks Rust Service" || return 1
    ss_svc_enable ss-rust
    open_port "$port"
    ss_write_command
    if ss_svc_restart_verify ss-rust; then
        ui_ok "Shadowsocks Rust 已安装并运行"
        ss_view
        ui_info "以后输入 ssrust 打开这个菜单。"
    fi
}

ss_update() {
    local cur latest
    ss_need_installed || return 1
    cur=$(ss_installed_version)
    latest=$(ss_latest_version) || ui_warn "查不到最新版本（GitHub 限流？），以 ${latest} 为准。"
    if [ -n "$cur" ] && ! ss_version_lt "$cur" "$latest"; then
        ui_ok "已是最新版本 ${cur}"
        ui_yes "重新安装 ${latest}（换成静态链接的 musl 版并核对 SHA-256）？" n || return 0
    else
        ui_yes "更新 shadowsocks-rust ${cur:-?} → ${latest}？" y || return 0
    fi
    ss_install_binary "$latest" || return 1
    ss_apply_all && ui_ok "已更新到 ${latest}，全部服务已重启"
}

ss_uninstall() {
    local port p f
    ss_installed || [ -f "$CONFIG_PATH" ] || ss_svc_exists ss-rust || { ui_warn "没有安装 Shadowsocks Rust。"; return 0; }
    ui_yes "确定卸载 Shadowsocks Rust（主端口与全部额外端口）？" n || { echo "已取消。"; return 0; }
    port=$(ss_cfg "$CONFIG_PATH" .server_port)
    for f in "${PORTS_DIR}"/*.json; do
        [ -f "$f" ] || continue
        p=$(basename "$f" .json)
        ss_svc_remove "ss-rust-$p"; close_port "$p"
    done
    ss_svc_remove ss-rust
    [ -n "$port" ] && close_port "$port"
    if ss_stls_info || [ -f "$STLS_SS_UNIT" ]; then
        if ui_yes "也删除 SS 前面的 ShadowTLS（shadowtls-ss）吗？" y; then
            systemctl stop shadowtls-ss >/dev/null 2>&1; systemctl disable shadowtls-ss >/dev/null 2>&1
            rm -f "$STLS_SS_UNIT"; systemctl daemon-reload
            [ -n "$STLS_PORT" ] && close_port "$STLS_PORT"
            ui_ok "已删除 shadowtls-ss"
        fi
    fi
    if [ -x "$MAINLAND_BLOCK_SCRIPT" ] && { ss_mainland_active || [ -f /etc/systemd/system/block-mainland.service ] || [ -f /etc/init.d/block-mainland ]; }; then
        if ui_yes "也停用并删除中国大陆屏蔽吗？" y; then
            ss_mainland_run disable >/dev/null 2>&1
            ss_mainland_run auto-update-disable >/dev/null 2>&1
            rm -f "$MAINLAND_BLOCK_SCRIPT" "$MAINLAND_EXTRACT_SCRIPT"
        fi
    fi
    rm -rf "$INSTALL_DIR" "$BINARY_PATH" "$SS_LOG_DIR"
    rm -f /usr/local/bin/ssrust /usr/local/bin/ss-2022.sh
    ui_ok "Shadowsocks Rust 已卸载（防火墙里的端口也关了）"
}

# ── 服务 ──────────────────────────────────────────────────────────────────────
ss_service_menu() {
    local c s rc
    ss_need_installed || return 1
    ui_sub "启动 / 停止 / 重启（主端口与全部额外端口）" "启动" "停止" "重启"
    ui_read c || return 0
    case "$c" in
        1|3) rc=0
             for s in $(ss_all_services); do ss_svc_restart_verify "$s" || rc=1; done
             [ "$rc" = 0 ] && ui_ok "全部在运行" ;;
        2) for s in $(ss_all_services); do ss_svc stop "$s"; done; ui_ok "已停止" ;;
    esac
}

ss_status() {
    local s
    ss_need_installed || return 1
    echo
    echo -e "  版本 $(ss_installed_version)（$(ss_target 2>/dev/null)），服务管理：$(ss_init)"
    for s in $(ss_all_services); do
        if ss_svc_active "$s"; then echo -e "  ${GREEN}●${RESET} $s  运行中"; else echo -e "  ${RED}●${RESET} $s  未运行"; fi
    done
    echo
    echo -e "${DIM}── ss-rust 最近的日志 ──${RESET}"
    ss_log_show ss-rust
}

# ── 修改配置 ──────────────────────────────────────────────────────────────────
# 改了主端口：防火墙、ShadowTLS 的后端、大陆屏蔽的规则跟着改
ss_change_port() {
    local old new
    old=$(ss_cfg "$CONFIG_PATH" .server_port)
    ss_ask_port "$old" || return 0; new="$ASK"
    [ "$new" = "$old" ] && { echo "端口没变。"; return 0; }
    ss_cfg_set "$CONFIG_PATH" '.server_port = $p' --argjson p "$new" || return 1
    ss_apply_main || return 1
    open_port "$new"; close_port "$old"
    if [ -f "$STLS_SS_UNIT" ] && grep -q -- "--server 127.0.0.1:${old} " "$STLS_SS_UNIT"; then
        sed -i "s/--server 127\.0\.0\.1:${old} /--server 127.0.0.1:${new} /" "$STLS_SS_UNIT"
        systemctl daemon-reload; systemctl restart shadowtls-ss
        ui_ok "ShadowTLS 的后端跟着改成 127.0.0.1:${new}"
    fi
    if ss_mainland_active && [ -x /etc/ss-rust/mainland_cn_rules.sh ]; then
        bash /etc/ss-rust/mainland_cn_rules.sh >/dev/null 2>&1 && ui_ok "大陆屏蔽的规则已按新端口重下"
    fi
    ui_ok "主端口改为 ${new}（防火墙已放行，旧端口已关）"
}

ss_change_key() {
    local method
    method=$(ss_cfg "$CONFIG_PATH" .method)
    [ "$(ss_users_count)" -gt 0 ] && ui_warn "开着单端口多用户：换服务器密钥后，每个用户的链接都会变（用户密钥不变）。"
    ss_ask_key "$method" || return 0
    ss_cfg_set "$CONFIG_PATH" '.password = $k' --arg k "$ASK" || return 1
    ss_apply_main && ui_ok "已换密钥，新链接见「4. 查看配置」"
}

ss_change_method() {
    local old new users key n
    old=$(ss_cfg "$CONFIG_PATH" .method); users=$(ss_users_count)
    ss_ask_method || return 0; new="$ASK"
    [ "$new" = "$old" ] && { echo "加密方式没变。"; return 0; }
    if [ "$users" -gt 0 ] && ! ss_eih_capable "$new"; then
        ui_err "开着单端口多用户（${users} 个用户），而 ${new} 不支持多用户。先删光用户，或者选 aes-128-gcm / aes-256-gcm 的 2022 方式。"
        return 1
    fi
    key=$(ss_cfg "$CONFIG_PATH" .password)
    if ! ss_key_ok "$new" "$key"; then
        ui_warn "现在的密钥不适合 ${new}，要换一个。"
        ss_ask_key "$new" || return 0; key="$ASK"
    fi
    n=$(ss_key_len "$new")
    if [ "$users" -gt 0 ] && [ "$n" != "$(ss_key_len "$old")" ]; then
        ui_warn "密钥长度变了：每个用户都换新密钥，用户的链接全部要重发。"
        local i
        for (( i = 0; i < users; i++ )); do
            ss_cfg_set "$CONFIG_PATH" ".users[$i].password = \$k" --arg k "$(ss_gen_key "$new")" || return 1
        done
    fi
    ss_cfg_set "$CONFIG_PATH" '.method = $m | .password = $k' --arg m "$new" --arg k "$key" || return 1
    if ss_apply_main; then
        ss_is_2022 "$new" && ss_ensure_time_sync
        ui_ok "加密方式改为 ${new}，新链接见「4. 查看配置」"
    fi
}

ss_change_tfo() {
    ss_ask_tfo
    ss_cfg_set "$CONFIG_PATH" '.fast_open = $t' --argjson t "$ASK" || return 1
    ss_apply_main && ui_ok "TFO：$ASK"
}

ss_change_dns() {
    ss_ask_dns || return 0
    if [ -n "$ASK" ]; then ss_cfg_set "$CONFIG_PATH" '.nameserver = $d' --arg d "$ASK" || return 1
    else ss_cfg_set "$CONFIG_PATH" 'del(.nameserver)' || return 1; fi
    ss_apply_main && ui_ok "DNS：${ASK:-系统的}"
}

ss_change_plugin() {
    ss_ask_plugin || return 0
    if [ -n "$ASK_PLUGIN" ]; then
        ss_cfg_set "$CONFIG_PATH" '.plugin = $p | .plugin_opts = $o | .server = $s' \
            --arg p "$ASK_PLUGIN" --arg o "$ASK_PLUGIN_OPTS" --arg s "$(ss_listen_addr "$ASK_PLUGIN")" || return 1
    else
        ss_cfg_set "$CONFIG_PATH" 'del(.plugin, .plugin_opts) | .server = $s' --arg s "$(ss_listen_addr)" || return 1
    fi
    ss_apply_main && ui_ok "混淆插件：${ASK_PLUGIN:+$ASK_PLUGIN（$ASK_PLUGIN_OPTS）}${ASK_PLUGIN:-不用}"
}

# 入站 UDP 允许 IP 分片（1.25 起默认不允许；只有大的 UDP 包丢了才需要开）
ss_change_frag() {
    local f on
    on=$(ss_cfg "$CONFIG_PATH" '.inbound_udp_allow_fragmentation // false')
    if [ "$on" = true ]; then
        ui_yes "入站 UDP 现在允许分片，改回默认（不允许）？" y || return 0
        for f in $(ss_all_configs); do ss_cfg_set "$f" 'del(.inbound_udp_allow_fragmentation)' || return 1; done
    else
        ui_info "shadowsocks-rust 1.25 起入站 UDP 默认不分片。只有大的 UDP 包（比如某些游戏、视频通话）丢了才需要打开。"
        ui_yes "允许入站 UDP 分片？" n || return 0
        for f in $(ss_all_configs); do ss_cfg_set "$f" '.inbound_udp_allow_fragmentation = true' || return 1; done
    fi
    ss_apply_all && ui_ok "入站 UDP 分片：$(ss_cfg "$CONFIG_PATH" '.inbound_udp_allow_fragmentation // false' | sed 's/true/允许/;s/false/不允许（默认）/')"
}

ss_modify_menu() {
    local c
    ss_need_installed || return 1
    ui_sub "修改配置（主端口）" "端口" "密码 / 密钥" "加密方式" "TCP Fast Open" "DNS" "混淆插件（simple-obfs）" "入站 UDP 分片"
    ui_read c || return 0
    case "$c" in
        1) ss_change_port ;;
        2) ss_change_key ;;
        3) ss_change_method ;;
        4) ss_change_tfo ;;
        5) ss_change_dns ;;
        6) ss_change_plugin ;;
        7) ss_change_frag ;;
    esac
}

# ── 其他 ──────────────────────────────────────────────────────────────────────
ss_shadowtls() {
    ss_need_installed || return 1
    if [ "$(ss_init)" != systemd ]; then
        ui_err "ShadowTLS 管理脚本目前只支持 systemd 的系统（Debian / Ubuntu / RHEL 系），Alpine 上用不了。"
        return 1
    fi
    ss_run_remote "${SS_RAW_BASE}/shadowtls.sh" "ShadowTLS 管理脚本"
}

ss_update_self() {
    local tmp new
    tmp=$(mktemp) || return 1
    if ! fetch_verified_script "$SS_SCRIPT_URL" "$tmp"; then rm -f "$tmp"; return 1; fi
    new=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | cut -d'"' -f2)
    if [ "$new" = "$SCRIPT_VERSION" ]; then
        ui_ok "已是最新版本 ${SCRIPT_VERSION}"; rm -f "$tmp"; return 0
    fi
    install -m 755 "$tmp" /usr/local/bin/ss-2022.sh; rm -f "$tmp"
    ui_ok "脚本已更新：${SCRIPT_VERSION} → ${new}"
    exec bash /usr/local/bin/ss-2022.sh
}

# 旧版的 ssrust 是指向 /usr/local/bin/ss-2022.sh 的链接：换成每次取最新脚本的命令
ss_upgrade_command() {
    [ -L /usr/local/bin/ssrust ] && ss_installed && ss_write_command >/dev/null 2>&1
    return 0
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────
ss_status_block() {
    local svcs s r=0 t=0 users extra=0 f ob st
    ui_status_reset
    ss_ips
    if ! ss_installed; then
        ui_status_add "SS-Rust" "未安装" "$YELLOW"
        ui_status_add "IP" "${SS_IPV4:-${SS_IPV6:-N/A}}"
        return
    fi
    svcs=$(ss_all_services)
    for s in $svcs; do t=$((t + 1)); ss_svc_active "$s" && r=$((r + 1)); done
    if [ "$t" -gt 0 ] && [ "$r" = "$t" ]; then ui_status_add "SS-Rust" "运行中 ${r}/${t}" "$GREEN"
    elif [ "$r" -gt 0 ]; then ui_status_add "SS-Rust" "运行中 ${r}/${t}" "$YELLOW"
    else ui_status_add "SS-Rust" "已停止" "$RED"; fi
    ui_status_add "IP" "${SS_IPV4:-${SS_IPV6:-N/A}}"
    ui_status_add "版本" "$(ss_installed_version)"
    ui_status_add "加密" "$(ss_cfg "$CONFIG_PATH" .method)"
    for f in "${PORTS_DIR}"/*.json; do [ -f "$f" ] && extra=$((extra + 1)); done
    ui_status_add "端口" "$(ss_cfg "$CONFIG_PATH" .server_port)$( [ "$extra" -gt 0 ] && echo " +${extra}")"
    users=$(ss_users_count)
    if [ "$users" -gt 0 ]; then ui_status_add "用户" "${users} 个（单端口多用户）" "$GREEN"; else ui_status_add "用户" "单密钥"; fi
    if [ -f "$STLS_SS_UNIT" ]; then
        if systemctl is-active --quiet shadowtls-ss 2>/dev/null; then ui_status_add "ShadowTLS" "运行中" "$GREEN"; else ui_status_add "ShadowTLS" "已停止" "$YELLOW"; fi
    else
        ui_status_add "ShadowTLS" "未安装" "$YELLOW"
    fi
    ob=$(ss_outbound_current)
    if [ -n "$ob" ]; then ui_status_add "出口" "$(echo "$ob" | ss_proxy_show)" "$GREEN"; else ui_status_add "出口" "直连"; fi
    if ss_mainland_active; then st="已启用"; ui_status_add "大陆屏蔽" "$st" "$GREEN"; else ui_status_add "大陆屏蔽" "未启用" "$YELLOW"; fi
}

ss_show_menu() {
    local BC='\033[96m' BB='\033[94m' WH='\033[97m'
    clear 2>/dev/null || true
    echo
    printf "  ${BOLD}${BC}%s${RESET}\n" ' ____    ____           ____     ___    ____    ____  '
    printf "  ${BOLD}${BC}%s${RESET}\n" '/ ___|  / ___|         |___ \   / _ \  |___ \  |___ \ '
    printf "  ${BOLD}${BB}%s${RESET}\n" '\___ \  \___ \   _____   __) | | | | |   __) |   __) |'
    printf "  ${BOLD}${BB}%s${RESET}\n" ' ___) |  ___) | |_____| / __/  | |_| |  / __/   / __/ '
    printf "  ${BOLD}${BC}%s${RESET}\n" '|____/  |____/         |_____|  \___/  |_____| |_____|'
    echo
    echo -e "  ${BOLD}${WH}SS-2022 Manager v${SCRIPT_VERSION}${RESET}  ${DIM}·····${RESET}  ${YELLOW}◆ https://jinqians.com${RESET}"
    echo -e "  ${BLUE}──────────────────────────────────────────────${RESET}"
    ss_status_block
    ui_status_print
    echo -e "  ${BLUE}──────────────────────────────────────────────${RESET}"
    echo
    ui_items "JQ's SS-2022 Manager" 7 \
        "安装 Shadowsocks Rust" "更新 Shadowsocks Rust" "卸载 Shadowsocks Rust" "查看配置与链接" \
        "修改配置" "启动 / 停止 / 重启" "运行状态与日志" \
        "单端口多用户（EIH）" "多端口" "出口代理" "ShadowTLS" "屏蔽中国大陆" "日志设置" "更新脚本"
    ui_items_end "退出"
}

check_root
ss_upgrade_command
num=""
while true; do
    ss_show_menu
    ui_read num || { echo; exit 0; }
    case "$num" in
        1) ss_install ;;
        2) ss_update ;;
        3) ss_uninstall ;;
        4) ss_need_installed && ss_view ;;
        5) ss_modify_menu ;;
        6) ss_service_menu ;;
        7) ss_status ;;
        8) ss_users_menu ;;
        9) ss_ports_menu ;;
        10) ss_outbound_menu ;;
        11) ss_shadowtls ;;
        12) ss_mainland_menu ;;
        13) ss_log_menu ;;
        14) ss_update_self ;;
        0) echo "再见。"; exit 0 ;;
        *) ui_err "请输入 0-14" ;;
    esac
    ui_pause
done
