#!/usr/bin/env bash
# 此文件由 tools/build.sh 从 src/ss-2022.sh 和 src/lib 生成：请修改 src/ 下的文件后重新生成。
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

# ── lib/firewall.sh ───────────────────────────────────────────────────────────
# 开放 / 关闭端口：firewalld、ufw、iptables + ip6tables、nftables，系统在用哪个就配哪个，
# 并持久化。所有脚本共用这一份（以前各脚本各有一份，CentOS 版才认 firewalld、
# Docker 版只开 TCP、重复安装会叠加重复规则）。POSIX sh。

# firewalld 正在运行
_fw_firewalld_active() {
    command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1
}

# ufw 已启用（-w：不把 inactive 当成 active）
_fw_ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"
}

# both | tcp | udp → 协议列表
_fw_protos() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        *) echo "tcp udp" ;;
    esac
}

# iptables 规则持久化：Debian 的 /etc/iptables、RHEL 的 iptables-services、Alpine 的 init 脚本
_fw_iptables_save() {
    if [ -x /etc/init.d/iptables ] && command -v rc-update >/dev/null 2>&1; then
        /etc/init.d/iptables save >/dev/null 2>&1 || true
        rc-update add iptables boot >/dev/null 2>&1 || true
        if [ -x /etc/init.d/ip6tables ]; then
            /etc/init.d/ip6tables save >/dev/null 2>&1 || true
            rc-update add ip6tables boot >/dev/null 2>&1 || true
        fi
    elif [ -f /etc/sysconfig/iptables ]; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
        [ -f /etc/sysconfig/ip6tables ] && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

# iptables / ip6tables：没有同样的规则才插入
_fw_iptables_open() {   # <port> <protos>
    _fio_changed=false
    for _fio_t in iptables ip6tables; do
        command -v "$_fio_t" >/dev/null 2>&1 || continue
        "$_fio_t" -L INPUT -n >/dev/null 2>&1 || continue   # 内核或容器里不可用
        for _fio_p in $2; do
            if ! "$_fio_t" -C INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null; then
                "$_fio_t" -I INPUT -p "$_fio_p" --dport "$1" -j ACCEPT 2>/dev/null && _fio_changed=true
            fi
        done
    done
    if [ "$_fio_changed" = true ]; then
        printf '%b\n' "${CYAN}在 iptables 中开放端口 $1${RESET}"
        _fw_iptables_save
    fi
}

_fw_iptables_close() {   # <port>
    _fic_changed=false
    for _fic_t in iptables ip6tables; do
        command -v "$_fic_t" >/dev/null 2>&1 || continue
        for _fic_p in tcp udp; do
            while "$_fic_t" -C INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null; do
                "$_fic_t" -D INPUT -p "$_fic_p" --dport "$1" -j ACCEPT 2>/dev/null || break
                _fic_changed=true
            done
        done
    done
    [ "$_fic_changed" = true ] && _fw_iptables_save
    return 0
}

# 保存 nftables 规则（有持久化配置文件时）
save_nftables_rules() {
    command -v nft >/dev/null 2>&1 || return 0
    for _snr_f in /etc/nftables.conf /etc/sysconfig/nftables.conf /etc/nftables.nft; do
        [ -f "$_snr_f" ] || continue
        nft list ruleset > "$_snr_f" 2>/dev/null || true
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables >/dev/null 2>&1 || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nftables boot >/dev/null 2>&1 || true
        fi
        printf '%b\n' "${GREEN}nftables 规则已保存${RESET}"
        return 0
    done
    return 0
}

# nftables 里 hook 在 input 上的 filter 链（"族 表 链" 每行一条）。
# iptables-nft 自己的 ip/ip6 filter 表已由 iptables 处理，跳过，免得规则重复。
_fw_nft_input_chains() {
    nft -a list ruleset 2>/dev/null | awk -v skip_ipt="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain); in_chain = 1; next }
        in_chain && /type filter/ && /hook input/ {
            if (!(skip_ipt == "1" && (family == "ip" || family == "ip6") && table == "filter")) print family " " table " " chain
        }
        in_chain && /^[[:space:]]*}/ { in_chain = 0 }
    '
}

# 在 nftables 现有的 input 链里放行端口（没有 nftables 防火墙时什么都不做）
open_nftables_port() {   # <port> [both|tcp|udp]
    command -v nft >/dev/null 2>&1 || return 0
    _onp_skip=0
    command -v iptables >/dev/null 2>&1 && _onp_skip=1
    _onp_chains=$(_fw_nft_input_chains "$_onp_skip")
    [ -n "$_onp_chains" ] || return 0
    _onp_changed=false
    _onp_protos=$(_fw_protos "${2:-both}")
    while read -r _onp_family _onp_table _onp_chain; do
        [ -n "$_onp_family" ] || continue
        for _onp_p in $_onp_protos; do
            if ! nft list chain "$_onp_family" "$_onp_table" "$_onp_chain" 2>/dev/null | grep -q "$_onp_p dport $1 .*accept"; then
                nft insert rule "$_onp_family" "$_onp_table" "$_onp_chain" "$_onp_p" dport "$1" accept 2>/dev/null && _onp_changed=true
            fi
        done
    done <<EOF
$_onp_chains
EOF
    if [ "$_onp_changed" = true ]; then
        printf '%b\n' "${CYAN}在 nftables 中开放端口 $1${RESET}"
        save_nftables_rules
    fi
}

# 删掉 nftables 里放行该端口的规则
close_nftables_port() {   # <port>
    command -v nft >/dev/null 2>&1 || return 0
    _cnp_rules=$(nft -a list ruleset 2>/dev/null | awk -v port="$1" '
        $1 == "table" { family = $2; table = $3; gsub(/[{}]/, "", table) }
        $1 == "chain" { chain = $2; gsub(/[{}]/, "", chain) }
        ($0 ~ "(tcp|udp) dport " port " .*accept") && /# handle/ { print family " " table " " chain " " $NF }
    ')
    [ -n "$_cnp_rules" ] || return 0
    while read -r _cnp_family _cnp_table _cnp_chain _cnp_handle; do
        [ -n "$_cnp_handle" ] || continue
        nft delete rule "$_cnp_family" "$_cnp_table" "$_cnp_chain" handle "$_cnp_handle" 2>/dev/null || true
    done <<EOF
$_cnp_rules
EOF
    save_nftables_rules
}

# 开放端口：firewalld 在运行就只交给它；ufw 已启用就只交给它；否则配 iptables 与 nftables
open_port() {   # <port> [both|tcp|udp]
    _op_protos=$(_fw_protos "${2:-both}")
    if _fw_firewalld_active; then
        printf '%b\n' "${CYAN}在 firewalld 中开放端口 $1${RESET}"
        for _op_p in $_op_protos; do
            firewall-cmd --permanent --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
            firewall-cmd --add-port="$1/${_op_p}" >/dev/null 2>&1 || true
        done
        return 0
    fi
    # ufw 装了但没启用时也写进去：以后启用 ufw 时端口仍是开的
    if command -v ufw >/dev/null 2>&1; then
        printf '%b\n' "${CYAN}在 UFW 中开放端口 $1${RESET}"
        for _op_p in $_op_protos; do
            ufw allow "$1/${_op_p}" >/dev/null 2>&1 || true
        done
        _fw_ufw_active && return 0
    fi
    _fw_iptables_open "$1" "$_op_protos"
    open_nftables_port "$1" "${2:-both}"
    return 0
}

# 关闭端口：各个防火墙里放行它的规则都删掉
close_port() {   # <port>
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for _cp_p in tcp udp; do
            firewall-cmd --permanent --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
            firewall-cmd --remove-port="$1/${_cp_p}" >/dev/null 2>&1 || true
        done
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$1/tcp" >/dev/null 2>&1 || true
        ufw delete allow "$1/udp" >/dev/null 2>&1 || true
        ufw delete allow "$1" >/dev/null 2>&1 || true
    fi
    _fw_iptables_close "$1"
    close_nftables_port "$1"
    return 0
}

# 端口在当前防火墙里是否放行（测试与状态显示用）：firewalld / ufw / iptables / nftables 任一处放行即算
port_allowed() {   # <port> <tcp|udp>
    if _fw_firewalld_active; then
        firewall-cmd --query-port="$1/$2" >/dev/null 2>&1
        return
    fi
    if _fw_ufw_active; then
        ufw status 2>/dev/null | grep -Eq "^$1(/$2)?[[:space:]]+ALLOW"
        return
    fi
    if command -v iptables >/dev/null 2>&1 && iptables -C INPUT -p "$2" --dport "$1" -j ACCEPT 2>/dev/null; then
        return 0
    fi
    command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "$2 dport $1 .*accept"
}

# 端口是否有进程在监听（TCP 或 UDP）
is_port_in_use() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        ss -H -lun "( sport = :$1 )" 2>/dev/null | grep -q . && return 0
        return 1
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        lsof -nP -iUDP:"$1" >/dev/null 2>&1
        return
    fi
    return 1
}

