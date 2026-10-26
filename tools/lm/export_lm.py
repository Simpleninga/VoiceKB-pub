#!/usr/bin/env python3
"""把二元语法计数（count_bigrams.py 的输出）压成键盘用的二进制语言模型 Keyboard/Resources/lm.dat。
用法：python3 export_lm.py <counts.pkl> <pinyin.dat> <输出 lm.dat> [最少出现次数，默认 2] [--tri=三元计数.pkl] [--mint=3] [--delta=0.2]
带 --tri 导出 LMD2（在二元之后挂三元，格式见下）：P3(c|a,b) = (c_abc + K3·P2(c|b)) / (c_ab + K3)，K3 = max(10, 3 × (a,b) 后面见过的不同词数)；
没见过的三元 = 二元代价 + 回退代价 tback(a,b) = ln((c_ab + K3)/K3)。只留出现 ≥ mint 次、而且比回退到二元的代价低 delta 纳特以上的三元（熵剪枝，控制文件大小）。

平滑：P(b|a) = (c_ab + K_a·P_uni(b)) / (c_a + K_a)，P_uni 用键盘词典的一元权重（pinyin.dat，网页语料）。
K_a = max(20, 5 × a 见过的不同后继词数)（Witten-Bell 思路，2026-10-24 起 3 倍，10-25 重做语料后扫参数改成 5 倍：K 在 5~12 是平台，3 倍低 8 句）：后面接过的词越杂，没见过的词对越常见、罚得越轻。
原来固定 K = 20 时，「我」「数据」这种常用词后面接没见过的词要罚 11 纳特，冷僻词几乎不罚，整句选词就爱走冷僻词
（数据有点问题 → 书局有点问题）；改后跑分 聊天 71.8% → 80.0%、用户句子 43% → 54%。
代价一律是整数（单位 1/2048 纳特），键盘和 Python 参考实现都只做整数加法，两边结果才能逐字一致：
  已见过的词对：存 -ln P(b|a)；没见过的：一元代价 + 回退代价 backoff(a) = ln((c_a + K_a) / K_a)。

格式（小端）：
  头 40 字节：魔数 "LMD1"、词数 V、词对数 P、词偏移表偏移、词串偏移、回退表偏移、区间表偏移、后继词表偏移、代价表偏移
  LMD2 头 64 字节：前 9 项同上，再加 三元数 T、上下文数 C、上下文表偏移、三元区间表偏移、三元回退表偏移、三元后继词表偏移、三元代价表偏移；
  上下文表 C × u32（词对 (a, b) 在二元表里的下标，升序）；三元区间表 (C+1) × u32；三元回退表 C × u16；三元后继词表 T × u32（每个上下文里 id 升序）；三元代价表 T × u16
  词按 UTF-8 字节序排（id = 排序后的下标），词偏移表 (V+1) × u32；回退表 V × u16；
  区间表 (V+1) × u32：a 的词对在 [range[a], range[a+1])，后继词 id 升序；后继词表 P × u32；代价表 P × u16
"""
import math, pickle, struct, sys
sys.path.insert(0, __file__.rsplit("/", 2)[0])
import pyengine

