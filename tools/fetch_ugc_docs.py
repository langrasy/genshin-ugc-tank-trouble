# -*- coding: utf-8 -*-
"""
下载《原神·千星奇域》官方文档并转换为干净的 Markdown，供离线随时查阅。

数据源（2026-10 实测）：
  知识库  https://act-webstatic.mihoyo.com/ugc-tutorial/knowledge/cn/zh-cn
  教程课程 https://act-webstatic.mihoyo.com/ugc-tutorial/course/cn/zh-cn
  常见问题 https://act-webstatic.mihoyo.com/ugc-tutorial/faq/cn/zh-cn
三者结构一致：
  目录  {base}/catalog.json
  正文  {base}/{path_id}/content.html

转换流水线：
  content.html -> 清洗（去 style/class/data-*、展开合并单元格、拆 div/span 包裹）
               -> 表格转成 GFM 管道表格（占位符方式回填）
               -> pandoc(html -> gfm) -> 干净的 Markdown -> 按官方目录层级落盘

用法：
  python tools/fetch_ugc_docs.py                 # 下载 + 清洗 + 转换（已存在的正文会跳过）
  python tools/fetch_ugc_docs.py --force         # 强制重新下载
  python tools/fetch_ugc_docs.py --reconvert     # 不联网下载，仅用 _raw 里的 HTML 重新清洗转换
  python tools/fetch_ugc_docs.py --only course   # 只处理指定分区（逗号分隔，可多个）
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

from bs4 import BeautifulSoup
from bs4.element import NavigableString

# Windows 上 pandoc 是 .cmd 批处理垫片，CreateProcess 不会自动补 PATHEXT，
# 必须用 which() 解析出带扩展名的完整路径，否则 subprocess 会 FileNotFoundError。
PANDOC = shutil.which("pandoc")

QUERY = "?v=1016&game_biz=hk4eugc_cn&lang=zh-cn"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "ugc_official")
RAW = os.path.join(OUT, "_raw")

_TP = "https://act-webstatic.mihoyo.com/ugc-tutorial/%s/cn/zh-cn"

# 官方文档分三个分区，正文 URL 规则完全一致，因此用同一套逻辑处理。
# 知识库沿用 OUT / _raw 根目录（保持历史路径不变），课程与 FAQ 收进各自子目录。
SECTIONS = [
    {"key": "knowledge", "label": "知识库",
     "base": _TP % "knowledge", "raw": RAW, "out": OUT},
    {"key": "course", "label": "教程课程",
     "base": _TP % "course", "raw": os.path.join(RAW, "course"),
     "out": os.path.join(OUT, "教程课程")},
    {"key": "faq", "label": "常见问题",
     "base": _TP % "faq", "raw": os.path.join(RAW, "faq"),
     "out": os.path.join(OUT, "常见问题")},
]

UA = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/126.0 Safari/537.36",
    "Referer": "https://act.mihoyo.com/ys/ugc/tutorial/index.html",
}

BAD = re.compile(r'[\\/:*?"<>|\r\n\t]')

# 与本项目（坦克动荡移植）直接相关的重点文档，用于生成 README 的「本项目重点」索引
HIGHLIGHTS = [
    ("客户端控件 API（渲染/输入/音效/时停）", "附录/客户端控件API文档.md"),
    ("界面控件与客户端脚本（控件池/生命周期）", "概念介绍/高级概念/界面控件组管理/客户端控件和客户端脚本.md"),
    ("界面布局", "概念介绍/高级概念/界面控件组管理/界面布局.md"),
    ("背景音乐", "概念介绍/其它概念/背景音乐.md"),
    ("环境配置（音效资源）", "概念介绍/其它概念/环境配置.md"),
    ("多语言文本", "概念介绍/其它概念/多语言文本.md"),
    ("局内存档", "概念介绍/其它概念/局内存档.md"),
    ("成就", "概念介绍/高级概念/外围系统/成就.md"),
    ("排行榜", "概念介绍/高级概念/外围系统/排行榜.md"),
    ("竞技段位", "概念介绍/高级概念/外围系统/竞技段位.md"),
    ("关卡结算", "概念介绍/高级概念/外围系统/关卡结算.md"),
    ("奇匠订阅", "概念介绍/高级概念/外围系统/奇匠订阅.md"),
    ("奇域礼盒", "概念介绍/高级概念/外围系统/奇域礼盒.md"),
    ("奇域任务", "概念介绍/高级概念/外围系统/奇域任务.md"),
    ("多人试玩（联机）", "界面介绍/多人试玩.md"),
    ("语音和文字聊天", "概念介绍/其它概念/语音和文字聊天.md"),
    ("特效", "概念介绍/资产/特效.md"),
    ("特效器", "概念介绍/高级概念/特效器.md"),
    ("护盾", "概念介绍/高级概念/护盾.md"),
    ("关卡设置", "界面介绍/关卡设置.md"),
]


# --------------------------------------------------------------------------
# 网络
# --------------------------------------------------------------------------
def sanitize(name, limit=80):
    s = BAD.sub("_", (name or "").strip())
    s = re.sub(r"\s+", " ", s).strip(" .")
    return (s[:limit] or "untitled")


def get(url, retries=3):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (i + 1))
    raise RuntimeError("下载失败 %s: %s" % (url, last))


def walk(nodes, parents, acc):
    for n in nodes:
        title = n.get("title") or ""
        pid = n.get("path_id")
        chain = parents + [sanitize(title)]
        if pid:
            acc.append({"path_id": pid, "title": title, "chain": chain,
                        "doc_type": n.get("doc_type", ""), "updated": n.get("updated_at", "")})
        if n.get("children"):
            walk(n["children"], chain, acc)
    return acc


# --------------------------------------------------------------------------
# HTML 清洗：把带行内样式的富文本片段，压成 pandoc 能干净转换的语义化 HTML
#
# 表格单独处理：pandoc 的 GFM 写出器无法容纳带 <br> 的单元格（会退回原始
# HTML），所以这里自己把表格序列化成 GFM 管道表格，先用占位符顶替，等
# pandoc 转完正文后再回填。
# --------------------------------------------------------------------------
TABLE_TOKEN = "@@UGC_TABLE_%d@@"


def _grid(table):
    """把含 rowspan/colspan 的表格展开成规则网格（GFM 不支持合并单元格）。"""
    rows = table.find_all("tr")
    if not rows:
        return []
    grid = []
    pending = {}  # 列号 -> (剩余跨行数, 单元格对象)
    for tr in rows:
        cells = tr.find_all(["td", "th"], recursive=False) or tr.find_all(["td", "th"])
        row = []
        col = 0
        idx = 0
        while idx < len(cells) or any(c >= col for c in pending):
            if col in pending:
                rem, cell = pending[col]
                row.append(cell)
                if rem - 1 <= 0:
                    del pending[col]
                else:
                    pending[col] = (rem - 1, cell)
                col += 1
                continue
            if idx < len(cells):
                cell = cells[idx]
                idx += 1
                try:
                    rs = max(1, int(cell.get("rowspan", 1) or 1))
                except (TypeError, ValueError):
                    rs = 1
                try:
                    cs = max(1, int(cell.get("colspan", 1) or 1))
                except (TypeError, ValueError):
                    cs = 1
                for k in range(cs):
                    row.append(cell)
                    if rs > 1:
                        pending[col + k] = (rs - 1, cell)
                col += cs
                continue
            break
        grid.append(row)

    width = max(len(r) for r in grid) if grid else 0
    if width == 0:
        return []
    for r in grid:
        while len(r) < width:
            r.append(None)
    return grid


_TEXT_ESC = re.compile(r"([\\`*_\[\]])")


def _inline_md(node):
    """把单元格内部的节点序列化成行内 Markdown（<br> 保留为行内 HTML）。"""
    out = []
    for child in node.children:
        if isinstance(child, NavigableString):
            out.append(_TEXT_ESC.sub(r"\\\1", str(child)))
            continue
        name = child.name
        if name == "br":
            out.append("<br />")
        elif name in ("em", "i"):
            out.append("*%s*" % _inline_md(child))
        elif name in ("strong", "b"):
            out.append("**%s**" % _inline_md(child))
        elif name == "img":
            out.append("![%s](%s)" % (child.get("alt", "") or "", child.get("src", "")))
        elif name == "a":
            out.append("[%s](%s)" % (_inline_md(child), child.get("href", "")))
        elif name == "code":
            out.append("`%s`" % child.get_text().strip())
        elif name in ("p", "div"):
            out.append(_inline_md(child) + "<br />")
        elif name in ("ul", "ol"):
            for li in child.find_all("li", recursive=False):
                out.append("<br />" + _inline_md(li))
        elif name == "table":
            out.append("（嵌套表格，见原文）")
        else:
            out.append(_inline_md(child))
    return "".join(out)


def _cell_md(cell):
    if cell is None:
        return ""
    s = _inline_md(cell)
    s = re.sub(r"\s+", " ", s)                # 换行/多空格压成单空格
    s = re.sub(r"^(?:\s*<br />\s*)+", "", s)  # 去掉开头多余的换行
    s = re.sub(r"(?:\s*<br />\s*)+$", "", s)  # 去掉结尾多余的换行
    s = s.replace("|", "\\|").strip()
    return s


def _table_to_md(table):
    """把一张 HTML 表格序列化成 GFM 管道表格。"""
    grid = _grid(table)
    if not grid:
        return ""
    cells = [[_cell_md(c) for c in row] for row in grid]
    width = len(cells[0])
    lines = ["| " + " | ".join(cells[0]) + " |",
             "|" + "|".join([" --- "] * width) + "|"]
    for row in cells[1:]:
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)


def clean_html(text):
    """清洗正文 HTML，返回 (清洗后的 HTML, {表格序号: 管道表格 Markdown})。"""
    soup = BeautifulSoup(text, "lxml")

    # 1) 表格 -> 占位符（须在剥离属性之前，因为要读 rowspan/colspan）
    tables = {}
    for i, table in enumerate(soup.find_all("table")):
        if table.parent is None:
            continue
        tables[i] = _table_to_md(table)
        table.replace_with(NavigableString("\n\n" + (TABLE_TOKEN % i) + "\n\n"))

    # 2) 拆掉纯包裹用的 div / span（保留其文字与子元素）
    for el in soup.find_all(["div", "span"]):
        el.unwrap()

    # 3) 只保留有语义的属性：链接 href、图片 src/alt
    for tag in soup.find_all(True):
        keep = {}
        if tag.name == "a" and tag.get("href"):
            keep["href"] = tag["href"]
        if tag.name == "img" and tag.get("src"):
            keep["src"] = tag["src"]
            if tag.get("alt"):
                keep["alt"] = tag["alt"]
        tag.attrs = keep

    # 4) 丢弃 colgroup/col 等仅用于排版的元素
    for el in soup.find_all(["colgroup", "col"]):
        el.decompose()

    body = soup.body
    return (body.decode_contents() if body else str(soup)), tables


# 兜底：pandoc 偶尔仍会输出零散的 HTML 排版噪音，这里统一清掉。
_MD_NOISE = [
    (re.compile(r"<colgroup\b[^>]*>.*?</colgroup>", re.S | re.I), ""),
    (re.compile(r"<col\b[^>]*/?>", re.I), ""),
    (re.compile(r"</?span\b[^>]*>", re.I), ""),
    (re.compile(r"\s(?:style|class|align|valign|width|height|data-[\w-]+)=('[^']*'|\"[^\"]*\")",
                re.I), ""),
]


def clean_md(text):
    for pat, repl in _MD_NOISE:
        text = pat.sub(repl, text)
    return text


def run_pandoc(html_path, md_path):
    if PANDOC is None:
        raise RuntimeError("未找到 pandoc，请先安装并加入 PATH")
    cmd = [PANDOC, "-f", "html", "-t", "gfm", "--wrap=none",
           "--markdown-headings=atx", html_path, "-o", md_path]
    subprocess.run(cmd, check=True, capture_output=True)


def convert(html_path, md_path):
    """读取原始 HTML -> 清洗 -> pandoc 转 GFM -> 回填表格 -> 兜底清理。"""
    with open(html_path, "r", encoding="utf-8") as f:
        raw = f.read()
    cleaned, tables = clean_html(raw)
    tmp = html_path + ".clean.html"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(cleaned)
    try:
        run_pandoc(tmp, md_path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    with open(md_path, "r", encoding="utf-8") as f:
        md = f.read()
    for i, table_md in tables.items():
        md = md.replace(TABLE_TOKEN % i, table_md)
    md = clean_md(md)
    with open(md_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(md)


def to_md(html_bytes, html_path, md_path):
    with open(html_path, "wb") as f:
        f.write(html_bytes)
    convert(html_path, md_path)


# --------------------------------------------------------------------------
# 输出：按官方目录层级落盘 + 生成 README 索引
# --------------------------------------------------------------------------
def fetch_catalog(sec):
    """下载某分区的 catalog.json，返回扁平化的文档列表。"""
    cat = json.loads(get(sec["base"] + "/catalog.json" + QUERY).decode("utf-8"))
    os.makedirs(sec["raw"], exist_ok=True)
    with open(os.path.join(sec["raw"], "catalog.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(cat, f, ensure_ascii=False, indent=1)
    return walk(cat, [], [])


def process_section(sec, docs, force, reconvert):
    """下载 / 转换某分区的全部正文，返回 (处理, 跳过, 失败)。"""
    ok = fail = skip = 0
    for i, d in enumerate(docs, 1):
        pid = d["path_id"]
        html_path = os.path.join(sec["raw"], pid + ".html")
        md_path = os.path.join(sec["raw"], pid + ".md")
        try:
            if reconvert:
                if not os.path.exists(html_path):
                    skip += 1
                else:
                    convert(html_path, md_path)
                    ok += 1
            elif not force and os.path.exists(md_path):
                skip += 1
            elif not force and os.path.exists(html_path):
                convert(html_path, md_path)  # HTML 已下但 MD 缺失：只补转换
                ok += 1
            else:
                to_md(get(sec["base"] + "/" + pid + "/content.html" + QUERY), html_path, md_path)
                ok += 1
        except Exception as e:  # noqa: BLE001
            fail += 1
            print("      [失败] %s %s -> %s" % (pid, d["title"], e))
        if i % 20 == 0:
            print("      %d/%d" % (i, len(docs)))
    return ok, skip, fail


def write_section(sec, docs):
    """把某分区文档按目录层级落盘，返回 (输出篇数, [(章节, 标题, 相对路径)])。"""
    made = 0
    rows = []
    for d in docs:
        md_path = os.path.join(sec["raw"], d["path_id"] + ".md")
        if not os.path.exists(md_path):
            continue
        with open(md_path, "r", encoding="utf-8") as f:
            body = f.read().strip()
        rel_dir = os.path.join(*d["chain"][:-1]) if len(d["chain"]) > 1 else ""
        fname = d["chain"][-1] + ".md"
        dest_dir = os.path.join(sec["out"], rel_dir) if rel_dir else sec["out"]
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, fname)
        head = ["# %s" % d["title"], "",
                "> 章节：%s" % " / ".join(d["chain"]),
                "> 来源：%s/%s/content.html" % (sec["base"], d["path_id"]),
                "> 更新时间：%s" % d.get("updated", ""), "", "---", ""]
        with open(dest, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(head) + body + "\n")
        made += 1
        rows.append((" / ".join(d["chain"][:-1]) or "（顶层）",
                     d["title"],
                     os.path.relpath(dest, OUT).replace("\\", "/")))
    return made, rows


def write_readme(section_rows):
    """生成总索引 README（本项目重点 + 各分区全量目录）。"""
    lines = ["# 原神·千星奇域 官方文档（离线归档）", "",
             "来源：https://act.mihoyo.com/ys/ugc/tutorial/index.html", "",
             "重新抓取：`python tools/fetch_ugc_docs.py`（已存在的正文会跳过，"
             "加 `--force` 强制重下）", "",
             "仅重新转换：`python tools/fetch_ugc_docs.py --reconvert`", "",
             "## 本项目重点", "",
             "| 主题 | 文档 |", "| --- | --- |"]
    for label, rel in HIGHLIGHTS:
        if os.path.exists(os.path.join(OUT, rel)):
            lines.append("| %s | [%s](%s) |" % (label, rel.split("/")[-1][:-3], rel))

    for sec, rows in section_rows:
        if not rows:
            continue
        lines += ["", "## %s（%d 篇）" % (sec["label"], len(rows)), "",
                  "| 章节 | 文件 |", "| --- | --- |"]
        for chain, title, rel in rows:
            lines.append("| %s | [%s](%s) |" % (chain, title, rel))

    with open(os.path.join(OUT, "README.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main():
    force = "--force" in sys.argv
    reconvert = "--reconvert" in sys.argv
    only = None
    if "--only" in sys.argv:
        idx = sys.argv.index("--only")
        if idx + 1 < len(sys.argv):
            only = set(x.strip() for x in sys.argv[idx + 1].split(",") if x.strip())

    os.makedirs(OUT, exist_ok=True)
    for sec in SECTIONS:
        os.makedirs(sec["raw"], exist_ok=True)

    totals = {"ok": 0, "skip": 0, "fail": 0, "made": 0}
    section_rows = []
    for sec in SECTIONS:
        if only and sec["key"] not in only:
            continue
        print("\n=== [%s] %s ===" % (sec["key"], sec["label"]))
        print("[1/3] 获取目录 catalog.json")
        docs = fetch_catalog(sec)
        print("      共 %d 篇文档" % len(docs))

        print("[2/3] %s 正文并转 Markdown" % ("清洗重转" if reconvert else "下载"))
        ok, skip, fail = process_section(sec, docs, force, reconvert)

        print("[3/3] 按目录层级输出")
        made, rows = write_section(sec, docs)
        print("      输出 %d 篇（处理 %d / 跳过 %d / 失败 %d）" % (made, ok, skip, fail))

        section_rows.append((sec, rows))
        totals["ok"] += ok
        totals["skip"] += skip
        totals["fail"] += fail
        totals["made"] += made

    write_readme(section_rows)
    print("\n全部完成：输出 %d 篇（处理 %d / 跳过 %d / 失败 %d）"
          % (totals["made"], totals["ok"], totals["skip"], totals["fail"]))
    print("目录：%s" % OUT)


if __name__ == "__main__":
    main()
