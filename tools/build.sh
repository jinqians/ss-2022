#!/usr/bin/env bash
# 把 src/ 下的脚本连同它们用到的 src/lib 合成单个文件（bash <(curl …) 只能下载一个文件）。
# 根目录的文件都有人按 raw 地址取：ss-2022.sh（ss.jinqians.com、PSM、多功能菜单），
# block-mainland.sh（ss-2022.sh 与多功能菜单）。改代码请改 src/，然后重新生成。
# shadowtls.sh、menu.sh 与 jinqians/snell 的同名脚本是同一份，由 tools/sync-shared.sh 拷过来。
#
#   bash tools/build.sh          生成
#   bash tools/build.sh --check  只检查根目录的文件与 src/ 是否一致（不一致时退出码 1）
#
# src 里的写法：
#   SS_LIB=…  # @dev           只在直接运行 src/ 下的脚本时有用，合成时去掉
#   . "$SS_LIB/common.sh"  # @bundle   合成时换成 src/lib/common.sh 的内容
set -euo pipefail
cd "$(dirname "$0")/.."

# 发布文件:源文件
TARGETS=(
    "ss-2022.sh:src/ss-2022.sh"
    "block-mainland.sh:src/block-mainland.sh"
)

bundle() {   # <源文件> → 标准输出
    local src="$1" line lib n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        if (( n == 1 )); then
            printf '%s\n' "$line"
            printf '# 此文件由 tools/build.sh 从 %s 和 src/lib 生成：请修改 src/ 下的文件后重新生成。\n' "$src"
            continue
        fi
        [[ "$line" =~ \#\ @dev$ ]] && continue
        if [[ "$line" =~ ^\.\ \"\$SS_LIB/([a-z_-]+\.sh)\"[[:space:]]*\#\ @bundle$ ]]; then
            lib="src/lib/${BASH_REMATCH[1]}"
            [[ -f "$lib" ]] || { echo "$src:$n: 找不到 $lib" >&2; exit 1; }
            cat "$lib"
            printf '\n'
            continue
        fi
        if [[ "$line" == *'$SS_LIB'* ]]; then
            echo "$src:$n: 用到 \$SS_LIB 的行只能是 # @bundle 或 # @dev" >&2
            exit 1
        fi
        printf '%s\n' "$line"
    done < "$src"
}

check=false
[[ "${1:-}" == "--check" ]] && check=true
stale=0
for t in "${TARGETS[@]}"; do
    out="${t%%:*}" src="${t#*:}"
    if $check; then
        if ! diff -q <(bundle "$src") "$out" >/dev/null 2>&1; then
            echo "过期：$out（与 $src 不一致，运行 bash tools/build.sh）"
            stale=1
        fi
    else
        mkdir -p "$(dirname "$out")"
        bundle "$src" > "$out.tmp"
        chmod 755 "$out.tmp"
        mv "$out.tmp" "$out"
        echo "生成 $out ← $src"
    fi
done
exit "$stale"
