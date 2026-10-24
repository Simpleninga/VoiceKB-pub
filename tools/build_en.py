#!/usr/bin/env python3
"""英文联想词表：按词频从高到低，一行一个小写单词（只含 a-z）。
用法：pip install wordfreq（装在临时 venv 里就行），再 python3 build_en.py Keyboard/Resources/enwords.txt [词数]
数据来自 wordfreq（代码 Apache-2.0，数据 CC-BY-SA 4.0），自用。"""
import re, sys
from wordfreq import top_n_list

out = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 30000
seen, words = set(), []
for w in top_n_list("en", n * 3):
    if not re.fullmatch(r"[a-z]+", w) or w in seen:
        continue
    if len(w) == 1 and w not in ("a", "i"):
        continue
    seen.add(w)
    words.append(w)
    if len(words) >= n:
        break
open(out, "w").write("\n".join(words) + "\n")
print(len(words), "words ->", out)
