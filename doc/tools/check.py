import re,sys,io,os
KW={"associatedtype","class","deinit","enum","extension","fileprivate","func","import","init","inout",
"internal","let","open","operator","private","precedencegroup","protocol","public","rethrows","static",
"struct","subscript","typealias","var","break","case","catch","continue","default","defer","do","else",
"fallthrough","for","guard","if","in","repeat","return","throw","throws","try","where","while","as","Any",
"await","false","is","nil","self","Self","super","true"}
bad=0
for f in sys.argv[1:]:
    s=io.open(f,encoding='utf-8').read(); s_raw=s
    name=os.path.basename(f)
    # 1) 去掉字符串与注释后检查括号配平
    t=[]; i=0; n=len(s); instr=False; inline=False; inblk=0
    while i<n:
        c=s[i]; nxt=s[i+1] if i+1<n else ''
        if inline:
            if c=='\n': inline=False
            i+=1; continue
        if inblk:
            if c=='/' and nxt=='*': inblk+=1; i+=2; continue
            if c=='*' and nxt=='/': inblk-=1; i+=2; continue
            i+=1; continue
        if instr:
            if c=='\\': i+=2; continue
            if c=='"': instr=False
            i+=1; continue
        if c=='/' and nxt=='/': inline=True; i+=2; continue
        if c=='/' and nxt=='*': inblk=1; i+=2; continue
        if c=='"': instr=True; i+=1; continue
        t.append(c); i+=1
    code="".join(t)
    for op,cl,label in [('{','}','花括号'),('(',')','圆括号'),('[',']','方括号')]:
        d=code.count(op)-code.count(cl)
        if d: print(f"✗ {name}: {label}不配平 差 {d}"); bad+=1
    if instr: print(f"✗ {name}: 字符串未闭合"); bad+=1
    if inblk: print(f"✗ {name}: 块注释未闭合"); bad+=1
    # 2) 声明名撞 Swift 关键字（未加反引号）
    for m in re.finditer(r'\b(?:let|var|func|case)\s+([A-Za-z_]\w*)', code):
        # 排除三种误报：`guard let self` 是解包写法；`case Self.x` 是模式匹配；
        # `case "字符串" where 条件` 剔除字符串后剩 `case where` —— where 是守卫不是声明。
        if m.group(1) in KW and m.group(1) not in ('self', 'Self', 'where'): print(f"✗ {name}: 声明名是 Swift 关键字: {m.group(1)}"); bad+=1
    # 3) 中文全角标点混进代码（只查代码区，注释与字符串已剔除）
    for ch in "，。；：（）【】「」":
        if ch in code: print(f"✗ {name}: 代码区出现全角标点 {ch}"); bad+=1
    # 4) 硬编码颜色字面量（token 之外）。
    #    注意要在**保留字符串**的源码上查 —— 第一版跑在剔除过字符串的 code 上，
    #    于是永远匹配不到，等于这条检查一直是空转的。
    nocomment=re.sub(r'//[^\n]*','',re.sub(r'/\*.*?\*/','',s_raw,flags=re.S))
    for m in re.finditer(r'Color\(hex:\s*"([0-9A-Fa-f]{6})"', nocomment):
        # WidgetTheme.swift 是扩展自己的 token 表（刻意从 UmbraTokens 抄值，不共享文件），
        # 和 UmbraTokens 一样是「定义色值的地方」，不算硬编码。
        if name not in ("UmbraTokens.swift","UmbraColors.swift","WidgetTheme.swift"):
            print(f"✗ {name}: 页面里出现硬编码颜色 #{m.group(1)}，应走 token"); bad+=1
    print(f"· {name}: {len(s)} 字节, {s.count(chr(10))+1} 行 —— 结构检查通过" if bad==0 else f"· {name}: 见上")
print("\n关键字/结构检查:", "全部通过" if bad==0 else f"{bad} 处问题")
sys.exit(1 if bad else 0)
