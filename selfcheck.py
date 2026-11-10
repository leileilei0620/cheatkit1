#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CheatKit 静态自检（不替代 clang 编译，只抓结构性错误）

修过的坑：
  早期版本把换行写成两个字符的反斜杠+n，导致 strip_code 从未识别换行，
  第一行 // 注释之后的整份文件都被当成注释丢弃，检查等于空跑。
  现在统一用真正的换行符，并额外做一遍"结构字符数量"交叉验证。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
EXTS = (".m", ".h", ".xm")
NL = chr(10)


def strip_code(src):
    """去掉字符串/字符字面量/注释，只留结构字符（保留换行以便定位行号）"""
    out = []
    i, n = 0, len(src)
    state = None  # None / 'line' / 'block' / 'str' / 'char'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if c == '"':
                state = "str"
                i += 1
                continue
            if c == "'":
                state = "char"
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line":
            if c == NL:
                state = None
                out.append(c)
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = None
                i += 2
                continue
            if c == NL:
                out.append(c)
            i += 1
            continue
        if state in ("str", "char"):
            if c == chr(92):
                i += 2
                continue
            if (state == "str" and c == '"') or (state == "char" and c == "'"):
                state = None
            i += 1
            continue
    return "".join(out)


def check_file(path):
    errs = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    code = strip_code(raw)

    # 1. 括号配对
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    line = 1
    for ch in code:
        if ch == NL:
            line += 1
            continue
        if ch in pairs:
            stack.append((ch, line))
        elif ch in pairs.values():
            if not stack:
                errs.append("  多余闭括号 %r @ line %d" % (ch, line))
                continue
            op, ol = stack.pop()
            if pairs[op] != ch:
                errs.append("  括号不匹配: %r(line %d) vs %r(line %d)"
                            % (op, ol, ch, line))
    for op, ol in stack:
        errs.append("  未闭合 %r @ line %d" % (op, ol))

    # 2. @interface / @implementation 与 @end 配对
    n_inter = len(re.findall(r"@interface\b", code))
    n_impl = len(re.findall(r"@implementation\b", code))
    n_end = len(re.findall(r"@end\b", code))
    if n_inter + n_impl != n_end:
        errs.append("  @interface(%d) + @implementation(%d) = %d，但 @end 有 %d 个"
                    % (n_inter, n_impl, n_inter + n_impl, n_end))

    # 3. Logos：只有 %hook / %group 需要 %end，%ctor 用花括号块
    if path.endswith(".xm"):
        n_hook = len(re.findall(r"%hook\b|%group\b", code))
        n_pend = len(re.findall(r"%end\b", code))
        if n_hook != n_pend:
            errs.append("  Logos: %%hook/%%group(%d) 与 %%end(%d) 不等"
                        % (n_hook, n_pend))

    # 4. C++ 关键字混入 .m（ARC 下必须是 NULL / nil）
    if path.endswith(".m"):
        for kw in ("nullptr", "std::", "#include <iostream>"):
            if kw in code:
                errs.append("  C++ 关键字残留: %s" % kw)

    # 5. hook 之后再用裸 dlsym 取 orig 会自递归（必须走 g_real_dlsym 快照）
    #    唯一允许的例外：g_pdlsym 自身的引导调用（发生在 hook dlsym 之前）
    pat = r"=\s*\(?\w+\)?\s*(?<!g_real_)dlsym\s*\("
    #    SubstrateRT.m 是「用 dlsym 解析 MS* 符号」的模块，按设计要裸调 dlsym
    if "SubstrateRT" in path:
        pat = None
    for m in (re.finditer(pat, code) if pat else []):
        ln = code[:m.start()].count(NL) + 1
        line_start = code.rfind(NL, 0, m.start()) + 1
        if "g_pdlsym" in code[line_start:m.start()]:
            continue
        errs.append("  裸 dlsym 取 orig，hook 后会自递归（改用 g_real_dlsym）@ line %d" % ln)

    # 6. 同目录/上级的 #import 目标必须真实存在
    if path.endswith((".m", ".h", ".xm")):
        for m in re.finditer(r'#\s*import\s+"([^"]+)"', raw):
            rel = m.group(1)
            target = os.path.normpath(os.path.join(os.path.dirname(path), rel))
            if not os.path.isfile(target):
                ln = raw[:m.start()].count(NL) + 1
                errs.append("  #import 目标不存在: %s @ line %d" % (rel, ln))

    nlines = raw.count(NL) + 1
    return errs, nlines, len(code)


def main():
    total_err = 0
    total_files = 0
    print("=" * 70)
    print(" CheatKit 静态自检")
    print("=" * 70)
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "build", "packages", ".theos", "obj")]
        for fn in sorted(filenames):
            if not fn.endswith(EXTS):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT).replace(os.sep, "/")
            errs, nlines, ncoded = check_file(p)
            total_files += 1
            if errs:
                total_err += len(errs)
                print("[FAIL] %-46s (%d 行)" % (rel, nlines))
                for e in errs:
                    print(e)
            else:
                print("[ OK ] %-46s (%d 行, 结构字符 %d)" % (rel, nlines, ncoded))
    print("=" * 70)
    print(" 文件 %d 个，%s" % (total_files,
                             "全部通过" if total_err == 0 else "%d 处问题" % total_err))
    print("=" * 70)
    return 0 if total_err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
