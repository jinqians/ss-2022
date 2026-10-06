#!/usr/bin/env bash
# 与 jinqians/snell 共用的文件：snell 仓库是它们的出处，这里只放一模一样的副本。
#   - src/lib 里的 common.sh、firewall.sh、netinfo.sh（系统识别、装包、防火墙、公网地址）
#   - 根目录的 shadowtls.sh、menu.sh：snell 构建出来的 scripts/shadowtls.sh、scripts/menu.sh
#     （ShadowTLS 管理、多功能菜单；旧版 ss-2022.sh 与旁人按本仓库的 raw 地址取它们）
# 要改这些文件，改 snell 仓库，构建后再运行本脚本拷过来。
#
#   bash tools/sync-shared.sh <snell 仓库目录>          拷过来
#   bash tools/sync-shared.sh <snell 仓库目录> --check  只比较（不一致时退出码 1）
set -euo pipefail
cd "$(dirname "$0")/.."
snell="${1:?用法：bash tools/sync-shared.sh <snell 仓库目录> [--check]}"
[[ -f "$snell/tools/build.sh" && -d "$snell/src/lib" ]] || { echo "不是 snell 仓库：$snell" >&2; exit 1; }

# 本仓库的路径:snell 仓库里的路径
SHARED=(
    "src/lib/common.sh:src/lib/common.sh"
    "src/lib/firewall.sh:src/lib/firewall.sh"
    "src/lib/netinfo.sh:src/lib/netinfo.sh"
    "shadowtls.sh:scripts/shadowtls.sh"
    "menu.sh:scripts/menu.sh"
)

check=false
[[ "${2:-}" == "--check" ]] && check=true
differ=0
for s in "${SHARED[@]}"; do
    here="${s%%:*}" there="$snell/${s#*:}"
    [[ -f "$there" ]] || { echo "snell 仓库里没有 ${s#*:}" >&2; exit 1; }
    if $check; then
        cmp -s "$here" "$there" || { echo "不一致：$here（snell 的 ${s#*:}）"; differ=1; }
    else
        cp "$there" "$here.tmp"
        if [[ -x "$there" ]]; then chmod 755 "$here.tmp"; else chmod 644 "$here.tmp"; fi
        mv "$here.tmp" "$here"
        echo "拷贝 $here ← snell/${s#*:}"
    fi
done
exit "$differ"
