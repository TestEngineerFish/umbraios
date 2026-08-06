"""类型存在性检查：代码里出现的 Umbra* 类型名是不是真的声明过。

用途和 check2 一样是替代编译器：新建一批页面时最容易的错就是引用了一个
「以为已经做了」的组件（比如 UmbraNavDots 写了但忘了加进 UmbraChrome）。

声明来源 = out/ 下的全部 .swift + 通过 --extra 传进来的工程既有文件。
"""
import io
import os
import re
import sys

decl_re = re.compile(r"^\s*(?:public |private |internal |fileprivate |final )*"
                     r"(?:struct|class|enum|protocol|extension|typealias)\s+([A-Za-z_]\w*)",
                     re.M)

files = [a for a in sys.argv[1:] if not a.startswith("--")]
extra = []
if "--extra" in sys.argv:
    extra = sys.argv[sys.argv.index("--extra") + 1:]
    files = [f for f in files if f not in extra]

declared = set()
for f in files + extra:
    if not os.path.exists(f):
        print("· 跳过（不存在）：%s" % f)
        continue
    s = io.open(f, encoding="utf-8").read()
    declared |= set(decl_re.findall(s))

bad = 0
for f in files:
    name = os.path.basename(f)
    s = io.open(f, encoding="utf-8").read()
    s = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", s, flags=re.S))
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)          # 去掉字符串字面量
    for m in re.finditer(r"\bUmbra[A-Z]\w*", s):
        if m.group(0) not in declared:
            line = s[: m.start()].count("\n") + 1
            print("✗ %s:%d 用到了没有声明的类型 %s" % (name, line, m.group(0)))
            bad += 1

print("已声明的 Umbra 类型 %d 个" % len([d for d in declared if d.startswith("Umbra")]))
print("类型存在性检查:", "全部通过" if bad == 0 else "%d 处问题" % bad)
sys.exit(1 if bad else 0)
