#!/usr/bin/env bash
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

SS_LIB="${SS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"  # @dev
. "$SS_LIB/common.sh"       # @bundle
. "$SS_LIB/ss-ui.sh"        # @bundle
. "$SS_LIB/ss-service.sh"   # @bundle
. "$SS_LIB/bm-rules.sh"     # @bundle
. "$SS_LIB/bm-boot.sh"      # @bundle

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