# 显示占用指定端口的进程
show_port_occupier() {   # <port>
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        ss -lunp "( sport = :$1 )" 2>/dev/null | sed 's/^/  /'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /'
        lsof -nP -iUDP:"$1" 2>/dev/null | sed 's/^/  /'
    fi
}

# ── lib/netinfo.sh ────────────────────────────────────────────────────────────
# 本机公网地址与所在国家（生成客户端配置时用）。POSIX sh。

# 本机公网 IPv4 / IPv6（取不到时为空）
get_public_ipv4() { curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null; }
get_public_ipv6() { curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null; }

# 查询 IP 所属国家代码（多接口回退，避免单一接口限流返回错误信息）
get_ip_country() {
    local target="$1"
    local api=""
    local raw=""
    local result=""

    if [ -z "$target" ]; then
        echo "Unknown"
        return 1
    fi

    for api in "https://ipinfo.io/${target}/country" \
               "http://ip-api.com/line/${target}?fields=countryCode" \
               "https://ipwho.is/${target}?fields=country_code" \
               "https://ipapi.co/${target}/country/"; do
        raw=$(curl -s --connect-timeout 5 --max-time 10 "$api" 2>/dev/null)
        result=$(echo "$raw" | tr -d ' \t\r\n')
        case "$result" in
            [A-Za-z][A-Za-z]) ;;
            *) result=$(echo "$raw" | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1) ;;
        esac
        case "$result" in
            [A-Za-z][A-Za-z])
                echo "$result" | tr '[:lower:]' '[:upper:]'
                return 0
                ;;
        esac
    done

    echo "Unknown"
    return 1
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

# ── lib/ss-release.sh ─────────────────────────────────────────────────────────
# shadowsocks-rust 的发布版：查最新版本、按 CPU 选包、下载并核对官方的 SHA-256 后安装。
# 用静态链接的 musl 版：不依赖系统的 glibc，Alpine 与老系统都能跑。bash。

SS_REPO="shadowsocks/shadowsocks-rust"
SS_FALLBACK_VERSION="1.25.0"   # 查不到最新版本时（GitHub API 限流等）用它

# 本机对应的发布包名里的平台部分
ss_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7|armv8l) echo "armv7-unknown-linux-musleabihf" ;;
        armv6l) echo "arm-unknown-linux-musleabihf" ;;
        i686|i386) echo "i686-unknown-linux-musl" ;;
        riscv64) echo "riscv64gc-unknown-linux-musl" ;;
        loongarch64) echo "loongarch64-unknown-linux-musl" ;;
        *) return 1 ;;
    esac
}

# 最新的正式版（不带 v）。先问 API，限流时看 releases/latest 跳到哪个标签
ss_latest_version() {
    local v
    v=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${SS_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    [ -n "$v" ] || v=$(curl -fsSI --max-time 15 -o /dev/null -w '%{redirect_url}' "https://github.com/${SS_REPO}/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p')
    v=${v#v}
    case "$v" in
        [0-9]*.[0-9]*.[0-9]*) echo "$v" ;;
        *) echo "$SS_FALLBACK_VERSION"; return 1 ;;
    esac
}

# 已装的版本：问二进制本身（ver.txt 只是记录）
ss_installed_version() {
    local v=""
    [ -x "$BINARY_PATH" ] && v=$("$BINARY_PATH" --version 2>/dev/null | awk '{print $2; exit}')
    [ -n "$v" ] || v=$(cat "$VERSION_FILE" 2>/dev/null)
    echo "${v#v}"
}

# a < b（x.y.z，逐段按数字比）
ss_version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
            if ((x[i] + 0) < (y[i] + 0)) exit 0
            if ((x[i] + 0) > (y[i] + 0)) exit 1
        }
        exit 1
    }'
}

# 下载、核对、安装：成功后 BINARY_PATH 是新的 ssserver
ss_install_binary() {   # <版本，不带 v>
    local ver="$1" target f url tmp
    if ! target=$(ss_target); then
        ui_err "不支持的 CPU 架构：$(uname -m)"
        return 1
    fi
    f="shadowsocks-v${ver}.${target}.tar.xz"
    url="https://github.com/${SS_REPO}/releases/download/v${ver}/${f}"
    tmp=$(mktemp -d) || return 1
    ui_info "下载 shadowsocks-rust ${ver}（${target}）…"
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$tmp/$f" "$url" \
        || ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$tmp/$f.sha256" "$url.sha256"; then
        ui_err "下载失败：$url"
        rm -rf "$tmp"; return 1
    fi
    if ! (cd "$tmp" && sha256sum -c "$f.sha256" >/dev/null 2>&1); then
        ui_err "下载的文件与官方的 SHA-256 不符，已丢弃。"
        rm -rf "$tmp"; return 1
    fi
    if ! xz -dc "$tmp/$f" | tar -xf - -C "$tmp" || [ ! -f "$tmp/ssserver" ]; then
        ui_err "解压失败，或包里没有 ssserver。"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$(dirname "$BINARY_PATH")" "$INSTALL_DIR"
    cp "$tmp/ssserver" "${BINARY_PATH}.new" && chmod 755 "${BINARY_PATH}.new"
    if ! "${BINARY_PATH}.new" --version >/dev/null 2>&1; then
        ui_err "新的 ssserver 在这台机器上运行不了。"
        rm -f "${BINARY_PATH}.new"; rm -rf "$tmp"; return 1
    fi
    mv -f "${BINARY_PATH}.new" "$BINARY_PATH"
    echo "$ver" > "$VERSION_FILE"
    rm -rf "$tmp"
    ui_ok "shadowsocks-rust ${ver} 已安装（SHA-256 核对无误）"
}

# ── lib/ss-config.sh ──────────────────────────────────────────────────────────
# 配置文件：加密方式与密钥、读写（jq，改哪项只动哪项，别的键原样留着）、单端口多用户的运行配置。
#
# /etc/ss-rust/config.json 一直是单服务器的格式（server / server_port / method / password …），
# PSM、ShadowTLS 脚本、大陆屏蔽都按这个格式读端口与密钥。单端口多用户（EIH）的用户也记在它的
# users 里；但 ssserver 只在 servers 数组里认 users（单服务器格式里会被忽略），所以有用户时
# 另外生成 config-eih.json（servers 格式）给主服务跑。bash。

CONFIG_EIH="${INSTALL_DIR}/config-eih.json"

# 菜单里的加密方式（第一个是默认）。2022-blake3-chacha8-poly1305 官方发布版不支持，不列；
# 流加密（rc4-md5、aes-*-cfb 等）不安全，也不列（已经在用的配置照常能跑）。
SS_METHODS=(
    "2022-blake3-aes-128-gcm"
    "2022-blake3-aes-256-gcm"
    "2022-blake3-chacha20-poly1305"
    "aes-128-gcm"
    "aes-256-gcm"
    "chacha20-ietf-poly1305"
)

