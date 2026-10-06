# ── lib/bm-boot.sh ────────────────────────────────────────────────────────────
# 开机自动恢复（systemd 服务 / OpenRC 服务）与定时更新 IP 库（systemd 定时器 /
# Alpine 的 /etc/periodic）。不依赖 cron 软件包。bash。

BM_BOOT_UNIT="/etc/systemd/system/block-mainland.service"
BM_BOOT_OPENRC="/etc/init.d/block-mainland"
BM_TIMER="/etc/systemd/system/block-mainland-update.timer"
BM_TIMER_SVC="/etc/systemd/system/block-mainland-update.service"
BM_PERIODIC_NAME="block-mainland-update"
BM_UPDATE_LOG="/var/log/block-mainland-update.log"
BM_SELF="/usr/local/bin/block-mainland.sh"
BM_OLD_CRON="/etc/cron.d/block-mainland-auto-update"   # 旧版的定时任务

bm_boot_enable() {
    case "$(ss_init)" in
        systemd)
            cat > "$BM_BOOT_UNIT" <<EOF
[Unit]
Description=Block mainland China connections to Shadowsocks
After=network-online.target ss-rust.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${BM_RULES}
ExecStop=/bin/sh ${BM_RULES} stop

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable block-mainland >/dev/null 2>&1
            ;;
        openrc)
            cat > "$BM_BOOT_OPENRC" <<EOF
#!/sbin/openrc-run
description="Block mainland China connections to Shadowsocks"

depend() {
    need net
    after firewall iptables ip6tables ss-rust
}

start() {
    ebegin "Applying mainland China block rules"
    /bin/sh ${BM_RULES} >/dev/null 2>&1
    eend \$?
}

stop() {
    ebegin "Removing mainland China block rules"
    /bin/sh ${BM_RULES} stop >/dev/null 2>&1
    eend 0
}
EOF
            chmod 755 "$BM_BOOT_OPENRC"
            rc-update add block-mainland default >/dev/null 2>&1
            # 让 OpenRC 记下它已启动（规则刚才已经下了，start 再跑一次也无妨）
            rc-service block-mainland start >/dev/null 2>&1 || true
            ;;
        *) ui_warn "没有 systemd 或 OpenRC：重启后要手动运行 sh ${BM_RULES}"; return 1 ;;
    esac
}

bm_boot_disable() {
    if [ -f "$BM_BOOT_UNIT" ]; then
        systemctl disable block-mainland >/dev/null 2>&1 || true
        rm -f "$BM_BOOT_UNIT"; systemctl daemon-reload
    fi
    if [ -f "$BM_BOOT_OPENRC" ]; then
        rc-update del block-mainland default >/dev/null 2>&1 || true
        rm -f "$BM_BOOT_OPENRC"
    fi
    return 0
}

bm_boot_enabled() {
    case "$(ss_init)" in
        systemd) [ -f "$BM_BOOT_UNIT" ] && systemctl is-enabled --quiet block-mainland 2>/dev/null ;;
        openrc) [ -f "$BM_BOOT_OPENRC" ] && rc-update show default 2>/dev/null | grep -qw block-mainland ;;
        *) return 1 ;;
    esac
}

# 定时更新：每天或每周一 04:30 运行一次 block-mainland.sh update
bm_auto_update_enable() {   # <daily|weekly>
    local when="${1:-daily}" cal
    case "$when" in
        daily) cal="*-*-* 04:30:00" ;;
        weekly) cal="Mon *-*-* 04:30:00" ;;
        *) ui_err "只支持 daily 或 weekly"; return 1 ;;
    esac
    [ -x "$BM_SELF" ] || { ui_err "没有 ${BM_SELF}（定时任务要运行它）"; return 1; }
    rm -f "$BM_OLD_CRON"
    case "$(ss_init)" in
        systemd)
            cat > "$BM_TIMER_SVC" <<EOF
[Unit]
Description=Update the mainland China IP lists for block-mainland

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'bash ${BM_SELF} update >> ${BM_UPDATE_LOG} 2>&1'
EOF
            cat > "$BM_TIMER" <<EOF
[Unit]
Description=Update the mainland China IP lists (${when})

[Timer]
OnCalendar=${cal}
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload
            systemctl enable --now block-mainland-update.timer >/dev/null 2>&1
            ;;
        openrc)
            rm -f "/etc/periodic/daily/$BM_PERIODIC_NAME" "/etc/periodic/weekly/$BM_PERIODIC_NAME"
            mkdir -p "/etc/periodic/$when"
            printf '#!/bin/sh\nbash %s update >> %s 2>&1\n' "$BM_SELF" "$BM_UPDATE_LOG" > "/etc/periodic/$when/$BM_PERIODIC_NAME"
            chmod 755 "/etc/periodic/$when/$BM_PERIODIC_NAME"
            # Alpine 的 crond 跑 /etc/periodic，确认它开着
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || true
            ;;
        *) ui_err "没有 systemd 或 OpenRC，无法定时。"; return 1 ;;
    esac
    ui_ok "已开启定时更新（$( [ "$when" = daily ] && echo 每天 || echo 每周一 ) 04:30），日志：${BM_UPDATE_LOG}"
}

bm_auto_update_disable() {
    if [ -f "$BM_TIMER" ]; then
        systemctl disable --now block-mainland-update.timer >/dev/null 2>&1 || true
        rm -f "$BM_TIMER" "$BM_TIMER_SVC"; systemctl daemon-reload
    fi
    rm -f "/etc/periodic/daily/$BM_PERIODIC_NAME" "/etc/periodic/weekly/$BM_PERIODIC_NAME" "$BM_OLD_CRON"
    ui_ok "已关闭定时更新"
}

bm_auto_update_state() {
    if [ -f "$BM_TIMER" ]; then
        if grep -q '^OnCalendar=Mon' "$BM_TIMER"; then echo "每周一 04:30（systemd 定时器）"; else echo "每天 04:30（systemd 定时器）"; fi
    elif [ -f "/etc/periodic/daily/$BM_PERIODIC_NAME" ]; then echo "每天（/etc/periodic/daily）"
    elif [ -f "/etc/periodic/weekly/$BM_PERIODIC_NAME" ]; then echo "每周（/etc/periodic/weekly）"
    elif [ -f "$BM_OLD_CRON" ]; then echo "旧版的 cron 任务（重新开启会换成定时器）"
    else echo "未开启"; fi
}
