#!/usr/bin/env bash
# 此文件由 tools/build.sh 从 src/block-mainland.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: 屏蔽中国大陆来源到 Shadowsocks Rust / ShadowTLS 端口的连接
# =========================================
# 用法：block-mainland.sh [enable|disable|update|status|auto-update-enable [daily|weekly]|auto-update-disable|auto-update-status]
# 不带参数是菜单。ss-2022.sh 的「屏蔽中国大陆」与多功能菜单都调用它。

# shellcheck disable=SC2034  # 版本号：看文件就知道是哪一版
SCRIPT_VERSION="2.0"
CONFIG_PATH="/etc/ss-rust/config.json"
SS_RAW_BASE="${SS_RAW_BASE:-https://raw.githubusercontent.com/jinqians/ss-2022/main}"

# ── lib/common.sh ─────────────────────────────────────────────────────────────
# 所有脚本共用：颜色、root 检查、系统与包管理器、脚本的发布地址。
# 只用 POSIX sh 的写法：Alpine / Docker 版脚本在 ash、dash 下也要能用。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 脚本的发布地址。短域名（*.jinqians.com）由 Cloudflare 重定向到仓库里的文件：
# snell / snell-centos / snell-alpine → 根目录，menu / snell-docker / install → scripts/。
# 菜单里调用的子脚本从 SNELL_RAW_BASE 下的 scripts/、docker/ 取。
# 脚本自身的更新与管理命令走短域名，运行才会被统计到。
# 可以用同名环境变量换成镜像地址（测试时指向本地的文件）。
SNELL_RAW_BASE="${SNELL_RAW_BASE:-https://raw.githubusercontent.com/jinqians/snell/main}"
SNELL_SCRIPT_URL="${SNELL_SCRIPT_URL:-https://snell.jinqians.com}"                     # snell.sh（Debian / Ubuntu / CentOS / RHEL）
SNELL_ALPINE_SCRIPT_URL="${SNELL_ALPINE_SCRIPT_URL:-https://snell-alpine.jinqians.com}" # snell-alpine.sh
SNELL_DOCKER_SCRIPT_URL="${SNELL_DOCKER_SCRIPT_URL:-https://snell-docker.jinqians.com}" # snell-docker.sh
SNELL_MENU_SCRIPT_URL="${SNELL_MENU_SCRIPT_URL:-https://menu.jinqians.com}"             # menu.sh

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        printf '%b\n' "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 识别系统：OS_FAMILY = debian | rhel | alpine | unknown，PKG = apt | dnf | yum | apk
OS_FAMILY=""
PKG=""
detect_os() {
    [ -n "$OS_FAMILY" ] && return 0
    OS_FAMILY="unknown"
    if [ -f /etc/os-release ]; then
        # 在子 shell 里读，os-release 的 NAME / VERSION 等变量不会覆盖脚本自己的
        case " $(. /etc/os-release; echo "$ID $ID_LIKE" | tr '[:upper:]' '[:lower:]') " in
            *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
            *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*) OS_FAMILY="rhel" ;;
            *" alpine "*) OS_FAMILY="alpine" ;;
        esac
    elif [ -f /etc/redhat-release ]; then
        OS_FAMILY="rhel"
    fi
    if command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG="yum"
    elif command -v apk >/dev/null 2>&1; then PKG="apk"
    fi
}

# 等待其他 apt 进程完成
wait_for_apt() {
    command -v fuser >/dev/null 2>&1 || return 0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; do
        printf '%b\n' "${YELLOW}等待其他 apt 进程完成...${RESET}"
        sleep 2
    done
}

# 用系统的包管理器安装软件包
pkg_install() {
    detect_os
    case "$PKG" in
        apt)
            wait_for_apt
            DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *)
            printf '%b\n' "${RED}未识别的包管理器，请手动安装：$*${RESET}"
            return 1
            ;;
    esac
}

# 提供某个命令的软件包名（各发行版不同的在这里对上）
pkg_for_cmd() {
    detect_os
    case "$1" in
        ip|ss) if [ "$OS_FAMILY" = "rhel" ]; then echo "iproute"; else echo "iproute2"; fi ;;
        nft) echo "nftables" ;;
        fuser) echo "psmisc" ;;
        gpg) if [ "$OS_FAMILY" = "rhel" ]; then echo "gnupg2"; else echo "gnupg"; fi ;;
        sysctl) if [ "$OS_FAMILY" = "rhel" ]; then echo "procps-ng"; else echo "procps"; fi ;;
        modprobe) echo "kmod" ;;
        *) echo "$1" ;;
    esac
}

