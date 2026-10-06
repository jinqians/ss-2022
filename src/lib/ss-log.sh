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
