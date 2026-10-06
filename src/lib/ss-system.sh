# ── lib/ss-system.sh ──────────────────────────────────────────────────────────
# 依赖、时间同步、混淆插件、管理命令（ssrust）、运行别的脚本。bash。

# 装依赖：Debian / Ubuntu、RHEL 系、Alpine 都用各自的包名
ss_install_deps() {
    detect_os
    ui_info "检查依赖…"
    ensure_cmds curl jq tar ip ss || { ui_err "依赖安装失败，请检查软件源。"; return 1; }
    # xz 在 Debian / Ubuntu 叫 xz-utils
    if ! command -v xz >/dev/null 2>&1; then
        if [ "$PKG" = apt ]; then pkg_install xz-utils; else pkg_install xz; fi
        command -v xz >/dev/null 2>&1 || { ui_err "没装上 xz（解压发布包要用）"; return 1; }
    fi
    # 二维码可有可无；RHEL 系要 EPEL，Alpine 的包名是 libqrencode-tools
    if ! command -v qrencode >/dev/null 2>&1; then
        case "$OS_FAMILY" in
            alpine) pkg_install libqrencode-tools >/dev/null 2>&1 ;;
            rhel) pkg_install epel-release >/dev/null 2>&1; pkg_install qrencode >/dev/null 2>&1 ;;
            *) pkg_install qrencode >/dev/null 2>&1 ;;
        esac
        command -v qrencode >/dev/null 2>&1 || ui_warn "没装上 qrencode，查看配置时不显示二维码（不影响使用）。"
    fi
    return 0
}

# 时间同步：2022 系列加密校验时间戳，服务器与客户端差 30 秒以上就连不上。
# 只开 NTP，不改时区（时区与时间戳无关）。
ss_ensure_time_sync() {
    detect_os
    if [ "$(ss_init)" = systemd ]; then
        local s
        for s in chronyd chrony systemd-timesyncd ntp ntpd; do
            systemctl is-active --quiet "$s" 2>/dev/null && return 0
        done
        if systemctl list-unit-files systemd-timesyncd.service 2>/dev/null | grep -q timesyncd \
            && { timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd >/dev/null 2>&1; }; then
            ui_ok "已开启时间同步（systemd-timesyncd）"; return 0
        fi
        pkg_install chrony >/dev/null 2>&1 || true
        systemctl enable --now chronyd >/dev/null 2>&1 || systemctl enable --now chrony >/dev/null 2>&1 || true
        if systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
            ui_ok "已开启时间同步（chrony）"; return 0
        fi
    elif [ "$(ss_init)" = openrc ]; then
        rc-service chronyd status >/dev/null 2>&1 || rc-service ntpd status >/dev/null 2>&1 && return 0
        pkg_install chrony >/dev/null 2>&1 || true
        rc-update add chronyd default >/dev/null 2>&1 || true
        if rc-service chronyd start >/dev/null 2>&1; then ui_ok "已开启时间同步（chrony）"; return 0; fi
    fi
    ui_warn "没能自动开启时间同步。用 2022 系列加密时客户端连不上，先检查服务器时间是否准确。"
    return 0
}

# simple-obfs 的服务端（obfs-server）：只有 Debian / Ubuntu 的官方源里有
ss_install_obfs() {
    command -v obfs-server >/dev/null 2>&1 && return 0
    detect_os
    if [ "$PKG" != apt ]; then
        ui_warn "这个系统的官方源里没有 simple-obfs（只有 Debian / Ubuntu 有），请自行编译 obfs-server 后再开。"
        return 1
    fi
    ui_info "安装 simple-obfs…"
    pkg_install simple-obfs >/dev/null 2>&1
    command -v obfs-server >/dev/null 2>&1 || { ui_warn "simple-obfs 安装失败"; return 1; }
}

# 管理命令：ssrust 每次运行都取最新的脚本（ss.jinqians.com），取不到时用本机保存的那份
# （/usr/local/bin/ss-2022.sh，旧版的 ssrust 是指向它的链接）
ss_write_command() {
    mkdir -p /usr/local/bin
    rm -f /usr/local/bin/ssrust
    cat > /usr/local/bin/ssrust <<EOF
#!/usr/bin/env bash
# Shadowsocks Rust 管理命令（ss-2022 写的）：运行最新的管理脚本，取不到时用本机的那份
[ "\$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
tmp=\$(mktemp)
if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "${SS_SCRIPT_URL}" -o "\$tmp" 2>/dev/null \\
    && [ -s "\$tmp" ] && bash -n "\$tmp" 2>/dev/null; then
    cp "\$tmp" /usr/local/bin/ss-2022.sh && chmod 755 /usr/local/bin/ss-2022.sh
    bash "\$tmp" "\$@"; rc=\$?
    rm -f "\$tmp"; exit \$rc
fi
rm -f "\$tmp"
echo "取不到最新的脚本，运行本机保存的版本。"
exec bash /usr/local/bin/ss-2022.sh "\$@"
EOF
    chmod 755 /usr/local/bin/ssrust
    # 本机留一份：在用的脚本是文件就拷它，否则（bash <(curl …) 时）下载一份
    if [ -f "$0" ] && [ -s "$0" ] && head -n 3 "$0" | grep -q 'ss-2022'; then
        [ "$(readlink -f "$0")" = /usr/local/bin/ss-2022.sh ] || cp "$0" /usr/local/bin/ss-2022.sh
    else
        fetch_verified_script "$SS_SCRIPT_URL" /usr/local/bin/ss-2022.sh >/dev/null 2>&1 || true
    fi
    [ -f /usr/local/bin/ss-2022.sh ] && chmod 755 /usr/local/bin/ss-2022.sh
    return 0
}

# 下载、校验后运行一个脚本（ShadowTLS 管理等）
ss_run_remote() {   # <地址> <名称> [参数…]
    local url="$1" name="$2" tmp
    shift 2
    tmp=$(mktemp) || return 1
    if fetch_verified_script "$url" "$tmp"; then
        bash "$tmp" "$@"
    else
        ui_err "${name}下载校验失败，没有运行。"
    fi
    rm -f "$tmp"
}
