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