# 缺哪个命令就装哪个包；装不上返回非 0，由调用方决定是否退出
ensure_cmds() {
    _ec_missing=""
    for _ec_cmd in "$@"; do
        command -v "$_ec_cmd" >/dev/null 2>&1 || _ec_missing="${_ec_missing} $(pkg_for_cmd "$_ec_cmd")"
    done
    [ -z "$_ec_missing" ] && return 0
    printf '%b\n' "${YELLOW}正在安装依赖：${_ec_missing# }${RESET}"
    # shellcheck disable=SC2086 # 包名按空格分开传
    pkg_install $_ec_missing || return 1
    for _ec_cmd in "$@"; do
        if ! command -v "$_ec_cmd" >/dev/null 2>&1; then
            printf '%b\n' "${RED}安装后仍找不到 ${_ec_cmd}，请手动安装 $(pkg_for_cmd "$_ec_cmd")${RESET}"
            return 1
        fi
    done
}

# 下载远程脚本并做完整性校验：传输失败即停、非空、语法检查。
# 只能保证传输完整；仓库本身被篡改要靠发布签名来防。
fetch_verified_script() {   # <url> <dest>
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$1" -o "$2"; then
        printf '%b\n' "${RED}下载失败: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    if [ ! -s "$2" ]; then
        printf '%b\n' "${RED}下载的文件为空，已丢弃: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    # bash 能解析 sh 写法；没有 bash 的系统（Alpine）用 sh 检查
    if command -v bash >/dev/null 2>&1; then
        _fv_shell=bash
    else
        _fv_shell=sh
    fi
    if ! "$_fv_shell" -n "$2" 2>/dev/null; then
        printf '%b\n' "${RED}下载的脚本未通过语法检查，已丢弃: $1${RESET}" >&2
        rm -f "$2"
        return 1
    fi
    return 0
}

# ── lib/ss-ui.sh ──────────────────────────────────────────────────────────────
# 菜单的样子（与 PSM、snell 的主菜单一致）：标题、「标签 ▶ 值」两列的状态栏、
# ═ 框里两列的选项（先排满左列）、横线下的 0。bash。

BOLD='\033[1m'
BLUE='\033[34m'
DIM='\033[2m'

# 显示宽度，与 locale 无关（新装的 VPS 常常没有 UTF-8 locale）：逐个 UTF-8 字节看，
# ASCII 与两字节的字符（×）占一格，三、四字节的（中文）占两格，后续字节不算
ui_width() {
    local s="$1" i code w=0
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v code '%d' "'${s:i:1}"
        (( code < 0 )) && (( code += 256 ))
        if (( code < 0x80 || (code >= 0xC0 && code < 0xE0) )); then
            w=$((w + 1))
        elif (( code >= 0xE0 )); then
            w=$((w + 2))
        fi
    done
    echo "$w"
}

ui_pad() {   # <文字> <宽度>：文字后补空格到这个宽度
    local w; w=$(ui_width "$1")
    printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''
}

