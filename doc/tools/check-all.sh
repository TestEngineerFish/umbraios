#!/bin/bash
# 三个检查器一次跑完。在仓库任意位置执行都行：
#   ./doc/tools/check-all.sh
#
# 为什么需要它：这三个脚本**必须带全量 .swift 文件参数**，
# 不带参数是空跑（会打印「全部通过」但其实什么都没查）—— 这个坑踩过一次，
# 所以把「找齐文件再传进去」这一步固化成脚本，别再手敲。
set -u

# 仓库根 = 本脚本所在目录（doc/tools）往上两级
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

# 三个 target 的源码目录。新增 target 时往这里加一行。
DIRS=()
for d in UmbraiOS UmbraWidgets AutoFillExtension; do
    [ -d "$d" ] && DIRS+=("$d")
done

if [ ${#DIRS[@]} -eq 0 ]; then
    echo "✗ 在 $ROOT 下没找到源码目录（UmbraiOS / UmbraWidgets / AutoFillExtension）"
    exit 1
fi

# _to_delete 是待删的模板残留，不参与检查
FILES=$(find "${DIRS[@]}" -name '*.swift' -not -path '*/_to_delete/*' | sort)
COUNT=$(echo "$FILES" | grep -c . )
echo "== 检查 $COUNT 个 .swift 文件（$ROOT）"

FAIL=0
for c in check.py check2.py check3.py; do
    echo
    echo "── $c"
    # shellcheck disable=SC2086
    python3 "$ROOT/doc/tools/$c" $FILES | tail -3
    [ "${PIPESTATUS[0]}" -ne 0 ] && FAIL=1
done

echo
[ $FAIL -eq 0 ] && echo "✅ 三个检查器全部通过" || echo "❌ 有检查未通过，往上翻看 ✗ 开头的行"
exit $FAIL