# 2022 系列的密钥是固定长度的随机字节（Base64），其余方式是任意密码
ss_key_len() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|2022-blake3-chacha8-poly1305) echo 32 ;;
    esac
}
ss_is_2022() { case "$1" in 2022-blake3-*) return 0 ;; esac; return 1; }
# 单端口多用户（Extensible Identity Header）只有 AES 的 2022 方式支持（ssserver 会拒绝 chacha20）
ss_eih_capable() { case "$1" in 2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) return 0 ;; esac; return 1; }

ss_gen_key() {   # <加密方式>
    local n; n=$(ss_key_len "$1")
    head -c "${n:-16}" /dev/urandom | base64 | tr -d '\n'
}

# 密钥是否可用：2022 系列要解码后正好是规定的字节数
ss_key_ok() {   # <加密方式> <密钥>
    local n; n=$(ss_key_len "$1")
    [ -n "$2" ] || return 1
    case "$2" in *[[:space:]\"\\:]*) return 1 ;; esac
    [ -z "$n" ] && return 0
    [ "$(printf '%s' "$2" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "$n" ]
}

# 读一项（没有时为空）：ss_cfg <文件> <jq 路径>
ss_cfg() { jq -r "($2) // empty" "$1" 2>/dev/null; }

# 改一项：ss_cfg_set <文件> <jq 程序> [jq 参数…]；先写临时文件再换上，权限 600
ss_cfg_set() {
    local f="$1" prog="$2" t
    shift 2
    t=$(mktemp "${f}.XXXXXX") || return 1
    if jq "$@" "$prog" "$f" > "$t" 2>/dev/null; then
        chmod 600 "$t" && mv -f "$t" "$f"
    else
        rm -f "$t"
        ui_err "写配置失败：$f"
        return 1
    fi
}

# 监听地址。纯 IPv6 的机器只能 ::；有 IPv6、且 :: 也收 IPv4（bindv6only=0）时 ::，双栈；
# 否则 0.0.0.0。用 obfs 插件时有 IPv4 就 0.0.0.0：ssserver 带插件监听 :: 时会丢掉 IPv4
# （shadowsocks-rust issue #694）
ss_listen_addr() {   # [插件]
    local v4=0 v6=0
    [ -f /proc/net/if_inet6 ] && v6=1
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && v4=1
    command -v ip >/dev/null 2>&1 || v4=1
    if [ "$v4" = 0 ] && [ "$v6" = 1 ]; then echo "::"; return; fi
    [ -n "${1:-}" ] && { echo "0.0.0.0"; return; }
    if [ "$v6" = 1 ] && [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null)" != "1" ]; then echo "::"; else echo "0.0.0.0"; fi
}

# 新配置文件：<文件> <端口> <加密方式> <密钥> <TFO true|false> <DNS> <插件> <插件参数>
ss_new_config() {
    mkdir -p "$(dirname "$1")"
    jq -n --arg server "$(ss_listen_addr "$7")" --argjson port "$2" --arg method "$3" --arg password "$4" \
        --argjson tfo "$5" --arg dns "$6" --arg plugin "$7" --arg opts "$8" \
        '{server: $server, server_port: $port, method: $method, password: $password,
          fast_open: $tfo, mode: "tcp_and_udp", timeout: 300}
         + (if $dns != "" then {nameserver: $dns} else {} end)
         + (if $plugin != "" then {plugin: $plugin, plugin_opts: $opts} else {} end)' > "$1.tmp" \
        && chmod 600 "$1.tmp" && mv -f "$1.tmp" "$1"
}

ss_users_count() { jq '(.users // []) | length' "$CONFIG_PATH" 2>/dev/null || echo 0; }

# 有用户时主服务跑的配置：servers 数组里放这台服务器（含 users 与各服务器自己的选项），
# 其余的键（DNS、TFO、日志等全局设置）放在外层
ss_render_eih() {
    local t
    t=$(mktemp "${CONFIG_EIH}.XXXXXX") || return 1
    if jq '["server","server_port","method","password","users","mode","timeout","plugin","plugin_opts",
            "outbound_proxy","inbound_udp_allow_fragmentation","outbound_udp_allow_fragmentation"] as $per
           | . as $c
           | {servers: [$c | with_entries(select(.key as $k | $per | index($k)))]}
             + ($c | with_entries(select(.key as $k | ($per | index($k)) | not)))' "$CONFIG_PATH" > "$t"; then
        chmod 600 "$t" && mv -f "$t" "$CONFIG_EIH"
    else
        rm -f "$t"; return 1
    fi
}

# 让主服务按现在的配置跑：有用户跑 config-eih.json，没有就跑 config.json；然后重启并确认
ss_apply_main() {
    local want="$CONFIG_PATH"
    if [ "$(ss_users_count)" -gt 0 ]; then
        ss_render_eih || { ui_err "生成多用户配置失败"; return 1; }
        want="$CONFIG_EIH"
    else
        rm -f "$CONFIG_EIH"
    fi
    if [ "$(ss_svc_conf ss-rust)" != "$want" ]; then
        ss_write_service ss-rust "$want" "Shadowsocks Rust Service" || return 1
        ss_svc_enable ss-rust
    fi
    ss_svc_restart_verify ss-rust
}

