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
