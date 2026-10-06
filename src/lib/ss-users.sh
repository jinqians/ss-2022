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
