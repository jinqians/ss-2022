# ── lib/ss-ui.sh ──────────────────────────────────────────────────────────────
# 菜单的样子（与 PSM、snell 的主菜单一致）：标题、「标签 ▶ 值」两列的状态栏、
# ═ 框里两列的选项（先排满左列）、横线下的 0。bash。

BOLD='\033[1m'
BLUE='\033[34m'
DIM='\033[2m'

# 显示宽度，与 locale 无关（新装的 VPS 常常没有 UTF-8 locale）：逐个 UTF-8 字节看，
# ASCII 与两字节的字符（×）占一格，三、四字节的（中文）占两格，后续字节不算
ui_width() {
    local s="$1" i code w=0
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        printf -v code '%d' "'${s:i:1}"
        (( code < 0 )) && (( code += 256 ))
        if (( code < 0x80 || (code >= 0xC0 && code < 0xE0) )); then
            w=$((w + 1))
        elif (( code >= 0xE0 )); then
            w=$((w + 2))
        fi
    done
    echo "$w"
}

ui_pad() {   # <文字> <宽度>：文字后补空格到这个宽度
    local w; w=$(ui_width "$1")
    printf '%s%*s' "$1" $(( $2 > w ? $2 - w : 0 )) ''
}

# 状态栏：先 ui_status_reset，再逐项 ui_status_add <标签> <值> [颜色]，最后 ui_status_print
UI_LABELS=(); UI_VALUES=(); UI_COLORS=()
ui_status_reset() { UI_LABELS=(); UI_VALUES=(); UI_COLORS=(); }
ui_status_add() { UI_LABELS+=("$1"); UI_VALUES+=("$2"); UI_COLORS+=("${3:-}"); }
ui_status_print() {   # 标签 9 格，左列的值补到 16 格（长的值放右列）
    local i line n=${#UI_LABELS[@]}
    for (( i = 0; i < n; i += 2 )); do
        line="  ${CYAN}$(ui_pad "${UI_LABELS[i]}" 9)${RESET} ▶  ${UI_COLORS[i]}"
        if (( i + 1 < n )); then
            line="${line}$(ui_pad "${UI_VALUES[i]}" 16)${RESET} ${CYAN}$(ui_pad "${UI_LABELS[i + 1]}" 9)${RESET} ▶  ${UI_COLORS[i + 1]}${UI_VALUES[i + 1]}${RESET}"
        else
            line="${line}${UI_VALUES[i]}${RESET}"
        fi
        echo -e "$line"
    done
}

# 两列的选项：ui_items <标题> <左列行数> <第 1 项> <第 2 项> …（编号从 1 起，先排满左列）
ui_items() {
    local title="$1" rows="$2" i k w=0 line
    shift 2
    local items=("$@")
    local wide="══════════════════════════════════════════════════════════════"
    for (( i = 0; i < rows && i < ${#items[@]}; i++ )); do
        k=$(ui_width "${items[i]}"); (( k > w )) && w=$k
    done
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    # 标题居中（62 格）
    k=$(ui_width "$title")
    echo -e "${BOLD}$(printf '%*s' $(( (62 - k) / 2 )) '')${title}${RESET}"
    echo -e "${BOLD}${BLUE}${wide}${RESET}"
    for (( i = 0; i < rows && i < ${#items[@]}; i++ )); do
        line="  ${CYAN}$(printf '%2d.' $((i + 1)))${RESET} "
        if [ -n "${items[i + rows]:-}" ]; then
            line="${line}$(ui_pad "${items[i]}" "$w")  ${CYAN}$(printf '%2d.' $((i + 1 + rows)))${RESET} ${items[i + rows]}"
        else
            line="${line}${items[i]}"
        fi
        echo -e "$line"
    done
}
ui_items_end() {   # [0 的说明]
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────────────────${RESET}"
    echo -e "  ${CYAN} 0.${RESET} ${1:-退出}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════════════${RESET}"
}

# 子菜单：ui_sub <标题> <第 1 项> <第 2 项> …（一列，编号从 1 起，0 返回）
ui_sub() {
    local title="$1" i
    shift
    echo
    echo -e "${BOLD}${BLUE}── ${title} $(printf '─%.0s' $(seq 1 $(( 40 - $(ui_width "$title") > 4 ? 40 - $(ui_width "$title") : 4 ))))${RESET}"
    for (( i = 1; i <= $#; i++ )); do
        echo -e "  ${CYAN}$(printf '%2d.' "$i")${RESET} ${!i}"
    done
    echo -e "  ${CYAN} 0.${RESET} 返回"
}

# 读一个选择；读不到（输入结束）时返回 1
ui_read() {   # <变量名> [提示]
    local __v
    if ! read -rp "$(echo -e "${CYAN}${2:-请选择: }${RESET}")" __v; then
        echo
        return 1
    fi
    printf -v "$1" '%s' "$__v"
}

# 问 y/n：ui_yes <提示> [默认 y|n]
ui_yes() {
    local a d="${2:-n}" hint="[y/N]"
    [ "$d" = y ] && hint="[Y/n]"
    read -rp "$1 ${hint}: " a || return 1
    a=${a:-$d}
    case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

ui_pause() { echo; read -rp "$(echo -e "${CYAN}按回车返回…${RESET}")" _ || true; }

ui_ok()   { echo -e "${GREEN}✓ $*${RESET}"; }
ui_warn() { echo -e "${YELLOW}$*${RESET}"; }
ui_err()  { echo -e "${RED}$*${RESET}"; }
ui_info() { echo -e "${CYAN}$*${RESET}"; }
