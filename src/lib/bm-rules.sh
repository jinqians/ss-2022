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