# 状态栏：先 ui_status_reset，再逐项 ui_status_add <标签> <值> [颜色]，最后 ui_status_print
UI_LABELS=(); UI_VALUES=(); UI_COLORS=()
ui_status_reset() { UI_LABELS=(); UI_VALUES=(); UI_COLORS=(); }
ui_status_add() { UI_LABELS+=("$1"); UI_VALUES+=("$2"); UI_COLORS+=("${3:-}"); }
ui_status_print() {   # 标签 9 格，左列的值补到 16 格（长的值放右列）
    local i line n=${#UI_LABELS[@]}
    for (( i = 0; i < n; i += 2 )); do
        line="  ${CYAN}$(ui_pad "${UI_LABELS[i]}" 9)${RESET} ▶  ${UI_COLORS[i]}"
        if (( i + 1 < n )); then
            line="${line}$(ui_pad "${UI_VALUES[i]}" 16)${RESET} ${CYAN}$(ui_pad "${UI_LABELS[i + 1]}" 9)${RESET} ▶  ${UI_COLORS[i + 1]}${UI_VALUES[i + 1]}${RESET}"
        else
            line="${line}${UI_VALUES[i]}${RESET}"
        fi
        echo -e "$line"
    done
}

# 两列的选项：ui_items <标题> <左列行数> <第 1 项> <第 2 项> …（编号从 1 起，先排满左列）
ui_items() {
    local title="$1" rows="$2" i k w=0 line
    shift 2
    local items=("$@")
    local wide="══════════════════════════════════════════════════════════════"
    for (( i = 0; i < rows && i < ${#items[@]}; i++ )); do
        k=$(ui_width "${items[i]}"); (( k > w )) && w=$k
    done
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    # 标题居中（62 格）
    k=$(ui_width "$title")
    echo -e "${BOLD}$(printf '%*s' $(( (62 - k) / 2 )) '')${title}${RESET}"
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    for (( i = 0; i < rows && i < ${#items[@]}; i++ )); do
        line="  ${CYAN}$(printf '%2d.' $((i + 1)))${RESET} "
        if [ -n "${items[i + rows]:-}" ]; then
            line="${line}$(ui_pad "${items[i]}" "$w")  ${CYAN}$(printf '%2d.' $((i + 1 + rows)))${RESET} ${items[i + rows]}"
        else
            line="${line}${items[i]}"
        fi
        echo -e "$line"
    done
}
ui_items_end() {   # [0 的说明]
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN} 0.${RESET} ${1:-退出}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"
}

# 子菜单：ui_sub <标题> <第 1 项> <第 2 项> …（一列，编号从 1 起，0 返回）
ui_sub() {
    local title="$1" i
    shift
    echo
    echo -e "${BOLD}${BLUE}── ${title} $(printf '─%.0s' $(seq 1 $(( 40 - $(ui_width "$title") > 4 ? 40 - $(ui_width "$title") : 4 ))))${RESET}"
    for (( i = 1; i <= $#; i++ )); do
        echo -e "  ${CYAN}$(printf '%2d.' "$i")${RESET} ${!i}"
    done
    echo -e "  ${CYAN} 0.${RESET} 返回"
}

# 读一个选择；读不到（输入结束）时返回 1
ui_read() {   # <变量名> [提示]
    local __v
    if ! read -rp "$(echo -e "${CYAN}${2:-请选择: }${RESET}")" __v; then
        echo
        return 1
    fi
    printf -v "$1" '%s' "$__v"
}

# 问 y/n：ui_yes <提示> [默认 y|n]
ui_yes() {
    local a d="${2:-n}" hint="[y/N]"
    [ "$d" = y ] && hint="[Y/n]"
    read -rp "$1 ${hint}: " a || return 1
    a=${a:-$d}
    case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

ui_pause() { echo; read -rp "$(echo -e "${CYAN}按回车返回…${RESET}")" _ || true; }

ui_ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
ui_warn() { echo -e "${YELLOW}$*${RESET}"; }
ui_err()  { echo -e "${RED}$*${RESET}"; }
ui_info() { echo -e "${CYAN}$*${RESET}"; }

# ── lib/ss-service.sh ─────────────────────────────────────────────────────────
# ss-rust 的服务：systemd（Debian / Ubuntu / RHEL 系）或 OpenRC（Alpine）。
# 主服务 ss-rust、每个额外端口一个 ss-rust-<端口>，名字与路径和旧版一样（PSM 也认这些）。
# 主服务一般跑 /etc/ss-rust/config.json；开了单端口多用户时跑生成的 config-eih.json（见 ss-config.sh）。bash。

ss_init() {
    if [ -d /run/systemd/system ]; then
        echo systemd
    elif [ -x /sbin/openrc-run ] || command -v openrc-run >/dev/null 2>&1; then
        echo openrc
    else
        echo none
    fi
}

ss_unit_file() {   # <服务名>
    case "$(ss_init)" in
        openrc) echo "/etc/init.d/$1" ;;
        *) echo "/etc/systemd/system/$1.service" ;;
    esac
}

ss_svc_exists() { [ -f "$(ss_unit_file "$1")" ]; }

# 写服务文件：<服务名> <配置文件> <说明>
ss_write_service() {
    local name="$1" conf="$2" desc="$3" f
    f=$(ss_unit_file "$name")
    case "$(ss_init)" in
        systemd)
            cat > "$f" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH} -c ${conf}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            ;;
        openrc)
            cat > "$f" <<EOF
#!/sbin/openrc-run
description="${desc}"
command="${BINARY_PATH}"
command_args="-c ${conf}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
rc_ulimit="-n 1048576"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.log"

depend() {
    need net
    after firewall
}
EOF
            chmod 755 "$f"
            ;;
        *)
            ui_err "没有找到 systemd 或 OpenRC，无法创建服务。"
            return 1
            ;;
    esac
}

# 服务文件里跑的是哪个配置
ss_svc_conf() {   # <服务名>
    sed -n 's/.*[ "]-c \([^ "]*\).*/\1/p' "$(ss_unit_file "$1")" 2>/dev/null | head -n 1
}

ss_svc_enable() {
    case "$(ss_init)" in
        systemd) systemctl enable "$1" >/dev/null 2>&1 ;;
        openrc) rc-update add "$1" default >/dev/null 2>&1 ;;
    esac
}

ss_svc() {   # <start|stop|restart> <服务名>
    case "$(ss_init)" in
        systemd) systemctl "$1" "$2" >/dev/null 2>&1 ;;
        openrc) rc-service "$2" "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ss_svc_active() {   # <服务名>
    case "$(ss_init)" in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc) rc-service "$1" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ss_svc_logs() {   # <服务名> [行数]
    local n="${2:-20}"
    case "$(ss_init)" in
        systemd) journalctl --no-pager -n "$n" -u "$1" 2>/dev/null ;;
        openrc) tail -n "$n" "/var/log/$1.log" 2>/dev/null ;;
    esac
}

