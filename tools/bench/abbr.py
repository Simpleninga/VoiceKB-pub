#!/usr/bin/env python3
"""简拼跑分：chat 句子只打每个字的声母 / 首字母（你吃饭了吗 → ncflm），看第一个 / 前三个候选里有没有原句；
--mixed：一半的字打全拼、一半打首字母（混拼，nichflm 这种）。用法：python3 tools/bench/abbr.py [--mixed] [--fails]"""
import os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pyengine

RES = os.path.join(ROOT, "Keyboard", "Resources")
D = pyengine.Dict(os.path.join(RES, "pinyin.dat"))
pyengine.load_syllables(os.path.join(ROOT, "tools", "syllables.txt"))
lm = pyengine.LM(os.path.join(RES, "lm.dat"))
rng = random.Random(1)
rows = []
for l in open(os.path.join(HERE, "data", "chat.tsv"), encoding="utf8"):
    f = l.rstrip("\n").split("\t")
    if len(f) >= 3:
        rows.append((f[0], f[2].split()))
def arg(name, default):
    return next((a.split("=", 1)[1] for a in sys.argv if a.startswith(f"--{name}=")), default)
pyengine.PEN_ABBR = int(float(arg("pen", 2.4)) * 2048)
pyengine.ABBR_WORDS = int(arg("words", 6))
pyengine.ABBR_CHARS = int(arg("chars", 10))
pyengine.ABBR_MAX = int(arg("max", 5))
pyengine.BEAM = int(arg("beam", 4))
mixed = "--mixed" in sys.argv
ok1 = ok3 = 0
fails = []
for s, syls in rows:
    typed = "".join((t if (mixed and rng.random() < 0.5) else t[0]) for t in syls)
    c = pyengine.candidates(D, typed, 14, False, lm, None)
    texts = [x[0] for x in c if x[1] == len(typed)]
    if texts and texts[0] == s:
        ok1 += 1
    if s in texts[:3]:
        ok3 += 1
    else:
        fails.append(f"{s}\t{typed}\t{' '.join(x[0] for x in c[:4])}")
n = len(rows)
print(f"{'混拼' if mixed else '纯简拼'}：首选 {ok1}/{n} = {ok1 / n:.1%}，前三 {ok3}/{n} = {ok3 / n:.1%}")
if "--fails" in sys.argv:
    print("\n".join(fails[:25]))
