#!/usr/bin/env python3
"""领域词补全：把清华开放中文词库 THUOCL（https://github.com/thunlp/THUOCL ，仅供学术 / 个人使用）里词典缺的词补进来 → tools/extra_domain.txt（build_dict.py 读）。
缺口（2026-10-25 测）：高血压、白血病、血小板、耳熟能详、深思熟虑、海南省、番禺 都打不出来。
拼音用 pypinyin 的词组读音（pip install --target <目录> pypinyin；放 sys.path）。权重（rime 口径，q = ln(权重 + 1) × 2048）按 THUOCL 词频折算，
故意压得比日常词低（打整词时照样排第一，整句里不抢常用词）。
用法：python3 tools/build_domain_words.py <放 thuocl_*.txt 的目录> <pypinyin 所在目录> tools/extra_domain.txt"""
import os, sys

src, pylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, pylib)
sys.path.insert(0, HERE)
from pypinyin import lazy_pinyin, Style
import pyengine

D = pyengine.Dict(os.path.join(HERE, "..", "Keyboard", "Resources", "pinyin.dat"))
have = set(D.entry_raw(i)[0] for i in range(D.n))
SYL = set(open(os.path.join(HERE, "syllables.txt")).read().split())

# 名字 → （取词频最高的前 N 个, 权重 = base + count × k, 权重上限, 最少几个字）
SOURCES = {
    "chengyu": (100000, 1200, 1.0, 6000, 4),
    "medical": (100000, 800, 1.0, 40000, 3),
    "caijing": (100000, 500, 0.5, 8000, 3),
    "law": (4000, 400, 0.5, 4000, 4),
    "food": (3000, 400, 1.0, 3000, 3),
    "animal": (3000, 300, 1.0, 3000, 3),
    "car": (800, 300, 1.0, 2000, 3),
    "diming": (12000, 300, 0.05, 3000, 3),
}
rows = []
seen = set()
for name, (top, base, k, cap, minlen) in SOURCES.items():
    f = os.path.join(src, f"thuocl_{name}.txt")
    items = []
    for l in open(f, encoding="utf-8-sig"):
        p = l.split()
        if len(p) >= 2 and p[1].isdigit():
            items.append((p[0].lstrip("﻿"), int(p[1])))
    items.sort(key=lambda x: -x[1])
    n = 0
    for w, c in items[:top]:
        if w in have or w in seen or len(w) < minlen and name != "medical" or len(w) < 2 or len(w) > (6 if name == "diming" else 8) or c < (20 if name == "medical" else 0):
            continue
        if not all("一" <= ch <= "鿿" for ch in w):
            continue
        syl = lazy_pinyin(w, style=Style.NORMAL)
        if len(syl) != len(w) or not all(s in SYL for s in syl):
            continue
        seen.add(w)
        rows.append((w, " ".join(syl), int(min(cap, base + c * k))))
        n += 1
    print(name, n)
with open(out, "w", encoding="utf8") as fo:
    fo.write("# 领域词补全（tools/build_domain_words.py 生成，THUOCL 词频折算；格式同 extra_words.txt：词<TAB>拼音<TAB>权重）\n")
    for w, s, q in rows:
        fo.write(f"{w}\t{s}\t{q}\n")
print(len(rows), "条", os.path.getsize(out), "字节")