# 全部配置文件（主配置与每个额外端口的）
ss_all_configs() {
    local f
    [ -f "$CONFIG_PATH" ] && echo "$CONFIG_PATH"
    for f in "${PORTS_DIR}"/*.json; do [ -f "$f" ] && echo "$f"; done
}

# 改了全局的设置（出口代理、日志、分片）后，主服务与每个额外端口都重启
ss_apply_all() {
    local f p rc=0
    ss_apply_main || rc=1
    for f in "${PORTS_DIR}"/*.json; do
        [ -f "$f" ] || continue
        p=$(basename "$f" .json)
        ss_svc_restart_verify "ss-rust-$p" || rc=1
    done
    return $rc
}

ss_port_ok() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

ss_random_port() {
    local p i
    for i in $(seq 1 30); do
        p=$(( (RANDOM << 15 | RANDOM) % 55536 + 10000 ))
        is_port_in_use "$p" || { echo "$p"; return 0; }
    done
    echo "$p"
}

# 本脚本已经用了的端口（主端口与额外端口）
ss_port_taken_by_us() {   # <端口>
    [ "$(ss_cfg "$CONFIG_PATH" .server_port)" = "$1" ] || [ -f "${PORTS_DIR}/$1.json" ]
}

# ── 交互：问端口、加密方式、密钥、TFO、DNS、插件；结果放在 ASK ──────────────
ASK=""
ss_ask_port() {   # [现在的端口]
    local def cur="${1:-}" p
    def=$(ss_random_port)
    while true; do
        ui_read p "端口 [1-65535]（回车用随机端口 ${def}）: " || return 1
        p=${p:-$def}
        if ! ss_port_ok "$p"; then ui_err "端口要是 1-65535 的数字"; continue; fi
        if [ "$p" != "$cur" ] && is_port_in_use "$p"; then
            ui_err "端口 $p 已经被占用："; show_port_occupier "$p"; continue
        fi
        if [ "$p" != "$cur" ] && ss_port_taken_by_us "$p"; then ui_err "端口 $p 已经是本脚本的节点"; continue; fi
        ASK="$p"; return 0
    done
}

ss_ask_method() {   # [现在的方式]
    local i c
    echo
    for i in "${!SS_METHODS[@]}"; do
        printf "  ${CYAN}%2d.${RESET} %s%s\n" $((i + 1)) "${SS_METHODS[$i]}" "$([ "$i" = 0 ] && echo "（默认，推荐）")"
    done
    while true; do
        ui_read c "加密方式 [1-${#SS_METHODS[@]}]（回车 1）: " || return 1
        c=${c:-1}
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#SS_METHODS[@]}" ]; then
            ASK="${SS_METHODS[$((c - 1))]}"; return 0
        fi
        ui_err "请输入 1-${#SS_METHODS[@]}"
    done
}

ss_ask_key() {   # <加密方式>
    local k n
    n=$(ss_key_len "$1")
    [ -n "$n" ] && ui_info "$1 的密钥是 ${n} 字节的随机数（Base64），建议直接回车生成。"
    while true; do
        ui_read k "密码 / 密钥（回车随机生成）: " || return 1
        [ -z "$k" ] && k=$(ss_gen_key "$1")
        if ss_key_ok "$1" "$k"; then ASK="$k"; return 0; fi
        if [ -n "$n" ]; then ui_err "要是 ${n} 字节密钥的 Base64；直接回车可自动生成"; else ui_err "密码不能为空，也不能有空格、引号、反斜杠或冒号"; fi
    done
}

ss_ask_tfo() {
    if ui_yes "开启 TCP Fast Open（TFO）？" y; then ASK=true; else ASK=false; fi
}

ss_ask_dns() {
    local d
    while true; do
        ui_read d "DNS（回车用系统的；多个用逗号分开，如 1.1.1.1,8.8.8.8）: " || return 1
        if [ -z "$d" ] || [[ "$d" =~ ^[0-9a-fA-F.:]+(,[0-9a-fA-F.:]+)*$ ]]; then ASK="$d"; return 0; fi
        ui_err "只能填 IP 地址，多个用逗号分开"
    done
}

# 混淆插件（simple-obfs）：结果放在 ASK_PLUGIN、ASK_PLUGIN_OPTS
ASK_PLUGIN=""; ASK_PLUGIN_OPTS=""
ss_ask_plugin() {
    local c
    echo -e "  ${CYAN} 1.${RESET} 不用插件（默认；2022 系列加密本身就够了）"
    echo -e "  ${CYAN} 2.${RESET} simple-obfs（http 混淆）"
    echo -e "  ${CYAN} 3.${RESET} simple-obfs（tls 混淆）"
    ui_read c "混淆插件 [1-3]（回车 1）: " || return 1
    ASK_PLUGIN=""; ASK_PLUGIN_OPTS=""
    case "${c:-1}" in
        2) ASK_PLUGIN="obfs-server"; ASK_PLUGIN_OPTS="obfs=http" ;;
        3) ASK_PLUGIN="obfs-server"; ASK_PLUGIN_OPTS="obfs=tls" ;;
    esac
    if [ -n "$ASK_PLUGIN" ] && ! ss_install_obfs; then
        ui_warn "混淆插件用不了，这次不开。"
        ASK_PLUGIN=""; ASK_PLUGIN_OPTS=""
    fi
    return 0
}

# ── lib/ss-system.sh ──────────────────────────────────────────────────────────
# 依赖、时间同步、混淆插件、管理命令（ssrust）、运行别的脚本。bash。

# 装依赖：Debian / Ubuntu、RHEL 系、Alpine 都用各自的包名
ss_install_deps() {
    detect_os
    ui_info "检查依赖…"
    ensure_cmds curl jq tar ip ss || { ui_err "依赖安装失败，请检查软件源。"; return 1; }
    # xz 在 Debian / Ubuntu 叫 xz-utils
    if ! command -v xz >/dev/null 2>&1; then
        if [ "$PKG" = apt ]; then pkg_install xz-utils; else pkg_install xz; fi
        command -v xz >/dev/null 2>&1 || { ui_err "没装上 xz（解压发布包要用）"; return 1; }
    fi
    # 二维码可有可无；RHEL 系要 EPEL，Alpine 的包名是 libqrencode-tools
    if ! command -v qrencode >/dev/null 2>&1; then
        case "$OS_FAMILY" in
            alpine) pkg_install libqrencode-tools >/dev/null 2>&1 ;;
            rhel) pkg_install epel-release >/dev/null 2>&1; pkg_install qrencode >/dev/null 2>&1 ;;
            *) pkg_install qrencode >/dev/null 2>&1 ;;
        esac
        command -v qrencode >/dev/null 2>&1 || ui_warn "没装上 qrencode，查看配置时不显示二维码（不影响使用）。"
    fi
    return 0
}

# 时间同步：2022 系列加密校验时间戳，服务器与客户端差 30 秒以上就连不上。
# 只开 NTP，不改时区（时区与时间戳无关）。
ss_ensure_time_sync() {
    detect_os
    if [ "$(ss_init)" = systemd ]; then
        local s
        for s in chronyd chrony systemd-timesyncd ntp ntpd; do
            systemctl is-active --quiet "$s" 2>/dev/null && return 0
        done
        if systemctl list-unit-files systemd-timesyncd.service 2>/dev/null | grep -q timesyncd \
            && { timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd >/dev/null 2>&1; }; then
            ui_ok "已开启时间同步（systemd-timesyncd）"; return 0
        fi
        pkg_install chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1 || true
        if systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
            ui_ok "已开启时间同步（chrony）"; return 0
        fi
    elif [ "$(ss_init)" = openrc ]; then
        rc-service chronyd status >/dev/null 2>&1 || rc-service ntpd status >/dev/null 2>&1 && return 0
        pkg_install chrony >/dev/null 2>&1 || true
        rc-update add chronyd default >/dev/null 2>&1 || true
        if rc-service chronyd start >/dev/null 2>&1; then ui_ok "已开启时间同步（chrony）"; return 0; fi
    fi
    ui_warn "没能自动开启时间同步。用 2022 系列加密时客户端连不上，先检查服务器时间是否准确。"
    return 0
}

# simple-obfs 的服务端（obfs-server）：只有 Debian / Ubuntu 的官方源里有
ss_install_obfs() {
    command -v obfs-server >/dev/null 2>&1 && return 0
    detect_os
    if [ "$PKG" != apt ]; then
        ui_warn "这个系统的官方源里没有 simple-obfs（只有 Debian / Ubuntu 有），请自行编译 obfs-server 后再开。"
        return 1
    fi
    ui_info "安装 simple-obfs…"
    pkg_install simple-obfs >/dev/null 2>&1
    command -v obfs-server >/dev/null 2>&1 || { ui_warn "simple-obfs 安装失败"; return 1; }
}

# 管理命令：ssrust 每次运行都取最新的脚本（ss.jinqians.com），取不到时用本机保存的那份
# （/usr/local/bin/ss-2022.sh，旧版的 ssrust 是指向它的链接）
ss_write_command() {
    mkdir -p /usr/local/bin
    rm -f /usr/local/bin/ssrust
    cat > /usr/local/bin/ssrust <<EOF
#!/usr/bin/env bash
# Shadowsocks Rust 管理命令（ss-2022 写的）：运行最新的管理脚本，取不到时用本机的那份
[ "\$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
tmp=\$(mktemp)
if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "${SS_SCRIPT_URL}" -o "\$tmp" 2>/dev/null \\
    && [ -s "\$tmp" ] && bash -n "\$tmp" 2>/dev/null; then
    cp "\$tmp" /usr/local/bin/ss-2022.sh && chmod 755 /usr/local/bin/ss-2022.sh
    bash "\$tmp" "\$@"; rc=\$?
    rm -f "\$tmp"; exit \$rc
fi
rm -f "\$tmp"
echo "取不到最新的脚本，运行本机保存的版本。"
exec bash /usr/local/bin/ss-2022.sh "\$@"
EOF
    chmod 755 /usr/local/bin/ssrust
    # 本机留一份：在用的脚本是文件就拷它，否则（bash <(curl …) 时）下载一份
    if [ -f "$0" ] && [ -s "$0" ] && head -n 3 "$0" | grep -q 'ss-2022'; then
        [ "$(readlink -f "$0")" = /usr/local/bin/ss-2022.sh ] || cp "$0" /usr/local/bin/ss-2022.sh
    else
        fetch_verified_script "$SS_SCRIPT_URL" /usr/local/bin/ss-2022.sh >/dev/null 2>&1 || true
    fi
    [ -f /usr/local/bin/ss-2022.sh ] && chmod 755 /usr/local/bin/ss-2022.sh
    return 0
}

# 下载、校验后运行一个脚本（ShadowTLS 管理等）
ss_run_remote() {   # <地址> <名称> [参数…]
    local url="$1" name="$2" tmp
    shift 2
    tmp=$(mktemp) || return 1
    if fetch_verified_script "$url" "$tmp"; then
        bash "$tmp" "$@"
    else
        ui_err "${name}下载校验失败，没有运行。"
    fi
    rm -f "$tmp"
}

# ── lib/ss-links.sh ───────────────────────────────────────────────────────────
# 查看配置：分享链接（SIP002）、二维码、Surge 配置行、ShadowTLS 组合、每个用户与额外端口的链接。bash。

OBFS_HOST="www.bing.com"   # 分享链接里 obfs 的伪装域名（http 的 Host / tls 的 SNI）
STLS_SS_UNIT="/etc/systemd/system/shadowtls-ss.service"

# SIP002 的 userinfo 用 URL 安全的 Base64、不带 =
ss_b64url() { printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

# 本机的公网地址（每次运行只查一次）。查到的不对时（NAT 的机器等）可以用 SS_SERVER_IP 指定
SS_IPV4=""; SS_IPV6=""; SS_IPS_DONE=""
ss_ips() {
    [ -n "$SS_IPS_DONE" ] && return 0
    SS_IPS_DONE=1
    if [ -n "${SS_SERVER_IP:-}" ]; then
        case "$SS_SERVER_IP" in *:*) SS_IPV6="$SS_SERVER_IP" ;; *) SS_IPV4="$SS_SERVER_IP" ;; esac
        return 0
    fi
    SS_IPV4=$(get_public_ipv4); SS_IPV6=$(get_public_ipv6)
    [[ "$SS_IPV4" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || SS_IPV4=""
    [[ "$SS_IPV6" == *:* ]] || SS_IPV6=""
}
ss_host() { case "$1" in *:*) echo "[$1]" ;; *) echo "$1" ;; esac; }

# SIP002 的插件参数（没有插件时为空）
ss_plugin_query() {   # <插件> <插件参数>
    [ -n "$1" ] || return 0
    local mode="${2#obfs=}"; mode="${mode%%;*}"
    echo "/?plugin=obfs-local%3Bobfs%3D${mode}%3Bobfs-host%3D${OBFS_HOST}"
}

ss_link() {   # <地址> <端口> <加密方式> <密码> <名字> [插件参数段]
    echo "ss://$(ss_b64url "$3:$4")@$(ss_host "$1"):$2${6:-}#$5"
}

ss_qr() { command -v qrencode >/dev/null 2>&1 && printf '%s' "$1" | qrencode -t UTF8; }

# ShadowTLS（shadowtls-ss）的监听端口、密码、SNI；没有装时返回 1
STLS_PORT=""; STLS_PW=""; STLS_SNI=""
ss_stls_info() {
    [ -f "$STLS_SS_UNIT" ] || return 1
    STLS_PORT=$(sed -n 's/.*--listen [^ ]*:\([0-9][0-9]*\).*/\1/p' "$STLS_SS_UNIT" | head -n 1)
    STLS_PW=$(sed -n 's/.*--password \([^ ][^ ]*\).*/\1/p' "$STLS_SS_UNIT" | head -n 1)
    STLS_SNI=$(sed -n 's/.*--tls \([^ ][^ ]*\).*/\1/p' "$STLS_SS_UNIT" | head -n 1)
    [ -n "$STLS_PORT" ] && [ -n "$STLS_PW" ] && [ -n "$STLS_SNI" ]
}

