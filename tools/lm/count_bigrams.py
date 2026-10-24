#!/usr/bin/env python3
"""从中文口语语料（stdin，一行一句）数二元语法：词 a 后面紧跟词 b 出现几次。
用法：curl -s <OpenSubtitles zh_cn.txt.gz> | gunzip | nice python3 count_bigrams.py <pinyin.dat> <输出 counts.pkl> [最多处理多少行]

词表 = 键盘词典（pinyin.dat）里权重最高的 8 万个词 + 标点；语料用 jieba 切词（只切，不用 HMM），
切出来不在词表里的算「未登录」，断开上下文。标点统一成全角（, . ? ! → ，。？！），句首记一个 <s>。
"""
import math, pickle, re, struct, sys, time
sys.path.insert(0, __file__.rsplit("/", 2)[0])
import jieba, pyengine

dat, out = sys.argv[1], sys.argv[2]
maxlines = int(sys.argv[3]) if len(sys.argv) > 3 else 10 ** 9
VOCAB = 80000
PUNCT = {",": "，", "，": "，", ".": "。", "。": "。", "?": "？", "？": "？", "!": "！", "！": "！", "…": "…", "...": "…",
         "、": "、", ":": "：", "：": "：", ";": "；", "；": "；"}

D = pyengine.Dict(dat)
best = {}
for i in range(D.n):
    w, q = D.entry(i)
    if len(w) <= 6 and q > best.get(w, -1):
        best[w] = q
words = [w for w, _ in sorted(best.items(), key=lambda x: -x[1])[:VOCAB]]
vocab = ["<unk>", "<s>"] + sorted(set(PUNCT.values())) + words
ids = {w: i for i, w in enumerate(vocab)}
print("词表", len(vocab), flush=True)

# 切词用键盘自己的词典（词频 = 词典权重），不用 jieba 自带的词表：这样「待会」「发微信」这类词在语料里就是一个词，
# 词对统计出来的词和键盘引擎里的词一一对应（用 jieba 自带词表，待会 被切成 待 + 会，联想就空了）
jieba.setLogLevel(60)
jieba.initialize()
# 只用词表里的词切（2026-10-25）：原来用整本词典（30 万词）切，词表外的词（如「的时候」，权重刚好卡在第 8 万名外）
# 被切成一整块、再因为不在词表里记成「未登录」断开上下文，「的→时候」这种最常见的搭配几乎没统计到，整句选词时「时候」输给「事后」。
# 只用词表里的词切，词表外的会自动拆成词表里的小词，上下文不断。
FREQ = {}
total = 0
for w in words:
    q = best[w]
    f = max(1, round(math.exp(q) - 1))
    FREQ[w] = f
    total += f
    for k in range(1, len(w)):
        FREQ.setdefault(w[:k], 0)
jieba.dt.FREQ = FREQ
jieba.dt.total = total
cjk = re.compile(r"[一-鿿]")
junk = re.compile(r"字幕|翻译|校对|www|http|制作|压制|@|sub|Sub|时间轴")
SHIFT = 17
cnt = {}
left = {}
t0 = time.time()
n = 0
for line in sys.stdin:
    line = line.strip()
    if len(line) < 2 or junk.search(line) or len(cjk.findall(line)) < len(line) * 0.5:
        continue
    n += 1
    if n > maxlines:
        break
    prev = 1
    for tok in jieba.cut(line, HMM=False):
        tok = tok.strip()
        if not tok:
            continue
        w = PUNCT.get(tok)
        i = ids.get(w if w else tok, 0)
        if i == 0 and not w and not cjk.search(tok):
            continue            # 引号、破折号、数字、字母：忽略，不断开
        if prev and i:
            k = prev << SHIFT | i
            cnt[k] = cnt.get(k, 0) + 1
            left[prev] = left.get(prev, 0) + 1
        prev = i
    if n % 200000 == 0:
        print(f"{n} 行 {time.time() - t0:.0f}s 二元 {len(cnt)}", flush=True)
        if len(cnt) > 6_000_000:       # 内存要紧：只出现过一次的先扔
            cnt = {k: c for k, c in cnt.items() if c > 1}
            print("  剪枝后", len(cnt), flush=True)
cnt = {k: c for k, c in cnt.items() if c > 1}      # 只出现一次的二元没有信息量，也占地方（服务器硬盘紧）
pickle.dump({"vocab": vocab, "cnt": cnt, "left": left, "lines": n}, open(out, "wb"))
print("完成", n, "行", len(cnt), "个二元", f"{time.time() - t0:.0f}s", flush=True)
