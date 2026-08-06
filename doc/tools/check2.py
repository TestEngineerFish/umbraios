"""引用存在性检查：页面里写的 UmbraColor.x / UmbraMetric.x / UmbraFont.x / UmbraIconPath.x
是不是真的在 token 层里有定义。

没有 Swift 编译器的情况下，拼错一个 token 名的后果是编译期才发现（用户那边），
而这类错误占我改动量的大头 —— 所以专门查一遍。
静态成员表从 UmbraTokens.swift / UmbraIconPath.swift 里扫 `static let/var/func` 得到。
"""
import re, sys, io, os

ROOT = os.path.dirname(os.path.abspath(__file__))


def _find_design_system():
    """找 DesignSystem 目录（token 定义在那里）。

    三种放法都支持，按优先级：
      1. 脚本旁边有 src/DesignSystem —— 容器里的工作副本；
      2. 从脚本位置逐级往上找 UmbraiOS/DesignSystem —— 放进仓库 doc/tools/ 时走这条；
      3. 环境变量 UMBRA_DESIGN_SYSTEM 显式指定。
    找不到就返回旧的 out/，让下面的成员表为空并报错，而不是静默放行。
    """
    env = os.environ.get("UMBRA_DESIGN_SYSTEM")
    if env and os.path.isdir(env):
        return env
    local = os.path.join(ROOT, "src", "DesignSystem")
    if os.path.isdir(local):
        return local
    cur = ROOT
    for _ in range(6):
        cand = os.path.join(cur, "UmbraiOS", "DesignSystem")
        if os.path.isdir(cand):
            return cand
        cur = os.path.dirname(cur)
    return os.path.join(ROOT, "out")


OUT = _find_design_system()


def members(path, enum_name):
    """扫一个文件里某个 enum/struct 的 static 成员名（含 case）。"""
    s = io.open(path, encoding="utf-8").read()
    i = s.find("enum %s" % enum_name)
    if i < 0:
        i = s.find("struct %s" % enum_name)
    if i < 0:
        return set()
    # 粗略取到下一个顶层 `\n}` 为止
    j = s.find("\n}", i)
    blk = s[i:j if j > 0 else len(s)]
    out = set(re.findall(r"static\s+(?:let|var|func)\s+([A-Za-z_]\w*)", blk))
    out |= set(re.findall(r"\bcase\s+([A-Za-z_]\w*)", blk))
    return out


TABLES = {
    "UmbraColor": members(os.path.join(OUT, "UmbraTokens.swift"), "UmbraColor"),
    "UmbraMetric": members(os.path.join(OUT, "UmbraTokens.swift"), "UmbraMetric"),
    "UmbraFont": members(os.path.join(OUT, "UmbraTokens.swift"), "UmbraFont"),
    "UmbraMotion": members(os.path.join(OUT, "UmbraTokens.swift"), "UmbraMotion"),
    "UmbraShadow": members(os.path.join(OUT, "UmbraTokens.swift"), "UmbraShadow"),
    "UmbraIconPath": members(os.path.join(OUT, "UmbraIconPath.swift"), "UmbraIconPath"),
}

bad = 0
for f in sys.argv[1:]:
    name = os.path.basename(f)
    s = io.open(f, encoding="utf-8").read()
    s = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", s, flags=re.S))
    for table, known in TABLES.items():
        if not known:
            print("✗ 取不到 %s 的成员表，检查脚本本身有问题" % table)
            bad += 1
            continue
        for m in re.finditer(r"\b%s\.([A-Za-z_]\w*)" % table, s):
            # 大写开头的是嵌套类型名（如 UmbraFont.Weight），不是静态成员，跳过
            if m.group(1)[0].isupper():
                continue
            if m.group(1) not in known and m.group(1) not in ("self", "init", "allNames"):
                line = s[: m.start()].count("\n") + 1
                print("✗ %s:%d 引用了不存在的 %s.%s" % (name, line, table, m.group(1)))
                bad += 1

print("引用存在性检查:", "全部通过" if bad == 0 else "%d 处问题" % bad)
sys.exit(1 if bad else 0)
