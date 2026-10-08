# -*- coding: utf-8 -*-
"""
在离线归档的千星奇域官方文档中做全文检索，方便随时查 API。

用法：
  python tools/search_ugc_docs.py 客户端控件
  python tools/search_ugc_docs.py 计时器 玩家 --section faq
  python tools/search_ugc_docs.py OnUIInit --context 3
  python tools/search_ugc_docs.py --list                 # 只列出各分区文件
  python tools/search_ugc_docs.py --section course --list

参数：
  关键词...           一个或多个关键词（空格分隔），全部命中才算匹配（AND）
  --section a,b       只搜指定分区：knowledge / course / faq（默认全部）
  --context N         每个命中额外显示上下 N 行（默认 0）
  --max N             最多输出 N 条命中（默认 60）
  --files             只列出命中的文件，不打印行内容
  --list              不检索，改为列出文件清单
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "ugc_official")

SECTIONS = {
    "knowledge": OUT,
    "course": os.path.join(OUT, "教程课程"),
    "faq": os.path.join(OUT, "常见问题"),
}


def iter_md(section_keys):
    for key in section_keys:
        base = SECTIONS[key]
        for dirpath, dirnames, filenames in os.walk(base):
            # 跳过 _raw 缓存目录
            dirnames[:] = [d for d in dirnames if d != "_raw"]
            for fn in filenames:
                if fn.lower().endswith(".md"):
                    yield key, os.path.join(dirpath, fn)


def main():
    args = sys.argv[1:]
    section_keys = list(SECTIONS.keys())
    context = 0
    max_hits = 60
    files_only = False
    list_only = False
    words = []

    i = 0
    while i < len(args):
        a = args[i]
        if a == "--section" and i + 1 < len(args):
            section_keys = [s.strip() for s in args[i + 1].split(",") if s.strip() in SECTIONS]
            i += 2
            continue
        if a == "--context" and i + 1 < len(args):
            context = int(args[i + 1])
            i += 2
            continue
        if a == "--max" and i + 1 < len(args):
            max_hits = int(args[i + 1])
            i += 2
            continue
        if a == "--files":
            files_only = True
            i += 1
            continue
        if a == "--list":
            list_only = True
            i += 1
            continue
        words.append(a)
        i += 1

    if not section_keys:
        print("分区名无效，可选：knowledge / course / faq")
        return 1

    if list_only or not words:
        for key, path in iter_md(section_keys):
            print("%s\t%s" % (key, os.path.relpath(path, OUT).replace("\\", "/")))
        return 0

    # ASCII 关键词忽略大小写；含中文的关键词按原样匹配
    pats = []
    for w in words:
        flags = re.IGNORECASE if w.isascii() else 0
        pats.append(re.compile(re.escape(w), flags))

    hits = 0
    matched_files = []
    for key, path in iter_md(section_keys):
        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            continue

        file_hit = False
        for n, line in enumerate(lines):
            if not all(p.search(line) for p in pats):
                continue
            hits += 1
            file_hit = True
            if files_only:
                break
            rel = os.path.relpath(path, OUT).replace("\\", "/")
            print("\n%s:%d" % (rel, n + 1))
            lo = max(0, n - context)
            hi = min(len(lines), n + context + 1)
            for k in range(lo, hi):
                mark = ">" if k == n else " "
                print("  %s %s" % (mark, lines[k]))
            if hits >= max_hits:
                break
        if file_hit:
            matched_files.append((key, os.path.relpath(path, OUT).replace("\\", "/")))
        if hits >= max_hits:
            break

    if files_only:
        print("命中 %d 个文件：" % len(matched_files))
        for key, rel in matched_files:
            print("  [%s] %s" % (key, rel))
    else:
        print("\n命中 %d 处（上限 %d）" % (hits, max_hits))
    return 0


if __name__ == "__main__":
    sys.exit(main())