ss_svc_remove() {   # <服务名>
    ss_svc stop "$1" || true
    case "$(ss_init)" in
        systemd)
            systemctl disable "$1" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$1.service"
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del "$1" default >/dev/null 2>&1 || true
            rm -f "/etc/init.d/$1" "/var/log/$1.log"
            ;;
    esac
}

# 启动（或重启）并确认在跑；起不来时打印日志与常见原因
ss_svc_restart_verify() {   # <服务名>
    local i
    ss_svc restart "$1" || ss_svc start "$1" || true
    for i in 1 2 3 4 5 6; do
        sleep 1
        ss_svc_active "$1" && return 0
    done
    ui_err "$1 没能运行起来，最近的日志："
    ss_svc_logs "$1" 20 | sed 's/^/  /'
    ui_warn "常见原因：密码与加密方式不匹配、端口被占用、混淆插件没装。"
    return 1
}

# 本脚本管理的全部服务：主服务和每个额外端口的
ss_all_services() {
    local f
    ss_svc_exists ss-rust && echo ss-rust
    for f in "${PORTS_DIR}"/*.json; do
        [ -f "$f" ] || continue
        echo "ss-rust-$(basename "$f" .json)"
    done
}

# ── lib/bm-rules.sh ───────────────────────────────────────────────────────────
# 屏蔽中国大陆来源的连接：IP 库、规则脚本、状态。
#
# IP 库是纯文本的 CIDR 列表：IPv4 来自 Hackl0us/GeoIP2-CN（与旧版用的 Country.mmdb 同一份数据，
# 不再需要 Python 与 maxminddb），IPv6 来自 gaoyifan/china-operator-ip。
# 规则脚本 /etc/ss-rust/mainland_cn_rules.sh 自成一体（POSIX sh）：每次运行时现找要保护的端口
# （主端口、额外端口、ShadowTLS 的监听端口），用 ipset restore 一次导入，再给每个端口下 DROP。
# 开机由 block-mainland 服务运行它（ipset 是内存里的，重启就没了）。bash。

BM_DIR="/etc/ss-rust/iprules"
BM_V4_FILE="${BM_DIR}/mainland_cn.txt"
BM_V6_FILE="${BM_DIR}/mainland_cn6.txt"
BM_RULES="/etc/ss-rust/mainland_cn_rules.sh"
BM_V4_URL="${BM_V4_URL:-https://raw.githubusercontent.com/Hackl0us/GeoIP2-CN/release/CN-ip-cidr.txt}"
BM_V6_URL="${BM_V6_URL:-https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt}"

bm_deps() {
    detect_os
    ensure_cmds curl ipset iptables || { ui_err "依赖安装失败（ipset、iptables）。"; return 1; }
    command -v ip6tables >/dev/null 2>&1 || pkg_install ip6tables >/dev/null 2>&1 || true
    return 0
}

# 下载一个列表：只留像 CIDR 的行，太少就当没下到（不覆盖已有的）
bm_fetch_list() {   # <地址> <文件> <至少几行>
    local tmp n
    tmp=$(mktemp) || return 1
    if curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$1" 2>/dev/null \
        | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' > "$tmp"; then
        n=$(wc -l < "$tmp" | tr -d ' ')
        if [ "$n" -ge "$3" ]; then
            mkdir -p "$BM_DIR"; mv -f "$tmp" "$2"; echo "$n"; return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

bm_download() {
    local n
    ui_info "下载中国大陆的 IP 段…"
    if n=$(bm_fetch_list "$BM_V4_URL" "$BM_V4_FILE" 1000); then
        ui_ok "IPv4：${n} 段"
    elif [ -s "$BM_V4_FILE" ]; then
        ui_warn "IPv4 列表下载失败，用已有的（$(wc -l < "$BM_V4_FILE" | tr -d ' ') 段）"
    else
        ui_err "IPv4 列表下载失败：$BM_V4_URL"; return 1
    fi
    if n=$(bm_fetch_list "$BM_V6_URL" "$BM_V6_FILE" 100); then
        ui_ok "IPv6：${n} 段"
    else
        ui_warn "IPv6 列表下载失败$( [ -s "$BM_V6_FILE" ] && echo "，用已有的" || echo "，这次只屏蔽 IPv4")"
    fi
    return 0
}

# 写规则脚本。它不依赖本脚本：开机、改端口后直接运行它即可（参数 stop 是撤掉规则）
bm_write_rules() {
    mkdir -p "$(dirname "$BM_RULES")"
    cat > "$BM_RULES" <<'EOF'
#!/bin/sh
# 由 block-mainland.sh 生成：屏蔽中国大陆来源到 Shadowsocks / ShadowTLS 端口的连接。
# 运行它 = 按现在的端口重新下规则；加参数 stop = 撤掉规则。请勿手改（重新启用时会覆盖）。
DIR=/etc/ss-rust/iprules

# 现在要保护的端口：主端口、额外端口、ShadowTLS 的监听端口
ports() {
    for f in /etc/ss-rust/config.json /etc/ss-rust/ports/*.json; do
        [ -f "$f" ] || continue
        sed -n 's/.*"server_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1
    done
    for f in /etc/systemd/system/shadowtls-*.service; do
        [ -f "$f" ] || continue
        sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1
    done
}

# 删掉引用某个集合的全部 INPUT 规则（按 *-save 的输出删，改过端口的旧规则也删得掉）
flush() {   # <iptables|ip6tables> <集合>
    command -v "$1" >/dev/null 2>&1 || return 0
    i=0
    while [ $i -lt 200 ]; do
        r=$("$1-save" 2>/dev/null | grep -m1 -- "-A INPUT .*--match-set $2 src") || break
        [ -n "$r" ] || break
        # shellcheck disable=SC2086
        "$1" -D INPUT ${r#-A INPUT } 2>/dev/null || break
        i=$((i + 1))
    done
}

apply() {   # <iptables|ip6tables> <集合> <inet|inet6> <列表文件>
    flush "$1" "$2"
    ipset destroy "$2" 2>/dev/null
    [ "${STOP:-}" = 1 ] && return 0
    [ -s "$4" ] && command -v "$1" >/dev/null 2>&1 || return 0
    { echo "create $2 hash:net family $3 maxelem 262144"; sed "s/^/add $2 /" "$4"; } | ipset restore -exist || return 1
    for p in $(ports | sort -un); do
        "$1" -I INPUT -p tcp --dport "$p" -m set --match-set "$2" src -j DROP
        "$1" -I INPUT -p udp --dport "$p" -m set --match-set "$2" src -j DROP
    done
}

[ "${1:-}" = stop ] && STOP=1
apply iptables mainland_cn_src inet "$DIR/mainland_cn.txt" || exit 1
apply ip6tables mainland_cn6_src inet6 "$DIR/mainland_cn6.txt" || true
EOF
    chmod 755 "$BM_RULES"
    # 旧版的逐行导入脚本用不到了
    rm -f /usr/local/bin/block-mainland-import-ips.sh
}

bm_active() { iptables-save 2>/dev/null | grep -q 'mainland_cn_src'; }

# 与规则脚本里一样的端口
bm_ports() {
    local f
    for f in "$CONFIG_PATH" /etc/ss-rust/ports/*.json; do
        [ -f "$f" ] || continue
        sed -n 's/.*"server_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1
    done
    for f in /etc/systemd/system/shadowtls-*.service; do
        [ -f "$f" ] || continue
        sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$f" | head -n 1
    done | sort -un
}

bm_status() {
    local v4p v6p missing="" p
    echo
    echo -e "${BOLD}${BLUE}── 中国大陆屏蔽 ──────────────────────────────${RESET}"
    echo -e "  要保护的端口  $(bm_ports | tr '\n' ' ')"
    echo -e "  IP 库         IPv4 $( [ -s "$BM_V4_FILE" ] && wc -l < "$BM_V4_FILE" | tr -d ' ' || echo 0) 段，IPv6 $( [ -s "$BM_V6_FILE" ] && wc -l < "$BM_V6_FILE" | tr -d ' ' || echo 0) 段"
    v4p=$(iptables -S INPUT 2>/dev/null | grep -- '--match-set mainland_cn_src src' | sed -n 's/.*--dport \([0-9]*\).*/\1/p' | sort -un | tr '\n' ' ')
    v6p=$(ip6tables -S INPUT 2>/dev/null | grep -- '--match-set mainland_cn6_src src' | sed -n 's/.*--dport \([0-9]*\).*/\1/p' | sort -un | tr '\n' ' ')
    if [ -n "$v4p" ]; then
        echo -e "  规则          ${GREEN}已启用${RESET}  IPv4：${v4p}$( [ -n "$v6p" ] && echo " IPv6：${v6p}")"
        for p in $(bm_ports); do case " $v4p " in *" $p "*) ;; *) missing="${missing}${p} " ;; esac; done
        [ -n "$missing" ] && ui_warn "  这些端口还没屏蔽：${missing}（重新选「启用」即可）"
    else
        echo -e "  规则          ${YELLOW}未启用${RESET}"
    fi
    echo -e "  开机自动恢复  $(bm_boot_enabled && echo "${GREEN}已启用${RESET}" || echo "${YELLOW}未启用${RESET}")"
    echo -e "  定时更新      $(bm_auto_update_state)"
}

