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
