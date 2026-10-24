#!/usr/bin/env python3
"""把几份二元计数（count_bigrams.py 的输出）按词合并成一份，每份可以乘一个权重。
用法：python3 merge_counts.py <输出.pkl> <主.pkl>[:权重] <另一份.pkl>:权重 …   （输出沿用主份的词表；别的份按词翻译 id，词表里没有的词对丢掉）"""
import pickle, sys

SHIFT = 17
out = sys.argv[1]
specs = []
for a in sys.argv[2:]:
    f, _, w = a.partition(":")
    specs.append((f, float(w) if w else 1.0))
main = pickle.load(open(specs[0][0], "rb"))
vocab = main["vocab"]
ids = {w: i for i, w in enumerate(vocab)}
cnt, left, lines = {}, {}, 0
for f, wt in specs:
    m = main if f == specs[0][0] else pickle.load(open(f, "rb"))
    tr = {i: ids.get(w) for i, w in enumerate(m["vocab"])}
    kept = 0
    for k, c in m["cnt"].items():
        a, b = tr.get(k >> SHIFT), tr.get(k & ((1 << SHIFT) - 1))
        if a is None or b is None:
            continue
        kk = a << SHIFT | b
        cnt[kk] = cnt.get(kk, 0) + c * wt
        kept += 1
    for a, c in m["left"].items():
        na = tr.get(a)
        if na is not None:
            left[na] = left.get(na, 0) + c * wt
    lines += m.get("lines", 0)
    print(f, "权重", wt, "词对", len(m["cnt"]), "保留", kept, flush=True)
pickle.dump({"vocab": vocab, "cnt": cnt, "left": left, "lines": lines}, open(out, "wb"))
print("合并后词对", len(cnt))
