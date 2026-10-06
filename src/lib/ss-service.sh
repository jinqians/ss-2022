# ── lib/ss-service.sh ─────────────────────────────────────────────────────────
# ss-rust 的服务：systemd（Debian / Ubuntu / RHEL 系）或 OpenRC（Alpine）。
# 主服务 ss-rust、每个额外端口一个 ss-rust-<端口>，名字与路径和旧版一样（PSM 也认这些）。
# 主服务一般跑 /etc/ss-rust/config.json；开了单端口多用户时跑生成的 config-eih.json（见 ss-config.sh）。bash。

ss_init() {
    if [ -d /run/systemd/system ]; then
        echo systemd
    elif [ -x /sbin/openrc-run ] || command -v openrc-run >/dev/null 2>&1; then
        echo openrc
    else
        echo none
    fi
}

ss_unit_file() {   # <服务名>
    case "$(ss_init)" in
        openrc) echo "/etc/init.d/$1" ;;
        *) echo "/etc/systemd/system/$1.service" ;;
    esac
}

ss_svc_exists() { [ -f "$(ss_unit_file "$1")" ]; }

# 写服务文件：<服务名> <配置文件> <说明>
ss_write_service() {
    local name="$1" conf="$2" desc="$3" f
    f=$(ss_unit_file "$name")
    case "$(ss_init)" in
        systemd)
            cat > "$f" <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH} -c ${conf}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            ;;
        openrc)
            cat > "$f" <<EOF
#!/sbin/openrc-run
description="${desc}"
command="${BINARY_PATH}"
command_args="-c ${conf}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
rc_ulimit="-n 1048576"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.log"

depend() {
    need net
    after firewall
}
EOF
            chmod 755 "$f"
            ;;
        *)
            ui_err "没有找到 systemd 或 OpenRC，无法创建服务。"
            return 1
            ;;
    esac
}

# 服务文件里跑的是哪个配置
ss_svc_conf() {   # <服务名>
    sed -n 's/.*[ "]-c \([^ "]*\).*/\1/p' "$(ss_unit_file "$1")" 2>/dev/null | head -n 1
}

ss_svc_enable() {
    case "$(ss_init)" in
        systemd) systemctl enable "$1" >/dev/null 2>&1 ;;
        openrc) rc-update add "$1" default >/dev/null 2>&1 ;;
    esac
}

ss_svc() {   # <start|stop|restart> <服务名>
    case "$(ss_init)" in
        systemd) systemctl "$1" "$2" >/dev/null 2>&1 ;;
        openrc) rc-service "$2" "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ss_svc_active() {   # <服务名>
    case "$(ss_init)" in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc) rc-service "$1" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

ss_svc_logs() {   # <服务名> [行数]
    local n="${2:-20}"
    case "$(ss_init)" in
        systemd) journalctl --no-pager -n "$n" -u "$1" 2>/dev/null ;;
        openrc) tail -n "$n" "/var/log/$1.log" 2>/dev/null ;;
    esac
}

ss_svc_remove() {   # <服务名>
    ss_svc stop "$1" || true
    case "$(ss_init)" in
        systemd)
            systemctl disable "$1" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$1.service"
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del "$1" default >/dev/null 2>&1 || true
            rm -f "/etc/init.d/$1" "/var/log/$1.log"
            ;;
    esac
}

# 启动（或重启）并确认在跑；起不来时打印日志与常见原因
ss_svc_restart_verify() {   # <服务名>
    local i
    ss_svc restart "$1" || ss_svc start "$1" || true
    for i in 1 2 3 4 5 6; do
        sleep 1
        ss_svc_active "$1" && return 0
    done
    ui_err "$1 没能运行起来，最近的日志："
    ss_svc_logs "$1" 20 | sed 's/^/  /'
    ui_warn "常见原因：密码与加密方式不匹配、端口被占用、混淆插件没装。"
    return 1
}

# 本脚本管理的全部服务：主服务和每个额外端口的
ss_all_services() {
    local f
    ss_svc_exists ss-rust && echo ss-rust
    for f in "${PORTS_DIR}"/*.json; do
        [ -f "$f" ] || continue
        echo "ss-rust-$(basename "$f" .json)"
    done
}
