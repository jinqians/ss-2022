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
