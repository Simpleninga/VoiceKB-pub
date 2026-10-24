#!/usr/bin/env python3
"""第二遍：数三元语法（词 a b 后面紧跟 c 出现几次），只数「上下文词对 (a, b) 已经够常见」的（词对出现次数 ≥ MIN_PAIR，来自合并后的二元计数）——
全数的话内存放不下（几千万种三元），而不常见的上下文本来也学不到什么。
用法：<语料 stdin，一行一句> | nice python3 count_trigrams.py <pinyin.dat> <二元计数.pkl> <输出 tri.pkl> [MIN_PAIR=30] [最多处理多少行]
词表、切词、标点处理和 count_bigrams.py 完全一样（词表取二元计数文件里的 vocab，保证 id 对得上）。"""
import math, pickle, re, sys, time
sys.path.insert(0, __file__.rsplit("/", 2)[0])
import jieba, pyengine

dat, bipkl, out = sys.argv[1], sys.argv[2], sys.argv[3]
MIN_PAIR = float(sys.argv[4]) if len(sys.argv) > 4 else 30
maxlines = int(sys.argv[5]) if len(sys.argv) > 5 else 10 ** 9
PUNCT = {",": "，", "，": "，", ".": "。", "。": "。", "?": "？", "？": "？", "!": "！", "！": "！", "…": "…", "...": "…",
         "、": "、", ":": "：", "：": "：", ";": "；", "；": "；"}
SHIFT = 17

m = pickle.load(open(bipkl, "rb"))
vocab = m["vocab"]
ids = {w: i for i, w in enumerate(vocab)}
pairs = {k for k, c in m["cnt"].items() if c >= MIN_PAIR}
print("词表", len(vocab), "上下文词对", len(pairs), flush=True)
del m

D = pyengine.Dict(dat)
best = {}
for i in range(D.n):
    w, q = D.entry(i)
    if w in ids and q > best.get(w, -1):
        best[w] = q
jieba.setLogLevel(60)
jieba.initialize()
FREQ, total = {}, 0
for w, q in best.items():
    if w in ("<unk>", "<s>") or w in PUNCT.values():
        continue
    f = max(1, round(math.exp(q) - 1))
    FREQ[w] = f
    total += f
    for k in range(1, len(w)):
        FREQ.setdefault(w[:k], 0)
jieba.dt.FREQ = FREQ
jieba.dt.total = total
cjk = re.compile(r"[一-鿿]")
junk = re.compile(r"字幕|翻译|校对|www|http|制作|压制|@|sub|Sub|时间轴")
cnt = {}
t0 = time.time()
n = 0
for line in sys.stdin:
    line = line.strip()
    if len(line) < 2 or junk.search(line) or len(cjk.findall(line)) < len(line) * 0.5:
        continue
    n += 1
    if n > maxlines:
        break
    a, b = 0, 1          # 0 = 没有上文；1 = <s>
    for tok in jieba.cut(line, HMM=False):
        tok = tok.strip()
        if not tok:
            continue
        w = PUNCT.get(tok)
        i = ids.get(w if w else tok, 0)
        if i == 0 and not w and not cjk.search(tok):
            continue
        if a and b and i and (a << SHIFT | b) in pairs:
            k = a << (2 * SHIFT) | b << SHIFT | i
            cnt[k] = cnt.get(k, 0) + 1
        a, b = (b, i) if i else (0, 0)
    if n % 200000 == 0:
        print(f"{n} 行 {time.time() - t0:.0f}s 三元 {len(cnt)}", flush=True)
        if len(cnt) > 7_000_000:
            cnt = {k: c for k, c in cnt.items() if c > 1}
            print("  剪枝后", len(cnt), flush=True)
cnt = {k: c for k, c in cnt.items() if c > 1}
pickle.dump({"vocab": vocab, "cnt": cnt, "lines": n}, open(out, "wb"))
print("完成", n, "行", len(cnt), "个三元", f"{time.time() - t0:.0f}s", flush=True)
