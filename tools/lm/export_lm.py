#!/usr/bin/env python3
"""把二元语法计数（count_bigrams.py 的输出）压成键盘用的二进制语言模型 Keyboard/Resources/lm.dat。
用法：python3 export_lm.py <counts.pkl> <pinyin.dat> <输出 lm.dat> [最少出现次数，默认 2]

平滑：P(b|a) = (c_ab + K_a·P_uni(b)) / (c_a + K_a)，P_uni 用键盘词典的一元权重（pinyin.dat，网页语料）。
K_a = max(20, 5 × a 见过的不同后继词数)（Witten-Bell 思路，2026-10-24 起 3 倍，10-25 重做语料后扫参数改成 5 倍：K 在 5~12 是平台，3 倍低 8 句）：后面接过的词越杂，没见过的词对越常见、罚得越轻。
原来固定 K = 20 时，「我」「数据」这种常用词后面接没见过的词要罚 11 纳特，冷僻词几乎不罚，整句选词就爱走冷僻词
（数据有点问题 → 书局有点问题）；改后跑分 聊天 71.8% → 80.0%、用户句子 43% → 54%。
代价一律是整数（单位 1/2048 纳特），键盘和 Python 参考实现都只做整数加法，两边结果才能逐字一致：
  已见过的词对：存 -ln P(b|a)；没见过的：一元代价 + 回退代价 backoff(a) = ln((c_a + K_a) / K_a)。

格式（小端）：
  头 40 字节：魔数 "LMD1"、词数 V、词对数 P、词偏移表偏移、词串偏移、回退表偏移、区间表偏移、后继词表偏移、代价表偏移
  词按 UTF-8 字节序排（id = 排序后的下标），词偏移表 (V+1) × u32；回退表 V × u16；
  区间表 (V+1) × u32：a 的词对在 [range[a], range[a+1])，后继词 id 升序；后继词表 P × u32；代价表 P × u16
"""
import math, pickle, struct, sys
sys.path.insert(0, __file__.rsplit("/", 2)[0])
import pyengine

cnts, dat, out = sys.argv[1], sys.argv[2], sys.argv[3]
minc = int(sys.argv[4]) if len(sys.argv) > 4 else 2
K_MIN, K_PER_FOLLOWER = 20.0, 5.0
PUNCT_SCALE = 0.35
SHIFT = 17
U = 2048

m = pickle.load(open(cnts, "rb"))
vocab, cnt, left = m["vocab"], m["cnt"], m["left"]

D = pyengine.Dict(dat)
q = {}
for i in range(D.n):
    w, qq = D.entry(i)
    if qq > q.get(w, -1):
        q[w] = qq
PUNCT_Q = 9.0       # 标点、<s>、<unk> 不在词典里：给个中等的一元权重（只影响没见过的词对）

order = sorted(range(len(vocab)), key=lambda i: vocab[i].encode("utf8"))
newid = {old: new for new, old in enumerate(order)}
words = [vocab[old] for old in order]
V = len(words)

# 词典里有很多复合词（我的、我们、待会儿…），语料按词典切词时它们是一个词，「我」后面就接不上「的」「们」了。
# 补一份「拆开的」词对：词 t = a + r，a 和 r 都在词表里，就给 (a, r) 加上 t 自己出现的次数（left[t] 近似 t 的出现次数）
oldid = {w: i for i, w in enumerate(vocab)}
extra = {}
for t, ti in oldid.items():
    if len(t) < 2 or ti < 2 + len(set("，。？！…、：；")):
        continue
    ct = left.get(ti, 0)
    if ct < minc:
        continue
    for k in range(1, len(t)):
        a, r = oldid.get(t[:k]), oldid.get(t[k:])
        if a is not None and r is not None:
            extra[a << SHIFT | r] = extra.get(a << SHIFT | r, 0) + ct
for k, c in extra.items():
    cnt[k] = cnt.get(k, 0) + c
    left[k >> SHIFT] = left.get(k >> SHIFT, 0) + c
PUNCTS = set("，。？！…、：；")
by_a = {}
for k, c in cnt.items():
    if c < minc:
        continue
    a, b = k >> SHIFT, k & ((1 << SHIFT) - 1)
    if vocab[b] in PUNCTS:
        c = c * PUNCT_SCALE         # 标点只影响联想预测的排序（整句选词里没有「词 + 标点」）：字幕里断句很碎，别让「，」总排第一
    by_a.setdefault(newid[a], []).append((newid[b], c))

back = []
ranges = [0]
bs, costs = [], []
for a in range(V):
    ca = left.get(oldid[words[a]], 0)
    K = max(K_MIN, K_PER_FOLLOWER * len(by_a.get(a, [])))
    back.append(min(65535, round(math.log((ca + K) / K) * U)))
    for b, c in sorted(by_a.get(a, [])):
        pu = math.exp(q.get(words[b], PUNCT_Q) - 21.0 * 1.0)     # q 是 ln(权重+1)，LN_TOTAL = 21
        p = (c + K * pu) / (ca + K)
        bs.append(b)
        costs.append(max(0, min(65535, round(-math.log(p) * U))))
    ranges.append(len(bs))
P = len(bs)

blob = bytearray()
woff = [0]
for w in words:
    blob += w.encode("utf8")
    woff.append(len(blob))

hdr = 40
off_woff = hdr
off_blob = off_woff + 4 * (V + 1)
off_back = off_blob + len(blob)
off_back += (-off_back) % 4
off_range = off_back + 2 * V
off_range += (-off_range) % 4
off_b = off_range + 4 * (V + 1)
off_cost = off_b + 4 * P
with open(out, "wb") as f:
    f.write(struct.pack("<4sIIIIIIII4x", b"LMD1", V, P, off_woff, off_blob, off_back, off_range, off_b, off_cost))
    f.write(struct.pack("<%dI" % (V + 1), *woff))
    f.write(blob)
    f.write(b"\0" * (off_back - off_blob - len(blob)))
    f.write(struct.pack("<%dH" % V, *back))
    f.write(b"\0" * (off_range - off_back - 2 * V))
    f.write(struct.pack("<%dI" % (V + 1), *ranges))
    f.write(struct.pack("<%dI" % P, *bs))
    f.write(struct.pack("<%dH" % P, *costs))
print(f"词 {V}，词对 {P}（最少出现 {minc} 次），文件 {off_cost + 2 * P} 字节")