# ── lib/bm-boot.sh ────────────────────────────────────────────────────────────
# 开机自动恢复（systemd 服务 / OpenRC 服务）与定时更新 IP 库（systemd 定时器 /
# Alpine 的 /etc/periodic）。不依赖 cron 软件包。bash。

BM_BOOT_UNIT="/etc/systemd/system/block-mainland.service"
BM_BOOT_OPENRC="/etc/init.d/block-mainland"
BM_TIMER="/etc/systemd/system/block-mainland-update.timer"
BM_TIMER_SVC="/etc/systemd/system/block-mainland-update.service"
BM_PERIODIC_NAME="block-mainland-update"
BM_UPDATE_LOG="/var/log/block-mainland-update.log"
BM_SELF="/usr/local/bin/block-mainland.sh"
BM_OLD_CRON="/etc/cron.d/block-mainland-auto-update"   # 旧版的定时任务

bm_boot_enable() {
    case "$(ss_init)" in
        systemd)
            cat > "$BM_BOOT_UNIT" <<EOF
[Unit]
Description=Block mainland China connections to Shadowsocks
After=network-online.target ss-rust.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${BM_RULES}
ExecStop=/bin/sh ${BM_RULES} stop

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable block-mainland >/dev/null 2>&1
            ;;
        openrc)
            cat > "$BM_BOOT_OPENRC" <<EOF
