#!/usr/bin/env python3
"""合并几份三元计数（count_trigrams.py 的输出，词表必须相同）：python3 merge_tri.py <输出.pkl> a.pkl:权重 b.pkl:权重 …"""
import pickle, sys

out = sys.argv[1]
cnt, vocab, lines = {}, None, 0
for a in sys.argv[2:]:
    f, _, w = a.partition(":")
    wt = float(w) if w else 1.0
    m = pickle.load(open(f, "rb"))
    assert vocab is None or vocab == m["vocab"], "词表不一致：" + f
    vocab = m["vocab"]
    for k, c in m["cnt"].items():
        cnt[k] = cnt.get(k, 0) + c * wt
    lines += m.get("lines", 0)
    print(f, wt, len(m["cnt"]), flush=True)
pickle.dump({"vocab": vocab, "cnt": cnt, "lines": lines}, open(out, "wb"))
print("合并后", len(cnt))