# SS + ShadowTLS 合并链接（Shadowrocket 的写法）
ss_stls_link() {   # <地址> <SS 端口> <加密方式> <密码> <名字>
    local j
    j=$(jq -cn --arg pw "$STLS_PW" --arg host "$STLS_SNI" --arg port "$STLS_PORT" --arg addr "$1" \
        '{version: "3", password: $pw, host: $host, port: $port, address: $addr}')
    echo "ss://$(ss_b64url "$3:$4")@$(ss_host "$1"):$2?shadow-tls=$(printf '%s' "$j" | base64 | tr -d '\n')#$5"
}

ss_kv() { echo -e "  $(ui_pad "$1" 9) ${GREEN}$2${RESET}"; }   # 按显示宽度对齐（中文占两格）

ss_view() {
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    local port method key tfo dns plugin opts pq ip users n i f uname ukey ob
    port=$(ss_cfg "$CONFIG_PATH" .server_port); method=$(ss_cfg "$CONFIG_PATH" .method)
    key=$(ss_cfg "$CONFIG_PATH" .password); tfo=$(ss_cfg "$CONFIG_PATH" '.fast_open // false')
    dns=$(ss_cfg "$CONFIG_PATH" .nameserver); plugin=$(ss_cfg "$CONFIG_PATH" .plugin); opts=$(ss_cfg "$CONFIG_PATH" .plugin_opts)
    ob=$(ss_cfg "$CONFIG_PATH" 'if (.outbound_proxy | type) == "array" then (.outbound_proxy | join(" → ")) else .outbound_proxy end')
    pq=$(ss_plugin_query "$plugin" "$opts")
    users=$(ss_users_count)
    ss_ips
    if [ -z "$SS_IPV4$SS_IPV6" ]; then ui_err "查不到本机的公网地址，没法生成链接。"; fi

    echo
    echo -e "${BOLD}${BLUE}── Shadowsocks Rust ──────────────────────────────${RESET}"
    [ -n "$SS_IPV4" ] && ss_kv "地址" "$SS_IPV4"
    [ -n "$SS_IPV6" ] && ss_kv "地址" "$SS_IPV6"
    ss_kv "端口" "$port"
    ss_kv "加密" "$method"
    ss_kv "密码" "$key"
    ss_kv "TFO" "$tfo"
    [ -n "$dns" ] && ss_kv "DNS" "$dns"
    [ -n "$plugin" ] && ss_kv "插件" "$plugin（$opts）"
    [ -n "$ob" ] && ss_kv "出口代理" "$ob（只有 TCP 经代理，UDP 直连）"

    if [ "$users" -gt 0 ]; then
        echo
        ui_warn "已开启单端口多用户（${users} 个用户）：只用上面这个服务器密钥的客户端连不上，每个人用自己的链接。"
        for (( i = 0; i < users; i++ )); do
            uname=$(jq -r ".users[$i].name" "$CONFIG_PATH"); ukey=$(jq -r ".users[$i].password" "$CONFIG_PATH")
            ss_user_links "$uname" "$ukey"
        done
    else
        echo -e "\n${YELLOW}── 分享链接 ──${RESET}"
        for ip in $SS_IPV4 $SS_IPV6; do
            echo "$(ss_link "$ip" "$port" "$method" "$key" "SS-$ip" "$pq")"
        done
        if command -v qrencode >/dev/null 2>&1 && [ -n "$SS_IPV4" ]; then
            echo -e "\n${YELLOW}── 二维码（IPv4）──${RESET}"
            ss_qr "$(ss_link "$SS_IPV4" "$port" "$method" "$key" "SS-$SS_IPV4" "$pq")"
        fi
        echo -e "\n${YELLOW}── Surge ──${RESET}"
        local obfs=""
        [ -n "$plugin" ] && obfs=", obfs=${opts#obfs=}, obfs-host=${OBFS_HOST}"
        for ip in $SS_IPV4 $SS_IPV6; do
            echo "SS-$ip = ss, $ip, $port, encrypt-method=$method, password=$key, tfo=$tfo, udp-relay=true$obfs"
        done
        if ss_stls_info; then
            echo -e "\n${YELLOW}── ShadowTLS（端口 ${STLS_PORT}，SNI ${STLS_SNI}）──${RESET}"
            for ip in $SS_IPV4; do
                echo "$(ss_stls_link "$ip" "$port" "$method" "$key" "SS-$ip")"
                echo "SS-$ip = ss, $ip, $STLS_PORT, encrypt-method=$method, password=$key, shadow-tls-password=$STLS_PW, shadow-tls-sni=$STLS_SNI, shadow-tls-version=3, udp-relay=true"
            done
        fi
    fi

    n=0
    for f in "${PORTS_DIR}"/*.json; do [ -f "$f" ] && n=$((n + 1)); done
    if [ "$n" -gt 0 ]; then
        echo -e "\n${YELLOW}── 额外端口（${n} 个）──${RESET}"
        ss_ports_links
    fi
    echo
}

# 一个用户的链接：客户端的密码是「服务器密钥:用户密钥」
ss_user_links() {   # <用户名> <用户密钥>
    local port method key plugin opts pq ip
    port=$(ss_cfg "$CONFIG_PATH" .server_port); method=$(ss_cfg "$CONFIG_PATH" .method); key=$(ss_cfg "$CONFIG_PATH" .password)
    plugin=$(ss_cfg "$CONFIG_PATH" .plugin); opts=$(ss_cfg "$CONFIG_PATH" .plugin_opts); pq=$(ss_plugin_query "$plugin" "$opts")
    ss_ips
    echo -e "\n${YELLOW}── 用户 $1 ──${RESET}"
    echo "  客户端密码：$key:$2"
    for ip in $SS_IPV4 $SS_IPV6; do
        echo "  $(ss_link "$ip" "$port" "$method" "$key:$2" "SS-$ip-$1" "$pq")"
    done
    if ss_stls_info && [ -n "$SS_IPV4" ]; then
        echo "  ShadowTLS：$(ss_stls_link "$SS_IPV4" "$port" "$method" "$key:$2" "SS-$SS_IPV4-$1")"
    fi
}

# ── lib/ss-users.sh ───────────────────────────────────────────────────────────
# 单端口多用户（shadowsocks-rust 1.25 的 Extensible Identity Header）：几个人共用一个端口，
# 各有各的密钥，可以单独删掉某个人。只支持 2022-blake3-aes-128-gcm / aes-256-gcm。
# 有用户时，只用服务器密钥的客户端会被拒绝；客户端的密码是「服务器密钥:用户密钥」。bash。

ss_user_name_ok() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; }
ss_user_exists() { jq -e --arg n "$1" 'any((.users // [])[]; .name == $n)' "$CONFIG_PATH" >/dev/null 2>&1; }

ss_user_add() {
    local method name key
    method=$(ss_cfg "$CONFIG_PATH" .method)
    if ! ss_eih_capable "$method"; then
        ui_err "单端口多用户只支持 2022-blake3-aes-128-gcm 与 2022-blake3-aes-256-gcm，现在是 ${method}。"
        ui_warn "要用的话，先在「修改配置 → 加密方式」里换成这两个之一（原来的链接会失效）。"
        return 1
    fi
    if [ "$(ss_users_count)" -eq 0 ]; then
        ui_warn "开启后，只用服务器密钥的客户端（现在的链接）会连不上，每个人改用自己的链接。"
        ui_warn "要继续用的设备，也给它加一个用户。删光所有用户就回到现在的样子。"
        ui_yes "开启单端口多用户？" n || { echo "已取消。"; return 0; }
    fi
    while true; do
        ui_read name "用户名（字母、数字、. _ -，最多 32 个）: " || return 1
        [ -z "$name" ] && { echo "已取消。"; return 0; }
        if ! ss_user_name_ok "$name"; then ui_err "用户名只能有字母、数字、. _ -，最多 32 个"; continue; fi
        if ss_user_exists "$name"; then ui_err "已经有用户 $name"; continue; fi
        break
    done
    key=$(ss_gen_key "$method")
    ss_cfg_set "$CONFIG_PATH" '.users = ((.users // []) + [{name: $n, password: $k}])' --arg n "$name" --arg k "$key" || return 1
    if ss_apply_main; then
        ui_ok "已添加用户 $name"
        ss_user_links "$name" "$key"
    else
        ui_err "加用户后服务没起来，撤回。"
        ss_cfg_set "$CONFIG_PATH" '.users |= map(select(.name != $n)) | if (.users | length) == 0 then del(.users) else . end' --arg n "$name"
        ss_apply_main
        return 1
    fi
}

# 选一个用户：结果放在 PICKED
PICKED=""
ss_user_pick() {
    local n i c
    n=$(ss_users_count)
    [ "$n" -gt 0 ] || { ui_warn "还没有用户。"; return 1; }
    for (( i = 0; i < n; i++ )); do
        printf "  ${CYAN}%2d.${RESET} %s\n" $((i + 1)) "$(jq -r ".users[$i].name" "$CONFIG_PATH")"
    done
    ui_read c "选择 [1-$n]（回车取消）: " || return 1
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ] || return 1
    PICKED=$(jq -r ".users[$((c - 1))].name" "$CONFIG_PATH")
}

ss_user_delete() {
    ss_user_pick || return 0
    ui_yes "删除用户 ${PICKED}？它的链接会立即失效。" n || { echo "已取消。"; return 0; }
    ss_cfg_set "$CONFIG_PATH" '.users |= map(select(.name != $n)) | if (.users | length) == 0 then del(.users) else . end' --arg n "$PICKED" || return 1
    ss_apply_main && ui_ok "已删除用户 ${PICKED}"
    [ "$(ss_users_count)" -eq 0 ] && ui_info "已没有用户，回到单密钥：只用服务器密钥的链接又能用了。"
    return 0
}

# 换某个用户的密钥（比如链接泄露了）
ss_user_rekey() {
    local key method
    ss_user_pick || return 0
    method=$(ss_cfg "$CONFIG_PATH" .method)
    key=$(ss_gen_key "$method")
    ss_cfg_set "$CONFIG_PATH" '.users |= map(if .name == $n then .password = $k else . end)' --arg n "$PICKED" --arg k "$key" || return 1
    ss_apply_main && { ui_ok "已给 ${PICKED} 换了新密钥，旧链接失效"; ss_user_links "$PICKED" "$key"; }
}

ss_users_list() {
    local n i
    n=$(ss_users_count)
    [ "$n" -gt 0 ] || { ui_warn "还没有用户（现在是单密钥）。"; return 0; }
    for (( i = 0; i < n; i++ )); do
        ss_user_links "$(jq -r ".users[$i].name" "$CONFIG_PATH")" "$(jq -r ".users[$i].password" "$CONFIG_PATH")"
    done
}

ss_users_menu() {
    local c
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    while true; do
        ui_sub "单端口多用户（EIH）：$( [ "$(ss_users_count)" -gt 0 ] && echo "$(ss_users_count) 个用户" || echo "未开启")" \
            "添加用户" "删除用户" "查看用户与链接" "给用户换密钥"
        ui_read c || return 0
        case "$c" in
            1) ss_user_add ;;
            2) ss_user_delete ;;
            3) ss_users_list ;;
            4) ss_user_rekey ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}

# ── lib/ss-ports.sh ───────────────────────────────────────────────────────────
# 额外端口：每个端口一个配置（/etc/ss-rust/ports/<端口>.json）和一个服务（ss-rust-<端口>），
# 与旧版相同。新端口照搬主配置（加密方式、TFO、DNS、插件、出口代理、日志），只换端口与密钥，
# 不带单端口多用户。bash。

ss_port_add() {
    local port method key f ip
    [ -f "$CONFIG_PATH" ] || { ui_err "先安装 Shadowsocks Rust。"; return 1; }
    method=$(ss_cfg "$CONFIG_PATH" .method)
    ui_info "新端口沿用主配置的加密方式（${method}）、TFO、DNS、插件与出口代理，密钥另配。"
    ss_ask_port || return 0; port="$ASK"
    ss_ask_key "$method" || return 0; key="$ASK"
    mkdir -p "$PORTS_DIR"
    f="${PORTS_DIR}/${port}.json"
    jq --argjson p "$port" --arg k "$key" 'del(.users) | .server_port = $p | .password = $k
        | if .log.writers then .log.writers |= map(if .file then .file.prefix = ("ss-rust-" + ($p | tostring)) else . end) else . end' \
        "$CONFIG_PATH" > "$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f" || { ui_err "写配置失败"; rm -f "$f.tmp"; return 1; }
    ss_write_service "ss-rust-$port" "$f" "Shadowsocks Rust Service (Port ${port})" || return 1
    ss_svc_enable "ss-rust-$port"
    if ! ss_svc_restart_verify "ss-rust-$port"; then
        ui_err "新端口没能运行，撤回。"
        ss_svc_remove "ss-rust-$port"; rm -f "$f"
        return 1
    fi
    open_port "$port"
    ui_ok "已添加端口 $port"
    ss_ips
    for ip in $SS_IPV4 $SS_IPV6; do
        echo "  $(ss_link "$ip" "$port" "$method" "$key" "SS-$ip-$port" "$(ss_plugin_query "$(ss_cfg "$f" .plugin)" "$(ss_cfg "$f" .plugin_opts)")")"
    done
}

# 每个额外端口的状态与链接
ss_ports_links() {
    local f port method key st ip
    ss_ips
    for f in "${PORTS_DIR}"/*.json; do
        [ -f "$f" ] || continue
        port=$(ss_cfg "$f" .server_port); method=$(ss_cfg "$f" .method); key=$(ss_cfg "$f" .password)
        if ss_svc_active "ss-rust-$port"; then st="${GREEN}运行中${RESET}"; else st="${RED}未运行${RESET}"; fi
        echo -e "  端口 ${port}  ${method}  ${st}"
        for ip in $SS_IPV4 $SS_IPV6; do
            echo "    $(ss_link "$ip" "$port" "$method" "$key" "SS-$ip-$port" "$(ss_plugin_query "$(ss_cfg "$f" .plugin)" "$(ss_cfg "$f" .plugin_opts)")")"
        done
    done
}

ss_port_delete() {
    local ports=() f c p
    for f in "${PORTS_DIR}"/*.json; do [ -f "$f" ] && ports+=("$(basename "$f" .json)"); done
    [ ${#ports[@]} -gt 0 ] || { ui_warn "还没有额外端口。"; return 0; }
    for (( c = 0; c < ${#ports[@]}; c++ )); do printf "  ${CYAN}%2d.${RESET} %s\n" $((c + 1)) "${ports[$c]}"; done
    ui_read c "删除哪个 [1-${#ports[@]}]（回车取消）: " || return 0
    [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#ports[@]} ] || { echo "已取消。"; return 0; }
    p="${ports[$((c - 1))]}"
    ss_svc_remove "ss-rust-$p"
    rm -f "${PORTS_DIR}/${p}.json"
    close_port "$p"
    ui_ok "已删除端口 $p（防火墙也关了）"
}

ss_ports_menu() {
    local c n f
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    while true; do
        n=0; for f in "${PORTS_DIR}"/*.json; do [ -f "$f" ] && n=$((n + 1)); done
        ui_sub "多端口：主端口 $(ss_cfg "$CONFIG_PATH" .server_port)，额外 ${n} 个" "添加端口" "删除端口" "查看端口与链接"
        ui_read c || return 0
        case "$c" in
            1) ss_port_add ;;
            2) ss_port_delete ;;
            3) [ "$n" -gt 0 ] && ss_ports_links || ui_warn "还没有额外端口。" ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}

# ── lib/ss-outbound.sh ────────────────────────────────────────────────────────
# 出口代理（shadowsocks-rust 1.25）：ssserver 发出的 TCP 连接经 SOCKS5 / HTTP / HTTPS 代理出去，
# 可以多跳；UDP 不经代理，仍从本机直接出去。主端口与每个额外端口一起设置。bash。

# 一跳的写法：socks5|http|https://[用户:密码@]主机:端口（IPv6 主机写在方括号里）
ss_proxy_url_ok() { [[ "$1" =~ ^(socks5|http|https)://([^@/[:space:]]+@)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]]; }

# 显示用：去掉用户名密码
ss_proxy_show() { sed -E 's#://[^@/]+@#://***@#g'; }

ss_outbound_current() {
    ss_cfg "$CONFIG_PATH" 'if (.outbound_proxy | type) == "array" then (.outbound_proxy | join(" → ")) else .outbound_proxy end'
}

# 从本机经代理访问一次，并显示出口 IP（第一跳；多跳时只能测第一跳）
ss_outbound_test() {   # <代理地址>
    local url="$1" code ip
    case "$url" in socks5://*) url="socks5h://${url#socks5://}" ;; esac
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 -x "$url" https://www.gstatic.com/generate_204 2>/dev/null)
    if [ "$code" = 204 ]; then
        ip=$(curl -s --max-time 12 -x "$url" https://api.ipify.org 2>/dev/null)
        ui_ok "代理可用，出口 IP：${ip:-（没查到）}"
        return 0
    fi
    ui_err "经代理访问失败（HTTP ${code:-无响应}）"
    return 1
}

ss_outbound_set() {
    local input hops=() h json
    echo "  例：socks5://127.0.0.1:1080、socks5://用户:密码@1.2.3.4:1080、http://1.2.3.4:8080"
    echo "  多跳按顺序用逗号分开：socks5://a:1080,https://b:443"
    ui_read input "代理地址（回车取消）: " || return 0
    [ -n "$input" ] || { echo "已取消。"; return 0; }
    IFS=',' read -r -a hops <<< "$input"
    for h in "${hops[@]}"; do
        h=$(echo "$h" | tr -d '[:space:]')
        ss_proxy_url_ok "$h" || { ui_err "看不懂这一跳：$(echo "$h" | ss_proxy_show)"; return 1; }
    done
    ss_outbound_test "$(echo "${hops[0]}" | tr -d '[:space:]')" || ui_yes "仍然设置吗？" n || return 0
    if [ ${#hops[@]} -eq 1 ]; then
        json=$(jq -cn --arg u "$(echo "${hops[0]}" | tr -d '[:space:]')" '$u')
    else
        json=$(printf '%s\n' "${hops[@]}" | tr -d ' \t' | jq -Rsc 'split("\n") | map(select(length > 0))')
    fi
    for f in $(ss_all_configs); do
        ss_cfg_set "$f" '.outbound_proxy = $p' --argjson p "$json" || return 1
    done
    ss_apply_all && ui_ok "已设置出口代理：$(ss_outbound_current | ss_proxy_show)（UDP 仍直连）"
}

ss_outbound_clear() {
    [ -n "$(ss_outbound_current)" ] || { ui_warn "没有设置出口代理。"; return 0; }
    for f in $(ss_all_configs); do ss_cfg_set "$f" 'del(.outbound_proxy)' || return 1; done
    ss_apply_all && ui_ok "已取消出口代理，回到直连。"
}

ss_outbound_menu() {
    local c cur
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    while true; do
        cur=$(ss_outbound_current)
        ui_sub "出口代理：$( [ -n "$cur" ] && echo "$cur" | ss_proxy_show || echo "未设置（直连）")" \
            "设置出口代理（SOCKS5 / HTTP / HTTPS，可多跳）" "测试当前的代理" "取消出口代理"
        echo -e "  ${DIM}只有 TCP 经代理；UDP 仍从本机直接出去。${RESET}"
        ui_read c || return 0
        case "$c" in
            1) ss_outbound_set ;;
            2) if [ -n "$cur" ]; then ss_outbound_test "$(ss_cfg "$CONFIG_PATH" 'if (.outbound_proxy | type) == "array" then .outbound_proxy[0] else .outbound_proxy end')"; else ui_warn "没有设置出口代理。"; fi ;;
            3) ss_outbound_clear ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}

# ── lib/ss-log.sh ─────────────────────────────────────────────────────────────
# 日志（shadowsocks-rust 1.24 起配置文件里的 log）：级别，以及另写一份到
# /var/log/ss-rust/（按天分文件，保留 7 个）。默认只输出到控制台：systemd 下进 journal，
# OpenRC 下进 /var/log/ss-rust.log。主端口与每个额外端口一起设置。bash。

SS_LOG_DIR="/var/log/ss-rust"

ss_log_level() { ss_cfg "$CONFIG_PATH" '.log.level // 0'; }
ss_log_file_on() { jq -e 'any((.log.writers // [])[]; has("file"))' "$CONFIG_PATH" >/dev/null 2>&1; }

ss_log_level_name() {
    case "$1" in 1) echo "详细（debug）" ;; 2|3) echo "最详细（trace）" ;; *) echo "默认（info）" ;; esac
}

ss_log_set_level() {
    local c f
    echo -e "  ${CYAN} 1.${RESET} 默认（info，推荐）"
    echo -e "  ${CYAN} 2.${RESET} 详细（debug，排查连接问题时用）"
    echo -e "  ${CYAN} 3.${RESET} 最详细（trace，日志很多）"
    ui_read c "日志级别 [1-3]: " || return 0
    case "$c" in 1|2|3) ;; *) echo "已取消。"; return 0 ;; esac
    for f in $(ss_all_configs); do
        if [ "$c" = 1 ]; then
            ss_cfg_set "$f" 'if .log then .log |= del(.level) else . end | if .log == {} then del(.log) else . end' || return 1
        else
            ss_cfg_set "$f" '.log.level = $l' --argjson l $((c - 1)) || return 1
        fi
    done
    ss_apply_all && ui_ok "日志级别：$(ss_log_level_name $((c - 1)))"
}

# 写文件：每个配置的文件名前缀是它的服务名
ss_log_file_enable() {
    local f p
    mkdir -p "$SS_LOG_DIR"
    for f in $(ss_all_configs); do
        p="ss-rust"
        [ "$f" != "$CONFIG_PATH" ] && p="ss-rust-$(basename "$f" .json)"
        ss_cfg_set "$f" '.log.writers = [{console: {}}, {file: {directory: $d, rotation: "daily", prefix: $p, max_files: 7}}]' \
            --arg d "$SS_LOG_DIR" --arg p "$p" || return 1
    done
    ss_apply_all && ui_ok "日志另写到 ${SS_LOG_DIR}/（按天分文件，保留 7 个）"
}

ss_log_file_disable() {
    local f
    for f in $(ss_all_configs); do
        ss_cfg_set "$f" 'if .log then .log |= del(.writers) else . end | if .log == {} then del(.log) else . end' || return 1
    done
    ss_apply_all && ui_ok "不再写日志文件（${SS_LOG_DIR} 里已有的文件留着，可以手动删）"
}

# 最近的日志：写了文件就看最新的文件，否则看服务的输出
ss_log_show() {   # [服务名]
    local name="${1:-ss-rust}" last
    if ss_log_file_on; then
        last=$(ls -1t "$SS_LOG_DIR/${name}".* 2>/dev/null | head -n 1)
        [ -n "$last" ] && { echo -e "${DIM}${last}${RESET}"; tail -n 40 "$last"; return 0; }
    fi
    ss_svc_logs "$name" 40
}

ss_log_menu() {
    local c
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    while true; do
        ui_sub "日志：级别 $(ss_log_level_name "$(ss_log_level)")，$(ss_log_file_on && echo "另写文件 ${SS_LOG_DIR}/" || echo "不写文件")" \
            "日志级别" "另写到文件（按天分，保留 7 个）" "不写文件" "查看最近的日志"
        ui_read c || return 0
        case "$c" in
            1) ss_log_set_level ;;
            2) ss_log_file_enable ;;
            3) ss_log_file_disable ;;
            4) ss_log_show ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}

# ── lib/ss-mainland.sh ────────────────────────────────────────────────────────
# 屏蔽中国大陆的连接：用本仓库的 block-mainland.sh（ipset + iptables，开机自动恢复，
# 可定时更新 IP 库）。脚本放在 /usr/local/bin（与旧版相同的位置）。bash。

MAINLAND_BLOCK_SCRIPT="/usr/local/bin/block-mainland.sh"
MAINLAND_EXTRACT_SCRIPT="/usr/local/bin/extract-cn-ip-from-mmdb.py"

ss_mainland_active() {
    command -v iptables-save >/dev/null 2>&1 && iptables-save 2>/dev/null | grep -q 'mainland_cn_src'
}

# 取最新的 block-mainland.sh 与它用的 Python 脚本（下载校验后才换上）
ss_mainland_fetch() {
    local tmp
    if ! fetch_verified_script "${SS_RAW_BASE}/block-mainland.sh" "${MAINLAND_BLOCK_SCRIPT}.new"; then
        [ -x "$MAINLAND_BLOCK_SCRIPT" ] && { ui_warn "取不到最新的屏蔽脚本，用本机已有的。"; return 0; }
        return 1
    fi
    mv -f "${MAINLAND_BLOCK_SCRIPT}.new" "$MAINLAND_BLOCK_SCRIPT" && chmod 755 "$MAINLAND_BLOCK_SCRIPT"
    tmp=$(mktemp) || return 1
    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "${SS_RAW_BASE}/extract-cn-ip-from-mmdb.py" -o "$tmp" \
        && [ -s "$tmp" ] && head -n 1 "$tmp" | grep -q python; then
        mv -f "$tmp" "$MAINLAND_EXTRACT_SCRIPT" && chmod 755 "$MAINLAND_EXTRACT_SCRIPT"
    else
        rm -f "$tmp"
        [ -f "$MAINLAND_EXTRACT_SCRIPT" ] || { ui_err "下载 extract-cn-ip-from-mmdb.py 失败"; return 1; }
    fi
}

ss_mainland_run() {   # [子命令…]
    PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 bash "$MAINLAND_BLOCK_SCRIPT" "$@"
}

ss_mainland_menu() {
    local c
    [ -f "$CONFIG_PATH" ] || { ui_err "还没有安装 Shadowsocks Rust。"; return 1; }
    ss_mainland_fetch || { ui_err "屏蔽脚本下载失败，请检查网络。"; return 1; }
    while true; do
        ui_sub "屏蔽中国大陆的连接：$(ss_mainland_active && echo 已启用 || echo 未启用)" \
            "下载 IP 库并启用" "更新 IP 库" "查看状态" "停用" "定时更新 IP 库（每天 / 每周）" "关闭定时更新"
        echo -e "  ${DIM}屏蔽的是来自中国大陆的入站连接（主端口、额外端口与 ShadowTLS 端口）。${RESET}"
        ui_read c || return 0
        case "$c" in
            1) ss_mainland_run enable ;;
            2) ss_mainland_run update ;;
            3) ss_mainland_run status ;;
            4) ss_mainland_run disable ;;
            5) local s; ui_read s "每天还是每周？[daily/weekly]（回车 daily）: " || continue
               ss_mainland_run auto-update-enable "${s:-daily}" ;;
            6) ss_mainland_run auto-update-disable ;;
            0|"") return 0 ;;
            *) ui_err "无效的选择" ;;
        esac
    done
}


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
