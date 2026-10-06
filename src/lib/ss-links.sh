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