cnts, dat, out = sys.argv[1], sys.argv[2], sys.argv[3]
pos = [a for a in sys.argv[4:] if not a.startswith("--")]
minc = int(pos[0]) if pos else 2
TRI = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tri=")), None)
MINT = int(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--mint=")), 3))
DELTA = float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--delta=")), 0.2))
TSCALE = float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tscale=")), 1.0))      # 三元计数只数了部分语料时，乘上这个倍数和二元对齐（试验用）
K3_MIN, K3_PER = 10.0, 3.0
K_MIN = 20.0
K_PER_FOLLOWER = float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--k=")), 5.0))      # 5.0 = 线上；试验时可调
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
Ks, cas, pus = [], [], []
pidx = {}          # (a, b) 新 id → 词对在二元表里的下标
for a in range(V):
    ca = left.get(oldid[words[a]], 0)
    K = max(K_MIN, K_PER_FOLLOWER * len(by_a.get(a, [])))
    Ks.append(K)
    cas.append(ca)
    back.append(min(65535, round(math.log((ca + K) / K) * U)))
    for b, c in sorted(by_a.get(a, [])):
        pu = math.exp(q.get(words[b], PUNCT_Q) - 21.0 * 1.0)     # q 是 ln(权重+1)，LN_TOTAL = 21
        p = (c + K * pu) / (ca + K)
        pidx[(a, b)] = len(bs)
        bs.append(b)
        costs.append(max(0, min(65535, round(-math.log(p) * U))))
    ranges.append(len(bs))
P = len(bs)

# ---- 三元（可选）----
ctx, tranges, tbacks, tw, tcosts = [], [0], [], [], []
if TRI:
    tm = pickle.load(open(TRI, "rb"))
    MASK = (1 << SHIFT) - 1
    # 三元计数的词表和二元计数的不一致时按词翻译 id（词表里没有的三元丢掉）
    tr = None if tm["vocab"] == vocab else {i: oldid.get(w) for i, w in enumerate(tm["vocab"])}
    by_ctx = {}
    for k, c in tm["cnt"].items():
        if c < MINT:
            continue
        a0, b0, w0 = k >> (2 * SHIFT), (k >> SHIFT) & MASK, k & MASK
        if tr is not None:
            a0, b0, w0 = tr.get(a0), tr.get(b0), tr.get(w0)
            if a0 is None or b0 is None or w0 is None:
                continue
        a, b, w = newid[a0], newid[b0], newid[w0]
        if (a, b) in pidx:
            by_ctx.setdefault((a, b), []).append((w, c * TSCALE))
    kept = dropped = 0
    for (a, b) in sorted(by_ctx, key=lambda ab: pidx[ab]):
        cab = cnt.get(oldid[words[a]] << SHIFT | oldid[words[b]], 0)
        fol = by_ctx[(a, b)]
        K3 = max(K3_MIN, K3_PER * len(fol))
        tback = math.log((cab + K3) / K3)
        rows = []
        for w, c in sorted(fol):
            pb = (pidx.get((b, w)))
            if pb is not None:
                bi_cost = costs[pb] / U
            else:
                bi_cost = -math.log(math.exp(q.get(words[w], PUNCT_Q) - 21.0)) + math.log((cas[b] + Ks[b]) / Ks[b])
            p2 = math.exp(-bi_cost)
            p3 = (c + K3 * p2) / (cab + K3)
            c3 = -math.log(p3)
            if bi_cost + tback - c3 >= DELTA:
                rows.append((w, max(0, min(65535, round(c3 * U)))))
        if not rows:
            dropped += 1
            continue
        kept += 1
        ctx.append(pidx[(a, b)])
        tbacks.append(min(65535, round(tback * U)))
        for w, cc in rows:
            tw.append(w)
            tcosts.append(cc)
        tranges.append(len(tw))
    print(f"三元：上下文 {len(ctx)}（丢 {dropped}），三元 {len(tw)}（最少 {MINT} 次，比回退好 {DELTA} 纳特以上）")
T, C = len(tw), len(ctx)

blob = bytearray()
woff = [0]
for w in words:
    blob += w.encode("utf8")
    woff.append(len(blob))

hdr = 64 if TRI else 40
off_woff = hdr
off_blob = off_woff + 4 * (V + 1)
off_back = off_blob + len(blob)
off_back += (-off_back) % 4
off_range = off_back + 2 * V
off_range += (-off_range) % 4
off_b = off_range + 4 * (V + 1)
off_cost = off_b + 4 * P
off_end = off_cost + 2 * P
if TRI:
    off_end += (-off_end) % 4
    off_ctx = off_end
    off_tr = off_ctx + 4 * C
    off_tb = off_tr + 4 * (C + 1)
    off_tb += 0
    off_tw = off_tb + 2 * C
    off_tw += (-off_tw) % 4
    off_tc = off_tw + 4 * T
    off_end = off_tc + 2 * T
with open(out, "wb") as f:
    if TRI:
        f.write(struct.pack("<4sIIIIIIIIIIIIIII", b"LMD2", V, P, off_woff, off_blob, off_back, off_range, off_b, off_cost, T, C, off_ctx, off_tr, off_tb, off_tw, off_tc)[:64])
    else:
        f.write(struct.pack("<4sIIIIIIII4x", b"LMD1", V, P, off_woff, off_blob, off_back, off_range, off_b, off_cost))
    f.write(struct.pack("<%dI" % (V + 1), *woff))
    f.write(blob)
    f.write(b"\0" * (off_back - off_blob - len(blob)))
    f.write(struct.pack("<%dH" % V, *back))
    f.write(b"\0" * (off_range - off_back - 2 * V))
    f.write(struct.pack("<%dI" % (V + 1), *ranges))
    f.write(struct.pack("<%dI" % P, *bs))
    f.write(struct.pack("<%dH" % P, *costs))
    if TRI:
        f.write(b"\0" * ((-(off_cost + 2 * P)) % 4))
        f.write(struct.pack("<%dI" % C, *ctx))
        f.write(struct.pack("<%dI" % (C + 1), *tranges))
        f.write(struct.pack("<%dH" % C, *tbacks))
        f.write(b"\0" * ((-(off_tb + 2 * C)) % 4))
        f.write(struct.pack("<%dI" % T, *tw))
        f.write(struct.pack("<%dH" % T, *tcosts))
print(f"词 {V}，词对 {P}（最少出现 {minc} 次），文件 {off_end} 字节")