#!/sbin/openrc-run
description="Block mainland China connections to Shadowsocks"

depend() {
    need net
    after firewall iptables ip6tables ss-rust
}

start() {
    ebegin "Applying mainland China block rules"
    /bin/sh ${BM_RULES} >/dev/null 2>&1
    eend \$?
}

stop() {
    ebegin "Removing mainland China block rules"
    /bin/sh ${BM_RULES} stop >/dev/null 2>&1
    eend 0
}
EOF
            chmod 755 "$BM_BOOT_OPENRC"
            rc-update add block-mainland default >/dev/null 2>&1
            # 让 OpenRC 记下它已启动（规则刚才已经下了，start 再跑一次也无妨）
            rc-service block-mainland start >/dev/null 2>&1 || true
            ;;
        *) ui_warn "没有 systemd 或 OpenRC：重启后要手动运行 sh ${BM_RULES}"; return 1 ;;
    esac
}

bm_boot_disable() {
    if [ -f "$BM_BOOT_UNIT" ]; then
        systemctl disable block-mainland >/dev/null 2>&1 || true
        rm -f "$BM_BOOT_UNIT"; systemctl daemon-reload
    fi
    if [ -f "$BM_BOOT_OPENRC" ]; then
        rc-update del block-mainland default >/dev/null 2>&1 || true
        rm -f "$BM_BOOT_OPENRC"
    fi
    return 0
}

