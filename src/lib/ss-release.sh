# ── lib/ss-release.sh ─────────────────────────────────────────────────────────
# shadowsocks-rust 的发布版：查最新版本、按 CPU 选包、下载并核对官方的 SHA-256 后安装。
# 用静态链接的 musl 版：不依赖系统的 glibc，Alpine 与老系统都能跑。bash。

SS_REPO="shadowsocks/shadowsocks-rust"
SS_FALLBACK_VERSION="1.25.0"   # 查不到最新版本时（GitHub API 限流等）用它

# 本机对应的发布包名里的平台部分
ss_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64-unknown-linux-musl" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-musl" ;;
        armv7l|armv7|armv8l) echo "armv7-unknown-linux-musleabihf" ;;
        armv6l) echo "arm-unknown-linux-musleabihf" ;;
        i686|i386) echo "i686-unknown-linux-musl" ;;
        riscv64) echo "riscv64gc-unknown-linux-musl" ;;
        loongarch64) echo "loongarch64-unknown-linux-musl" ;;
        *) return 1 ;;
    esac
}

# 最新的正式版（不带 v）。先问 API，限流时看 releases/latest 跳到哪个标签
ss_latest_version() {
    local v
    v=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${SS_REPO}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    [ -n "$v" ] || v=$(curl -fsSI --max-time 15 -o /dev/null -w '%{redirect_url}' "https://github.com/${SS_REPO}/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p')
    v=${v#v}
    case "$v" in
        [0-9]*.[0-9]*.[0-9]*) echo "$v" ;;
        *) echo "$SS_FALLBACK_VERSION"; return 1 ;;
    esac
}

# 已装的版本：问二进制本身（ver.txt 只是记录）
ss_installed_version() {
    local v=""
    [ -x "$BINARY_PATH" ] && v=$("$BINARY_PATH" --version 2>/dev/null | awk '{print $2; exit}')
    [ -n "$v" ] || v=$(cat "$VERSION_FILE" 2>/dev/null)
    echo "${v#v}"
}

# a < b（x.y.z，逐段按数字比）
ss_version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
            if ((x[i] + 0) < (y[i] + 0)) exit 0
            if ((x[i] + 0) > (y[i] + 0)) exit 1
        }
        exit 1
    }'
}

# 下载、核对、安装：成功后 BINARY_PATH 是新的 ssserver
ss_install_binary() {   # <版本，不带 v>
    local ver="$1" target f url tmp
    if ! target=$(ss_target); then
        ui_err "不支持的 CPU 架构：$(uname -m)"
        return 1
    fi
    f="shadowsocks-v${ver}.${target}.tar.xz"
    url="https://github.com/${SS_REPO}/releases/download/v${ver}/${f}"
    tmp=$(mktemp -d) || return 1
    ui_info "下载 shadowsocks-rust ${ver}（${target}）…"
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$tmp/$f" "$url" \
        || ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 60 -o "$tmp/$f.sha256" "$url.sha256"; then
        ui_err "下载失败：$url"
        rm -rf "$tmp"; return 1
    fi
    if ! (cd "$tmp" && sha256sum -c "$f.sha256" >/dev/null 2>&1); then
        ui_err "下载的文件与官方的 SHA-256 不符，已丢弃。"
        rm -rf "$tmp"; return 1
    fi
    if ! xz -dc "$tmp/$f" | tar -xf - -C "$tmp" || [ ! -f "$tmp/ssserver" ]; then
        ui_err "解压失败，或包里没有 ssserver。"
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$(dirname "$BINARY_PATH")" "$INSTALL_DIR"
    cp "$tmp/ssserver" "${BINARY_PATH}.new" && chmod 755 "${BINARY_PATH}.new"
    if ! "${BINARY_PATH}.new" --version >/dev/null 2>&1; then
        ui_err "新的 ssserver 在这台机器上运行不了。"
        rm -f "${BINARY_PATH}.new"; rm -rf "$tmp"; return 1
    fi
    mv -f "${BINARY_PATH}.new" "$BINARY_PATH"
    echo "$ver" > "$VERSION_FILE"
    rm -rf "$tmp"
    ui_ok "shadowsocks-rust ${ver} 已安装（SHA-256 核对无误）"
}