bm_boot_enabled() {
    case "$(ss_init)" in
        systemd) [ -f "$BM_BOOT_UNIT" ] && systemctl is-enabled --quiet block-mainland 2>/dev/null ;;
        openrc) [ -f "$BM_BOOT_OPENRC" ] && rc-update show default 2>/dev/null | grep -qw block-mainland ;;
        *) return 1 ;;
    esac
}

# 定时更新：每天或每周一 04:30 运行一次 block-mainland.sh update
bm_auto_update_enable() {   # <daily|weekly>
    local when="${1:-daily}" cal
    case "$when" in
        daily) cal="*-*-* 04:30:00" ;;
        weekly) cal="Mon *-*-* 04:30:00" ;;
        *) ui_err "只支持 daily 或 weekly"; return 1 ;;
    esac
    [ -x "$BM_SELF" ] || { ui_err "没有 ${BM_SELF}（定时任务要运行它）"; return 1; }
    rm -f "$BM_OLD_CRON"
    case "$(ss_init)" in
        systemd)
            cat > "$BM_TIMER_SVC" <<EOF
[Unit]
Description=Update the mainland China IP lists for block-mainland

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'bash ${BM_SELF} update >> ${BM_UPDATE_LOG} 2>&1'
EOF
            cat > "$BM_TIMER" <<EOF
[Unit]
Description=Update the mainland China IP lists (${when})

[Timer]
OnCalendar=${cal}
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload
            systemctl enable --now block-mainland-update.timer >/dev/null 2>&1
            ;;
        openrc)
            rm -f "/etc/periodic/daily/$BM_PERIODIC_NAME" "/etc/periodic/weekly/$BM_PERIODIC_NAME"
            mkdir -p "/etc/periodic/$when"
            printf '#!/bin/sh\nbash %s update >> %s 2>&1\n' "$BM_SELF" "$BM_UPDATE_LOG" > "/etc/periodic/$when/$BM_PERIODIC_NAME"
            chmod 755 "/etc/periodic/$when/$BM_PERIODIC_NAME"
            # Alpine 的 crond 跑 /etc/periodic，确认它开着
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || true
            ;;
        *) ui_err "没有 systemd 或 OpenRC，无法定时。"; return 1 ;;
    esac
    ui_ok "已开启定时更新（$( [ "$when" = daily ] && echo 每天 || echo 每周一 ) 04:30），日志：${BM_UPDATE_LOG}"
}

bm_auto_update_disable() {
    if [ -f "$BM_TIMER" ]; then
        systemctl disable --now block-mainland-update.timer >/dev/null 2>&1 || true
        rm -f "$BM_TIMER" "$BM_TIMER_SVC"; systemctl daemon-reload
    fi
    rm -f "/etc/periodic/daily/$BM_PERIODIC_NAME" "/etc/periodic/weekly/$BM_PERIODIC_NAME" "$BM_OLD_CRON"
    ui_ok "已关闭定时更新"
}

bm_auto_update_state() {
    if [ -f "$BM_TIMER" ]; then
        if grep -q '^OnCalendar=Mon' "$BM_TIMER"; then echo "每周一 04:30（systemd 定时器）"; else echo "每天 04:30（systemd 定时器）"; fi
    elif [ -f "/etc/periodic/daily/$BM_PERIODIC_NAME" ]; then echo "每天（/etc/periodic/daily）"
    elif [ -f "/etc/periodic/weekly/$BM_PERIODIC_NAME" ]; then echo "每周（/etc/periodic/weekly）"
    elif [ -f "$BM_OLD_CRON" ]; then echo "旧版的 cron 任务（重新开启会换成定时器）"
    else echo "未开启"; fi
}


# 定时更新要运行本脚本：在用的是文件就用它，否则（bash <(curl …) 时）放一份到 /usr/local/bin
bm_self() {
    if [ -f "$0" ] && head -n 5 "$0" | grep -q 'block-mainland'; then
        BM_SELF=$(readlink -f "$0")
    elif [ ! -x "$BM_SELF" ]; then
        fetch_verified_script "${SS_RAW_BASE}/block-mainland.sh" "$BM_SELF" >/dev/null 2>&1 && chmod 755 "$BM_SELF"
    fi
}

# 旧版把含 ipset 引用的规则存进了 /etc/iptables/rules.v4：开机时集合还不存在，
# netfilter-persistent 整个恢复都会失败。只删掉这些行，文件里别的规则不动。
bm_clean_saved_rules() {
    local f
    for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
        [ -f "$f" ] && grep -q 'mainland_cn' "$f" && sed -i '/mainland_cn/d' "$f"
    done
    return 0
}

bm_enable() {
    bm_deps || return 1
    bm_download || return 1
    bm_write_rules
    if ! sh "$BM_RULES"; then
        ui_err "规则没下成功（容器里需要 NET_ADMIN 权限，内核要有 ip_set 模块）。"
        return 1
    fi
    bm_clean_saved_rules
    bm_boot_enable
    ui_ok "已屏蔽中国大陆来源的连接（端口：$(bm_ports | tr '\n' ' ')），开机自动恢复"
}

bm_disable() {
    if [ -f "$BM_RULES" ]; then
        sh "$BM_RULES" stop
    else
        # 没有规则脚本（旧版或手动删了）：直接删
        local r i=0
        while [ $i -lt 200 ] && r=$(iptables-save 2>/dev/null | grep -m1 -- "-A INPUT .*--match-set mainland_cn_src src") && [ -n "$r" ]; do
            # shellcheck disable=SC2086
            iptables -D INPUT ${r#-A INPUT } 2>/dev/null || break; i=$((i + 1))
        done
        ipset destroy mainland_cn_src 2>/dev/null
    fi
    bm_boot_disable
    bm_clean_saved_rules
    ui_ok "已停用屏蔽（开机也不再恢复）"
}

# 更新 IP 库：屏蔽开着就按新库重下规则；没开就只更新文件（不会替你开）
bm_update() {
    bm_deps || return 1
    bm_download || return 1
    if bm_active; then
        bm_write_rules
        sh "$BM_RULES" && ui_ok "已按新的 IP 库重下规则"
    else
        ui_info "屏蔽没有开，只更新了 IP 库。"
    fi
}

bm_menu() {
    local c s
    while true; do
        ui_sub "屏蔽中国大陆的连接：$(bm_active && echo 已启用 || echo 未启用)" \
            "下载 IP 库并启用" "停用" "更新 IP 库" "查看状态" "定时更新 IP 库" "关闭定时更新"
        ui_read c || return 0
        case "$c" in
            1) bm_enable; bm_status ;;
            2) bm_disable ;;
            3) bm_update ;;
            4) bm_status ;;
            5) ui_read s "每天还是每周？[daily/weekly]（回车 daily）: " || continue
               bm_self; bm_auto_update_enable "${s:-daily}" ;;
            6) bm_auto_update_disable ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}

check_root
case "${1:-}" in
    enable) bm_enable && bm_status ;;
    disable) bm_disable ;;
    update) bm_update ;;
    status) bm_status ;;
    auto-update-enable) bm_self; bm_auto_update_enable "${2:-daily}" ;;
    auto-update-disable) bm_auto_update_disable ;;
    auto-update-status) echo "定时更新：$(bm_auto_update_state)" ;;
    "") bm_menu ;;
    *) echo "用法: $0 [enable|disable|update|status|auto-update-enable [daily|weekly]|auto-update-disable|auto-update-status]"; exit 1 ;;
esac
