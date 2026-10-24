#!/usr/bin/env python3
"""拼音引擎的 Python 参考实现（Swift 版 Keyboard/PinyinEngine.swift 照它写，调排序在这边做，快）。
用法：python3 pyengine.py pinyin.dat nihao woaizhongguo ..."""
import bisect, math, struct, sys

LN_TOTAL = 21.0
MAXKEY = 60


class Dict:
    def __init__(self, path):
        d = open(path, "rb").read()
        magic, n, koff, woff, toff, m, ioff, ikoff = struct.unpack_from("<4sIIIIIII", d, 0)
        assert magic == b"PYD1"
        self.d, self.n, self.koff, self.woff, self.toff = d, n, koff, woff, toff
        self.m, self.ioff, self.ikoff = m, ioff, ikoff
        self.keys = []
        for i in range(n):
            ko, wo, kl, wl, q = struct.unpack_from("<IIBBH", d, toff + i * 12)
            self.keys.append(d[koff + ko: koff + ko + kl])
        self.ikeys = []
        for i in range(m):
            ko, idx, kl = struct.unpack_from("<IIB", d, ioff + i * 12)
            self.ikeys.append(d[ikoff + ko: ikoff + ko + kl])

    def entry(self, i):
        ko, wo, kl, wl, q = struct.unpack_from("<IIBBH", self.d, self.toff + i * 12)
        return self.d[self.woff + wo: self.woff + wo + wl].decode("utf8"), q / 2048.0

    def entry_raw(self, i):
        """（词, 权重整数 q）——q = round(ln(权重+1) * 2048)，整数运算用"""
        ko, wo, kl, wl, q = struct.unpack_from("<IIBBH", self.d, self.toff + i * 12)
        return self.d[self.woff + wo: self.woff + wo + wl].decode("utf8"), q

    def exact(self, key):
        lo = bisect.bisect_left(self.keys, key)
        hi = bisect.bisect_right(self.keys, key)
        return range(lo, hi)

    def prefix(self, key):
        lo = bisect.bisect_left(self.keys, key)
        i = lo
        while i < self.n and self.keys[i].startswith(key):
            i += 1
        return range(lo, i)

    def initials(self, key):
        lo = bisect.bisect_left(self.ikeys, key)
        hi = bisect.bisect_right(self.ikeys, key)
        out = []
        for i in range(lo, hi):
            ko, idx, kl = struct.unpack_from("<IIB", self.d, self.ioff + i * 12)
            out.append(idx)
        return out


def cost(q):
    return LN_TOTAL - q


UNI_BASE = int(LN_TOTAL * 2048)     # 一元代价（整数，单位 1/2048 纳特）= UNI_BASE - q
BEAM = 4          # 整句动态规划：每个位置留几个「最后一个词不同」的最优路径
PER_KEY = 4       # 每段拼音最多试几个候选词


class LM:
    """二元语言模型（格式见 tools/lm/export_lm.py）。代价全是整数（1/2048 纳特）"""

    def __init__(self, path):
        d = open(path, "rb").read()
        magic, V, P, ow, ob, obk, orng, obs, oc = struct.unpack_from("<4sIIIIIIII", d, 0)
        assert magic == b"LMD1"
        self.V, self.P = V, P
        woff = struct.unpack_from("<%dI" % (V + 1), d, ow)
        self.words = [d[ob + woff[i]: ob + woff[i + 1]].decode("utf8") for i in range(V)]
        self.keys = [w.encode("utf8") for w in self.words]
        self.back = struct.unpack_from("<%dH" % V, d, obk)
        self.range = struct.unpack_from("<%dI" % (V + 1), d, orng)
        self.bs = struct.unpack_from("<%dI" % P, d, obs)
        self.costs = struct.unpack_from("<%dH" % P, d, oc)
        self.unk = self.id("<unk>")
        self.bos = self.id("<s>")

    def id(self, w):
        k = w.encode("utf8")
        i = bisect.bisect_left(self.keys, k)
        return i if i < self.V and self.keys[i] == k else -1

    def pair(self, a, b):
        lo, hi = self.range[a], self.range[a + 1]
        i = bisect.bisect_left(self.bs, b, lo, hi)
        return self.costs[i] if i < hi and self.bs[i] == b else None

    def followers(self, a, limit):
        """a 后面最可能接的词（代价小的在前），不含 <unk> / <s>"""
        lo, hi = self.range[a], self.range[a + 1]
        items = sorted((self.costs[i], self.bs[i]) for i in range(lo, hi) if self.bs[i] not in (self.unk, self.bos))
        return [self.words[b] for _, b in items[:limit]]


SYL = set()


def load_syllables(path):
    global SYL
    SYL = set(open(path).read().split())


def split_raw(raw):
    """去掉分词符 '，返回（字母串, 强制切开的位置集合, 字母数→原串位置表）
    rawpos[k] = 吃掉 k 个字母（连同紧跟的 '）后，原串里的位置"""
    letters, cuts, rawpos, i = [], set(), [0], 0
    while i < len(raw):
        if raw[i] == "'":
            if letters:
                cuts.add(len(letters))
            i += 1
            continue
        letters.append(raw[i])
        i += 1
        while i < len(raw) and raw[i] == "'":
            cuts.add(len(letters))
            i += 1
        rawpos.append(i)
    return "".join(letters), cuts, rawpos


def seg_ok(key, nchar, cuts_rel):
    """key 能不能切成恰好 nchar 个合法音节，且每个分词符位置都是音节边界"""
    cur = {0}
    for _ in range(nchar):
        nxt = set()
        for pos in cur:
            for l in range(1, 7):
                e = pos + l
                if e > len(key) or key[pos:e] not in SYL:
                    continue
                if any(pos < c < e for c in cuts_rel):
                    continue
                nxt.add(e)
        cur = nxt
        if not cur:
            return False
    return len(key) in cur


def boundaries(b, cuts):
    """音节边界（贪心取最长音节，不越过强制切点）：返回每个音节结束的位置"""
    n = len(b)
    out, i = [], 0
    while i < n:
        limit = min([c for c in cuts if c > i] + [n])
        for l in range(min(6, limit - i), 0, -1):
            if b[i:i + l].decode() in SYL:
                i += l
                out.append(i)
                break
        else:
            break
    return out


def display(raw):
    letters, cuts, _ = split_raw(raw)
    b = letters.encode()
    bs = boundaries(b, cuts)
    parts, prev = [], 0
    for e in bs:
        parts.append(letters[prev:e])
        prev = e
    if prev < len(letters):
        parts.append(letters[prev:])
    return " ".join(parts)


def inner_cuts(cuts, i, j):
    return [c - i for c in cuts if i < c < j]


def entry_ok(D, e, b, i, j, cuts):
    cr = inner_cuts(cuts, i, j)
    if not cr:
        return True
    w, _ = D.entry(e)
    return seg_ok(b[i:j].decode(), len(w), cr)


def first_ok(D, r, b, i, j, cuts):
    for e in list(r)[:60]:
        if entry_ok(D, e, b, i, j, cuts):
            return e
    return None


def prefix_words(D, b, j, k, cap):
    """键以 b[:j] 开头、更长，并且前 k 个音节恰好就是 b[:j]（xi 后面接 an 不算：xian 是另一个音节）的词，按权重取前 cap 个"""
    key = b[:j]
    cand = sorted(((D.entry(i)[1], i) for i in D.prefix(key) if len(D.keys[i]) > j), key=lambda x: (-x[0], x[1]))
    out = []
    for q, i in cand[:400]:
        w = D.entry(i)[0]
        kk = D.keys[i].decode()
        if len(w) > k and seg_ok(kk[:j], k, []) and seg_ok(kk[j:], len(w) - k, []):
            out.append(i)
            if len(out) == cap:
                break
    return out


def step_cost(lm, last, lid, uni):
    """上一个词 last（LM 的词 id，-1 = 没有上文）后面接词 lid 的代价；uni = 它的一元代价"""
    if lm is None or last < 0:
        return uni
    if lid >= 0:
        c = lm.pair(last, lid)
        if c is not None:
            return c
    return uni + lm.back[last]      # 没见过的词对（含不在模型里的词）：一元代价 + 回退代价，不能让「模型里没有的词」白占便宜


# ---- 个人学习（2026-10-24）----
# 选过的字词、整句、语音整理好的话都记下来，按次数给代价打折：「越用越懂你」。存在键盘扩展自己的容器里（一个文本文件，格式见 User.dump）。
# w：词（≥2 个字）的次数；b：（上一个词, 词）的次数；p：自造词（分几次选出来的短词组，词典里没有这个键+词）。都留「最近一次的序号」，满了淘汰最久没用的。
# 打折全是整数（1/2048 纳特），Swift 版 UserModel 逐字照抄。
U_CAP_W, U_CAP_B, U_CAP_P = 3000, 6000, 1000
# 单字不记词频（不打折）：单字一加分，整句选词就爱把词拆成单字（时间→是件、丝滑→是话），留出测试掉了 13 个点。
# 下面两张表是拿用户 400 句做留出测试调的（tools/bench/learn.py）：没见过的句子不掉、同一句再打一遍 52%→69%、聊天集不掉
BONUS_W = [int(x * 2048) for x in (0, 1.2, 1.8, 2.1, 2.4, 2.6, 2.8, 2.9, 3.0)]     # 词（≥2 个字）用过 0~8 次以上
BONUS_B = [int(x * 2048) for x in (0, 2.4, 3.6, 4.2, 4.6, 5.0, 5.2, 5.4, 5.6)]     # 词对用过 0~8 次以上
PHRASE_Q = int(12.0 * 2048)      # 自造词的一元权重（ln 权重 × 2048），相当于一个中等常用的词


class User:
    def __init__(self):
        self.w, self.b, self.p = {}, {}, {}
        self.seq = 0
        self._plist = None

    @staticmethod
    def load(path):
        u = User()
        for l in open(path, encoding="utf8"):
            f = l.rstrip("\n").split("\t")
            if f[0] == "w" and len(f) == 4:
                u.w[f[1]] = [int(f[2]), int(f[3])]
            elif f[0] == "b" and len(f) == 5:
                u.b[(f[1], f[2])] = [int(f[3]), int(f[4])]
            elif f[0] == "p" and len(f) == 5:
                u.p[(f[1].encode(), f[2])] = [int(f[3]), int(f[4])]
            elif f[0] == "s" and len(f) == 2:
                u.seq = int(f[1])
        return u

    def dump(self):
        """文本：首行 VKU1；w 词 次数 序号 / b 上一个词 词 次数 序号 / p 键 词 次数 序号 / s 当前序号（\t 分隔）"""
        out = ["VKU1"]
        out += [f"w\t{k}\t{c}\t{t}" for k, (c, t) in sorted(self.w.items(), key=lambda x: x[1][1])]
        out += [f"b\t{a}\t{k}\t{c}\t{t}" for (a, k), (c, t) in sorted(self.b.items(), key=lambda x: x[1][1])]
        out += [f"p\t{k.decode()}\t{w}\t{c}\t{t}" for (k, w), (c, t) in sorted(self.p.items(), key=lambda x: x[1][1])]
        out.append(f"s\t{self.seq}")
        return "\n".join(out) + "\n"

    def plist(self):
        """自造词按（键, 词的 UTF-8）排好的表：词格里它们的虚词条序号 = 词典条数 + 下标"""
        if self._plist is None:
            self._plist = sorted(self.p, key=lambda x: (x[0], x[1].encode()))
            self._pidx = {}
            for i, (k, w) in enumerate(self._plist):
                self._pidx.setdefault(k, []).append(i)
        return self._plist

    def phrases(self, key):
        """键正好是 key 的自造词在 plist 里的下标（升序）"""
        self.plist()
        return self._pidx.get(key, [])

    def bonus(self, prev, w):
        c = self.w.get(w)
        x = BONUS_W[min(c[0], 8)] if c else 0
        if prev is not None:
            c = self.b.get((prev, w))
            if c:
                x += BONUS_B[min(c[0], 8)]
        return x

    def _touch(self, table, k, cap):
        self.seq += 1
        v = table.get(k)
        if v:
            v[0] += 1
            v[1] = self.seq
            return
        table[k] = [1, self.seq]
        if len(table) > cap:            # 满了：按最近一次用的先后，扔掉最久没用的，留九成
            for old in sorted(table, key=lambda x: table[x][1])[:len(table) - cap * 9 // 10]:
                del table[old]

    def learn(self, words, prev=None):
        """words = 挨着上屏的词（一次拼字选出来的、一句整句切出来的），prev = 它前面那个词（上文，没有就 None）"""
        for w in words:
            if len(w) >= 2:
                self._touch(self.w, w, U_CAP_W)
            if prev is not None:
                self._touch(self.b, (prev, w), U_CAP_B)
            prev = w

    def add_phrase(self, key, word):
        self._touch(self.p, (key, word), U_CAP_P)
        self._plist = None


def _cjk(w):
    return all("\u4e00" <= ch <= "\u9fff" for ch in w)


def segment(lm, text):
    """按语言模型的词表正向最长匹配（最长 4 个字）切词；认不出的字单独一个"""
    out, i = [], 0
    while i < len(text):
        l = min(4, len(text) - i)
        while l > 1 and lm.id(text[i:i + l]) < 0:
            l -= 1
        out.append(text[i:i + l])
        i += l
    return out


def learn_text(user, lm, text, prev=None):
    """语音整理好的一段话：切词后连着的汉字词记词频和词对（标点、英文、数字处断开上下文）"""
    run = []
    for w in segment(lm, text):
        if _cjk(w):
            run.append(w)
            continue
        if run:
            user.learn(run, prev)
        run, prev = [], None
    if run:
        user.learn(run, prev)


# ---- 模糊音（二期，2026-10-25；设置里按「对」打开，默认全关）----
# 用户说话带口音：z/zh c/ch s/sh、n/l、an/ang en/eng in/ing、f/h 分不清。打开的对，输入的音节按这些对「也可能是」另一个音节：
# 词格里给每段拼音加「按模糊音换了一个或几个音节就成词」的边（带罚分，打对的不被抢）；整词候选里也把模糊音的词按（权重 - 罚分）并进去。
# 做法和 typo_edges 一样：沿有序词典按前缀走，每个音节试「原样 + 模糊音变体」，不枚举所有变体再逐个查。变体必须是合法音节。
FUZZ_ZCS, FUZZ_NL, FUZZ_NG, FUZZ_FH = 1, 2, 4, 8
FUZZ = 0                           # 现在打开的模糊音（位掩码；Swift 版是 PinyinEngine.fuzz）
PEN_FUZZ = int(1.2 * 2048)         # 每个换了的音节的罚分（1/2048 纳特，约差 3.3 倍词频）
FUZZ_MAX = 20                      # 一段最多吃这么多个字母


def _alt_zcs(t):
    if t[:2] in ("zh", "ch", "sh"):
        return t[0] + t[2:]
    if t[0] in "zcs" and (len(t) < 2 or t[1] != "h"):
        return t[0] + "h" + t[1:]
    return None


def _alt_nl(t):
    if t[0] == "n":
        return "l" + t[1:]
    if t[0] == "l":
        return "n" + t[1:]
    return None


def _alt_ng(t):
    if t[-3:] in ("ang", "eng", "ing"):
        return t[:-1]
    if t[-2:] in ("an", "en", "in"):
        return t + "g"
    return None


def _alt_fh(t):
    if t[0] == "f":
        return "h" + t[1:]
    if t[0] == "h":
        return "f" + t[1:]
    return None


def syl_variants(t, mask):
    """音节 t 按打开的模糊音能变成的别的音节（都在音节表里），顺序固定，不含 t 自己"""
    out = [t]
    for bit, f in ((FUZZ_ZCS, _alt_zcs), (FUZZ_NL, _alt_nl), (FUZZ_NG, _alt_ng), (FUZZ_FH, _alt_fh)):
        if mask & bit:
            for x in list(out):
                v = f(x)
                if v is not None and v in SYL and v not in out:
                    out.append(v)
    return out[1:]


def fuzz_edges(D, b, i, end, mask):
    """从 b[i] 起（不越过 end）按模糊音换了至少一个音节就能成词典键的段：按（吃掉几个字母, 词典键）排好的 [(吃掉几个字母, 词典键, 罚分)]；
    输入原样的键不收（那是普通的边）；同一段同一个键有几种切法 / 换法的取罚分最小的"""
    out = {}

    def walk(x, lo, hi, depth, changed):
        # 输入已经走到 b[x]；词典键前缀（长 depth）= D.keys[lo][:depth]，[lo, hi) 里的键都以它开头
        if changed and x > i and len(D.keys[lo]) == depth and D.keys[lo] != b[i:x]:
            k = (x - i, D.keys[lo])
            pen = changed * PEN_FUZZ
            if k not in out or pen < out[k]:
                out[k] = pen
        if x >= end or x - i >= FUZZ_MAX:
            return
        prefix = D.keys[lo][:depth]
        for l in range(1, 7):
            if x + l > end:
                break
            t = b[x:x + l].decode()
            if t not in SYL:
                continue
            for v, ch in [(t, 0)] + [(v, 1) for v in syl_variants(t, mask)]:
                a, z = _narrow(D, lo, hi, prefix + v.encode())
                if a < z:
                    walk(x + l, a, z, depth + len(v), changed + ch)

    walk(i, 0, D.n, 0, 0)
    return sorted((p, k, pen) for (p, k), pen in out.items())


# ---- 整句纠错：词格里给每段拼音加「改一处就成词」的边（2026-10-24）----
# 一处 = 邻键替换 / 多打一个字母 / 漏打一个字母（段尾只认漏打 g、h：an→ang、z→zh）/ 相邻两个字母对调；段长 2~14 个字母。
# 这样整句里夹一个错键也能连成句（原来纠错只看整个输入串，长句里错一个键就整句认不出）。带罚分交给语言模型挑：
# 打对的句子一般不会被「改」，因为改了要多付罚分（PEN_*）。做法是在有序词典上按前缀走（同 fuzzy），不枚举所有变体再逐个查。
# 罚分（1/2048 纳特）按错法分：邻键替换、对调最常见也最不伤切词；多打 / 漏打会把整段切词改掉，罚得重（不然「医患通」会被改成「以传统」）
PEN_SUB, PEN_TRANS, PEN_EXTRA, PEN_MISS, PEN_GH = int(7.0 * 2048), int(6.0 * 2048), int(10.0 * 2048), int(6.0 * 2048), int(6.0 * 2048)
TYPO_MIN, TYPO_MAX = 2, 14
# 另一路整句比最好的贵不超过这么多，才当第二个候选给出来：最好的改过拼音 → 原样那句宽一点（纠错改错时的退路）；
# 最好的没改 → 纠正句要很接近才给（门槛大了，打对的句子一大半后面都会多一个「纠正句」，太吵）
ALT_RAW_MARGIN, ALT_FIX_MARGIN = int(8.0 * 2048), int(3.0 * 2048)


def _children(D, lo, hi, depth):
    """[lo, hi) 里的键都以同一个长 depth 的前缀开头：按下一个字母分组，[(字母, 起, 止)]"""
    out = []
    x = lo
    while x < hi and len(D.keys[x]) == depth:
        x += 1
    while x < hi:
        k = D.keys[x]
        z = bisect.bisect_left(D.keys, k[:depth + 1] + b"\xff", x, hi)
        out.append((k[depth], x, z))
        x = z
    return out


def _narrow(D, lo, hi, key):
    a = bisect.bisect_left(D.keys, key, lo, hi)
    return a, bisect.bisect_left(D.keys, key + b"\xff", a, hi)


def typo_edges(D, b, i, end):
    """从 b[i] 起（不越过 end）改一处能成词典键的段：按（吃掉几个字母, 词典键）排好的 [(吃掉几个字母, 词典键, 罚分)]，
    不含和原样相同的；同一段同一个键有几种改法的取罚分最小的"""
    out = {}

    def emit(p, lo, hi, depth, pen):
        if TYPO_MIN <= p <= TYPO_MAX and lo < hi and len(D.keys[lo]) == depth and D.keys[lo] != b[i:i + p]:
            k = (p, D.keys[lo])
            if k not in out or pen < out[k]:
                out[k] = pen

    def exact(lo, hi, depth, p, can_emit, pen):     # 已经改过一处：后面只能原样对上
        if can_emit:
            emit(p, lo, hi, depth, pen)
        if p >= TYPO_MAX or i + p >= end:
            return
        a, z = _narrow(D, lo, hi, D.keys[lo][:depth] + b[i + p:i + p + 1]) if lo < hi else (0, 0)
        if a < z:
            exact(a, z, depth + 1, p + 1, True, pen)

    def walk(lo, hi, depth, p):                 # 还没改过：键的前 depth 个字母 = b[i:i+p]
        if i + p < end:
            exact(lo, hi, depth, p + 1, True, PEN_EXTRA)            # 多打了 b[i+p]
        nxt = b[i + p] if i + p < end else -1
        for ch, a, z in _children(D, lo, hi, depth):
            if ch == nxt:
                if p + 1 <= TYPO_MAX:
                    walk(a, z, depth + 1, p + 1)
            elif nxt >= 0 and chr(ch) in NEAR.get(chr(nxt), ""):
                exact(a, z, depth + 1, p + 1, True, PEN_SUB)        # 邻键替换
            if nxt >= 0:
                exact(a, z, depth + 1, p, False, PEN_MISS)          # 漏打了 ch（后面至少还要对上一个）
            if ch in (103, 104):
                emit(p, a, z, depth + 1, PEN_GH)                    # 段尾漏打 g / h
            if i + p + 1 < end and ch == b[i + p + 1] and nxt != ch:    # 相邻对调
                a2, z2 = _narrow(D, a, z, D.keys[a][:depth + 1] + bytes([nxt]))
                if a2 < z2:
                    exact(a2, z2, depth + 2, p + 2, True, PEN_TRANS)

    walk(0, D.n, 0, 0)
    return sorted((p, k, pen) for (p, k), pen in out.items())


def run_dp(D, b, cuts, lm, ctx, user=None, ctxw=None, t9=False):
    """整句动态规划（带二元语法）：每个位置、「改没改过拼音」两路各留 BEAM 条「最后一个词不同」的最优路径。
    返回 beams：beams[j] 是盖住 b[:j] 的路径表，按（代价, 路径）升序；状态 = (代价, 上一个词, 路径, 改过没有)，
    路径 = ((词条序号, 字母数), …)。改过的那条边，词条的键和原样的拼音不一样（显示纠正后的拼音就拿词条的键拼）。
    user = 个人学习（ctxw = 上文最后一个词的字面，给词对打折用）：每一步的代价按用过的次数打折，自造词也进词格（虚词条序号 ≥ 词典条数）
    t9 = 九键：b 里是数字（一个键上的任意字母）/ 已选定的字母，每段按 t9_edges 取词；不纠错、不用个人学习的自造词"""
    n = len(b)
    beams = [[] for _ in range(n + 1)]
    beams[0] = [(0, ctx, (), 0)]
    pl = user.plist() if user else []

    def ent(e):
        return D.entry_raw(e) if e < D.n else (pl[e - D.n][1], PHRASE_Q)

    def extend(i, j, es, pen):
        fix = 1 if pen else 0
        for e in es:
            w, q = ent(e)
            uni = UNI_BASE - q
            lid = lm.id(w) if lm else -1
            key = lid if lid >= 0 else -(e + 1)
            for c, last, path, f in beams[i]:
                st = step_cost(lm, last, lid, uni)
                if user:
                    st = max(0, st - user.bonus(ent(path[-1][0])[0] if path else ctxw, w))
                beams[j].append((c + st + pen, key, path + ((e, j - i),), f | fix))

    for i in range(n):
        if i > 0:
            beams[i] = prune(beams[i])
        if not beams[i]:
            continue
        lim = min([c for c in cuts if c > i] + [n])
        if t9:
            for j, es in t9_edges(D, b, i, lim, cuts):
                extend(i, j, es, 0)
            continue
        for j in range(i + 1, min(lim, i + MAXKEY) + 1):
            r = D.exact(b[i:j])
            if len(r):
                es = [e for e in list(r)[:60] if entry_ok(D, e, b, i, j, cuts)][:PER_KEY]
                extend(i, j, es, 0)
            if user:
                ph = user.phrases(b[i:j])
                if ph:
                    extend(i, j, [D.n + x for x in ph], 0)
        for p, k, pen in typo_edges(D, b, i, lim):
            extend(i, i + p, list(D.exact(k))[:PER_KEY], pen)
        if FUZZ:
            for p, k, pen in fuzz_edges(D, b, i, lim, FUZZ):
                extend(i, i + p, list(D.exact(k))[:PER_KEY], pen)
    beams[n] = prune(beams[n])
    return beams


def prune(states):
    """同一路（改没改过）里同一个「最后一个词」只留代价最小的（代价相同留路径小的），每路再留最好的 BEAM 条，合起来按（代价, 路径）排"""
    best = {}
    for st in states:
        k = (st[1], st[3])
        if k not in best or (st[0], st[2]) < (best[k][0], best[k][2]):
            best[k] = st
    out = []
    for f in (0, 1):
        out += sorted((x for x in best.values() if x[3] == f), key=lambda x: (x[0], x[2]))[:BEAM]
    return sorted(out, key=lambda x: (x[0], x[2]))


def predict(lm, ctx, limit=12):
    """上文最后一个词 ctx 之后最可能接的词 / 标点（没有 LM 或词不认识返回空）"""
    if lm is None or not ctx:
        return []
    a = lm.id(ctx)
    return lm.followers(a, limit) if a >= 0 else []


# ---- 拼音纠错（打错键 / 漏打 / 多打 / 前后鼠对调 / 模糊音）----
# 做法：把输入串和词典里每个键算一个带权的编辑距离（Damerau：替换、插入、删除、相邻对调），代价小的词排前面，再按词频折算。
# 代价全是整数，Swift 版逐字照抄。邻键 = 手机键盘上挨着的键（半键错位）+ 常见模糊音（l/n、f/h、r/l）；z/zh、c/ch、s/sh、an/ang 这类靠「h / g 少打多打」代价便宜。
NEAR = {
    "a": "qswz", "b": "fghnv", "c": "dfvx", "d": "cefrsx", "e": "drsw", "f": "bcdghrtv", "g": "bfhtvy", "h": "bfgjnuy",
    "i": "jkou", "j": "hikmnu", "k": "ijlmo", "l": "knopr", "m": "jkn", "n": "bhjlm", "o": "iklp", "p": "lo",
    "q": "aw", "r": "deflt", "s": "adewxz", "t": "fgry", "u": "hijy", "v": "bcfg", "w": "aeqs", "x": "cdsz",
    "y": "ghtu", "z": "asx",
}
F_NEAR, F_FAR, F_TRANS, F_INDEL, F_INDEL_SOFT = 2, 4, 2, 3, 2
F_LAMBDA = 2048                  # 每个代价单位折合的词频（1/2048 纳特）：1 纳特，也就是差 2.7 倍词频
WEAK_Q = int(9.5 * 2048)         # 整词里最常用的那个权重低于这个，就算「可能打错了」，把纠错候选排到前面


def f_budget(n):
    return 0 if n < 2 else (2 if n < 4 else (4 if n < 6 else 6))


def f_soft(ch, prev):
    """这个字母夹在 prev 后面，少打 / 多打了它也算模糊音（zh ch sh 的 h；an en in 后面的 g）"""
    return (ch == 104 and prev in b"zcs") or (ch == 103 and prev == 110)


def f_column(b, t, kc, kp, c1, c2):
    """编辑距离表的第 t 列（词典键的前 t 个字母 vs 输入串 b 的每个前缀），c1 / c2 = 第 t-1 / t-2 列，kc / kp = 键的第 t / t-1 个字母。
    带权 Damerau 编辑距离（替换 / 插入 / 删除 / 相邻对调），按键的字母一列一列算：同前缀的键共用前面的列（按词典顺序走，就是在字典树上走）"""
    n = len(b)
    col = [0] * (n + 1)
    col[0] = c1[0] + (F_INDEL_SOFT if t >= 2 and f_soft(kc, kp) else F_INDEL)
    ins = col[0] - c1[0]
    near = NEAR.get
    for r in range(1, n + 1):
        ar = b[r - 1]
        if ar == kc:
            best = c1[r - 1]
        elif chr(kc) in near(chr(ar), ""):
            best = c1[r - 1] + F_NEAR
        else:
            best = c1[r - 1] + F_FAR
        v = col[r - 1] + (F_INDEL_SOFT if r >= 2 and f_soft(ar, b[r - 2]) else F_INDEL)
        if v < best:
            best = v
        v = c1[r] + ins
        if v < best:
            best = v
        if r >= 2 and t >= 2 and ar == kp and b[r - 2] == kc:
            v = c2[r - 2] + F_TRANS
            if v < best:
                best = v
        col[r] = best
    return col


def fuzzy(D, b, cap):
    """纠错候选：[(词, 词条序号, 代价)]，得分高的在前（得分 = 权重整数 - 代价 * F_LAMBDA）。
    结果和原来「拿编辑距离把整本词典每个键算一遍」逐条一致（2026-10-24 改写时对拍过），但按词典顺序共用前缀的列，
    某个前缀往后的两列都超了预算（所有路径必经其中一列）就跳过所有以它开头的键，不再扫全词典。"""
    n = len(b)
    bud = f_budget(n)
    if bud == 0:
        return []
    win = min(2, bud // 2)
    col0 = [0] * (n + 1)
    for r in range(1, n + 1):
        col0[r] = col0[r - 1] + (F_INDEL_SOFT if r >= 2 and f_soft(b[r - 1], b[r - 2]) else F_INDEL)
    cols, mins, rmin = [col0], [min(col0)], [col0]      # 第 t 列、它的最小值、每一行在前 t 列里的最小值
    cur = b""                                            # cols 对应的键前缀
    best = {}
    i = 0
    while i < D.n:
        k = D.keys[i]
        l = 0
        top = min(len(k), len(cur))
        while l < top and k[l] == cur[l]:
            l += 1
        del cols[l + 1:], mins[l + 1:], rmin[l + 1:]
        cut = 0
        for t in range(l + 1, len(k) + 1):
            if t > n + win:
                cut = t
                break
            c = f_column(b, t, k[t - 1], k[t - 2] if t >= 2 else 0, cols[t - 1], cols[t - 2] if t >= 2 else None)
            cols.append(c)
            mins.append(min(c))
            rmin.append([x if x < y else y for x, y in zip(rmin[t - 1], c)])
            if mins[t] > bud and mins[t - 1] > bud:
                cut = t
                break
        if cut:
            cur = k[:len(cols) - 1]
            i = bisect.bisect_left(D.keys, k[:cut] + b"\xff", i + 1)
            continue
        cur = k
        m = len(k)
        if m >= n - win and cols[m][n] <= bud and cols[m][n] != 0 and all(x <= bud for x in rmin[m][1:]):
            c = cols[m][n]
            w, q = D.entry_raw(i)
            sc = q - c * F_LAMBDA
            if w not in best or sc > best[w][0]:
                best[w] = (sc, i, c)
        i += 1
    items = sorted(best.items(), key=lambda kv: (-kv[1][0], kv[1][1]))
    return [(w, i, c) for w, (sc, i, c) in items[:cap]]


# ---- 九键（2 abc 3 def 4 ghi 5 jkl 6 mno 7 pqrs 8 tuv 9 wxyz）----
# 输入串里：数字 2~9 = 这个键上的任意一个字母；小写字母 = 已经选定的音节（点左边的音节列表选的）；' = 分词。
# 做法：扫整本词典，键的每一位对得上（数字对应的字母 / 选定的字母）就算命中，按词频排。
T9_OF = {ord(ch): ord(d) for d, ls in {"2": "abc", "3": "def", "4": "ghi", "5": "jkl", "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"}.items() for ch in ls}


T9_LETTERS = {ord(d): [ord(c) for c in ls] for d, ls in {"2": "abc", "3": "def", "4": "ghi", "5": "jkl", "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"}.items()}


def t9_scan(D, pat, prefix):
    """键和 pat 逐位对得上的词条序号（升序）。prefix=False：长度相等；True：键比 pat 更长（联想）。
    按位在有序词典里收窄区间（数字 = 这个键上的几个字母挨个试，字母 = 只试它），不扫全词典"""
    m = len(pat)
    out = []

    def walk(x, lo, hi, key):
        if lo >= hi:
            return
        if x == m:
            # 键正好等于 key 的排在区间最前面
            e = lo
            while e < hi and len(D.keys[e]) == m:
                e += 1
            out.extend(range(e, hi) if prefix else range(lo, e))
            return
        c = pat[x]
        for ch in ([c] if c >= 97 else T9_LETTERS.get(c, [])):
            k2 = key + bytes([ch])
            a = bisect.bisect_left(D.keys, k2, lo, hi)
            z = bisect.bisect_left(D.keys, k2 + b"\xff", a, hi)
            walk(x + 1, a, z, k2)

    walk(0, 0, D.n, b"")
    return out


def t9_whole(D, b, j, cuts):
    """b[:j] 整个对上一个词的键（分词符位置要是音节边界），按（权重大 → 小，序号小 → 大）"""
    es = [e for e in t9_scan(D, b[:j], False) if entry_ok(D, e, D.keys[e], 0, j, cuts)]
    es.sort(key=lambda e: (-D.entry_raw(e)[1], e))
    return es


T9_PER_KEY = 8        # 九键每段最多试几个候选词（同一串数字能拼出好几个音节，4 个不够）


def t9_edges(D, b, i, lim, cuts):
    """从 b[i] 起（不越过 lim）所有对得上词典键的段：[(j, [词条序号…])]，j 升序；每段按（权重大 → 小，序号小 → 大）留 T9_PER_KEY 个。
    一次沿词典走完所有长度（走到词典里没有这个开头的键就停），不用每个长度各扫一遍"""
    hit = {}

    def walk(x, lo, hi, key):
        if lo >= hi:
            return
        if x > 0:
            e = lo
            while e < hi and len(D.keys[e]) == x:        # 键正好等于 key 的排在区间最前面
                e += 1
            if e > lo:
                hit.setdefault(i + x, []).extend(range(lo, e))
        if i + x >= lim or x >= MAXKEY:
            return
        c = b[i + x]
        for ch in ([c] if c >= 97 else T9_LETTERS.get(c, [])):
            k2 = key + bytes([ch])
            a = bisect.bisect_left(D.keys, k2, lo, hi)
            z = bisect.bisect_left(D.keys, k2 + b"\xff", a, hi)
            walk(x + 1, a, z, k2)

    walk(0, 0, D.n, b"")
    out = []
    for j in sorted(hit):
        es = [e for e in hit[j] if entry_ok(D, e, D.keys[e], 0, j - i, [c - i for c in cuts])]
        es.sort(key=lambda e: (-D.entry_raw(e)[1], e))
        if es:
            out.append((j, es[:T9_PER_KEY]))
    return out


def t9_candidates(D, raw, limit=40, expanded=False, lm=None, ctx=None):
    """返回 [(词, 吃掉原串几个字符, 种类, 拼音)]；拼音 = 这个候选对应的拼音（顶栏显示用），整句是各词的拼音拼起来"""
    letters, cuts, rawpos = split_raw(raw)
    b = letters.encode()
    n = len(b)
    if n == 0:
        return []
    ctx_id = lm.id(ctx) if lm and ctx else -1
    beams = run_dp(D, b, cuts, lm, ctx_id, None, ctx, t9=True)
    out, seen = [], set()

    def push(text, consume, kind, key=b""):
        if text in seen:
            return
        seen.add(text)
        out.append((text, rawpos[consume], kind, key.decode()))

    def sentence(j, k=0):
        """（整句, 拼音）：盖住 b[:j] 的第 k 好的路径；不足两个词的不算句子"""
        path = beams[j][k][2] if len(beams[j]) > k else None
        if not path or len(path) < 2:
            return None, b""
        return "".join(D.entry(e)[0] for e, _ in path), b"".join(D.keys[e] for e, _ in path)

    full = t9_whole(D, b, n, cuts)
    for i in full[:8]:
        push(D.entry(i)[0], n, "全", D.keys[i])
    for k in (0, 1):                  # 九键歧义多，整句给最好的两条（第二条是退路）
        s, skey = sentence(n, k)
        if s:
            push(s, n, "句", skey)
    assoc = []
    if not cuts:
        assoc = t9_scan(D, b, True)
        assoc.sort(key=lambda e: (-D.entry_raw(e)[1], e))
    for i in assoc[:3]:
        push(D.entry(i)[0], n, "联", D.keys[i])
    hit = []                      # 前缀：b[:j] 整个能成词的最长三处（只试最后 14 个位置）
    for j in range(n - 1, max(0, n - 15), -1):
        es = t9_whole(D, b, j, cuts)
        if es:
            hit.append((j, es))
            if len(hit) == 3:
                break
    for j, es in hit:
        t, tkey = sentence(j)
        if t:
            push(t, j, "前句", tkey)
        for i in es[:3]:
            push(D.entry(i)[0], j, "前", D.keys[i])
    for i in assoc[3:6]:
        push(D.entry(i)[0], n, "联", D.keys[i])
    if not out:
        push(letters, n, "原")
    if expanded:
        for i in full:
            push(D.entry(i)[0], n, "全", D.keys[i])
        for i in assoc[:40]:
            push(D.entry(i)[0], n, "联", D.keys[i])
        for j, es in hit:
            for i in es[:40]:
                push(D.entry(i)[0], j, "前", D.keys[i])
    return out[:limit]


def t9_syllables(D, raw, limit=12):
    """点左边列表选音节：下一个还没选的数字串（前面选好的字母不算）开头能拼出哪些音节，常用的在前。返回（音节列表, 数字串在原串里的起点）"""
    letters, cuts, rawpos = split_raw(raw)
    b = letters.encode()
    n = len(b)
    p = 0
    while p < n and b[p] >= 97:
        p += 1
    if p >= n:
        return [], 0
    end = min([c for c in cuts if c > p] + [n])
    opts = []
    for s in SYL:
        l = len(s)
        if l <= end - p and all(T9_OF[ord(s[i])] == b[p + i] for i in range(l)):
            r = D.exact(s.encode())
            opts.append((-(D.entry_raw(r[0])[1] if len(r) else 0), s))
    opts.sort()
    return [s for _, s in opts[:limit]], rawpos[p]


def candidates(D, raw, limit=40, expanded=False, lm=None, ctx=None, user=None):
    letters, cuts, rawpos = split_raw(raw)
    b = letters.encode()
    n = len(b)
    if n == 0:
        return []
    ctx_id = lm.id(ctx) if lm and ctx else -1
    beams = run_dp(D, b, cuts, lm, ctx_id, user, ctx)
    pl = user.plist() if user else []

    def word_of(e):
        return D.entry(e)[0] if e < D.n else pl[e - D.n][1]

    def key_of(e):
        return D.keys[e] if e < D.n else pl[e - D.n][0]

    class _Best:       # 沿用旧接口：best[j][1] 是 None 表示这一位置盖不住
        def __getitem__(self, j):
            return (0, None if not beams[j] else beams[j][0][2])
    best = _Best()
    out, seen = [], set()

    def push(text, consume, kind, fix="", parts=None):
        """fix = 纠正后的拼音（只算吃掉的那段，不含 '）；没改过拼音的是空串。parts = 它由哪几个词组成（整句的切词，个人学习用）"""
        if text in seen:
            return
        seen.add(text)
        out.append((text, rawpos[consume], kind, fix, tuple(parts) if parts else (text,)))

    def fixed(path, j):
        k = b"".join(key_of(e) for e, _ in path)
        return k.decode() if k != b[:j] else ""

    def sentence(j, st=None):
        """（整句, 纠正后的拼音, 切词）；st 不给就用这一位置最好的那条；不足两个词的不算句子"""
        path = st[2] if st else best[j][1]
        if not path or len(path) < 2:
            return None, "", ()
        ws = [word_of(e) for e, _ in path]
        return "".join(ws), fixed(path, j), ws

    full = [e for e in list(D.exact(b))[:60] if entry_ok(D, e, b, 0, n, cuts)]
    fpen = {}
    if FUZZ and not cuts:       # 模糊音：整串按模糊音换了音节就成词的，按（权重 - 罚分）并进整词里（打对的同权重排前面）
        for p, k, pen in fuzz_edges(D, b, 0, n, FUZZ):
            if p == n:
                for e in list(D.exact(k))[:60]:
                    fpen[e] = pen
        if fpen:
            sc = [(-D.entry_raw(e)[1], 0, k, e) for k, e in enumerate(full)] + [(-D.entry_raw(e)[1] + pen, 1, e, e) for e, pen in sorted(fpen.items())]
            full = [x[3] for x in sorted(sc)]
    if lm and ctx_id >= 0 and len(full) > 1:      # 有上文：整词按「接在上文后面」的代价重排（代价相同保持原顺序）
        def cx(e):
            w, q = D.entry_raw(e)
            return step_cost(lm, ctx_id, lm.id(w), UNI_BASE - q) + fpen.get(e, 0)
        full = [e for _, _, e in sorted((cx(e), k, e) for k, e in enumerate(full))]
    if user and full and any(user.bonus(ctx, D.entry(e)[0]) for e in full):     # 用过的词往前挪（打折后的代价相同保持原顺序）
        def ucost(e):
            w, q = D.entry_raw(e)
            base = step_cost(lm, ctx_id, lm.id(w), UNI_BASE - q) if lm and ctx_id >= 0 else UNI_BASE - q
            return base - user.bonus(ctx, w) + fpen.get(e, 0)
        full = [e for _, _, e in sorted((ucost(e), k, e) for k, e in enumerate(full))]
    # 自造词：键正好是整个输入串的，排在最前面（用得多的在前）
    mine = [] if cuts or not user else [pl[x][1] for x in sorted(user.phrases(b), key=lambda x: (-user.p[pl[x]][0], x))]
    top = max(D.entry(e)[1] for e in full) if full else 0
    s, sfix, sparts = sentence(n)
    # 纠错：输入串不是任何词（也不是任何词的开头、连不成句）= 多半打错了，纠错候选排最前；
    # 是个词但很冷僻（zhidan 制单、haide 害的）= 可能打错，纠错候选插在前两个整词后面；展开面板里总是补在最后
    typo = not full and not mine and s is None and len(D.prefix(b)) == 0
    weak = bool(full) and max(D.entry_raw(e)[1] for e in full) < WEAK_Q
    fz = []
    if not cuts and ((n >= 3 and (typo or weak)) or (expanded and n >= 2)):
        fz = fuzzy(D, b, 30 if expanded else 4)
    if typo:
        for w, i, c in fz[:4]:
            push(w, n, "纠", D.keys[i].decode())
    for w in mine:
        push(w, n, "自")
    pick = [i for k, i in enumerate(full[:8]) if k < 3 or D.entry(i)[1] >= top - 4.5]
    for i in pick[:2] if weak else pick:
        push(D.entry(i)[0], n, "全")
    if weak:
        for w, i, c in fz[:3]:
            push(w, n, "纠", D.keys[i].decode())
        for i in pick[2:]:
            push(D.entry(i)[0], n, "全")
    if s:
        push(s, n, "句", sfix, sparts)
        # 另一路（改过拼音 ↔ 没改过）的最好整句紧跟在后面：纠错改错了点它就回到原样，没敢改的点它就是纠正后的
        alt = next((st for st in beams[n] if st[3] != beams[n][0][3]), None)
        if alt and alt[0] - beams[n][0][0] <= (ALT_RAW_MARGIN if beams[n][0][3] else ALT_FIX_MARGIN):
            t, f, ps = sentence(n, alt)
            if t:
                push(t, n, "句", f, ps)
    r = D.prefix(b)
    cand = [(D.entry(i)[1], i) for i in r if len(D.keys[i]) > n and not cuts]
    cand.sort(key=lambda x: (-x[0], x[1]))
    for q, i in cand[:3]:       # 联想先给 3 个，后面接上「首字 / 前几个字」，其余的联想排在它们后面
        push(D.entry(i)[0], n, "联")
    bs = [e for e in boundaries(b, cuts) if e < n]
    for c in sorted(cuts):
        if c < n and c not in bs:
            bs.append(c)
    for j in sorted(bs, reverse=True)[:3]:
        if best[j][1] is None:
            continue
        s, f, ps = sentence(j)
        if s:
            push(s, j, "前句", f, ps)
        ex = [e for e in list(D.exact(b[:j]))[:60] if entry_ok(D, e, b, 0, j, cuts)]
        for i in ex[:3]:
            push(D.entry(i)[0], j, "前")
    for q, i in cand[3:6]:
        push(D.entry(i)[0], n, "联")
    if 2 <= n <= 6 and not cuts:
        for idx in D.initials(b)[:10]:
            push(D.entry(idx)[0], n, "简")
    if not out:
        push(letters, n, "原")
    if expanded:     # 点候选栏的向下箭头展开：前面的顺序不变，后面补上其余的
        for i in full:
            push(D.entry(i)[0], n, "全")
        for q, i in cand[:40]:
            push(D.entry(i)[0], n, "联")
        # 最长的三处、再加首字：每处先给最常用的 12 个同音词，接着是以它开头的联想词（豆包的做法：首字单独列出，下面一串联想），
        # 同音的冷僻字（一处可多达 60 个）放到最后
        sb = [] if cuts else [e for e in boundaries(b, cuts) if e < n]
        order = sorted(bs, reverse=True)[:3]
        order += [j for j in sb[:1] if j not in order]
        rest = []
        for j in order:
            if best[j][1] is None:
                continue
            ex = [e for e in list(D.exact(b[:j]))[:60] if entry_ok(D, e, b, 0, j, cuts)]
            for i in ex[:12]:
                push(D.entry(i)[0], j, "前")
            rest += [(i, j) for i in ex[12:]]
            if j in sb:
                for i in prefix_words(D, b, j, sb.index(j) + 1, 12):
                    push(D.entry(i)[0], j, "联")
        for i, j in rest:
            push(D.entry(i)[0], j, "前")
        if 2 <= n <= 6 and not cuts:
            for idx in D.initials(b)[:40]:
                push(D.entry(idx)[0], n, "简")
        for w, i, c in fz:
            push(w, n, "纠", D.keys[i].decode())
    return out[:limit]


if __name__ == "__main__":
    # 用法：pyengine.py pinyin.dat [lm.dat] 输入… ；输入可以写成「上文词@拼音」（上文词 = 光标前最后一个词），单独写「@上文词」= 只看联想预测
    D = Dict(sys.argv[1])
    load_syllables(sys.argv[1].rsplit("/", 1)[0] + "/../../tools/syllables.txt")
    args = sys.argv[2:]
    lm = None
    if args and args[0].endswith(".dat"):
        lm = LM(args[0])
        args = args[1:]
    user = None
    if args and args[0].startswith("--user="):      # 个人学习：--user=文件（格式见 User.dump）
        user = User.load(args[0][7:])
        args = args[1:]
    if args and args[0].startswith("--fuzzy="):      # 模糊音：--fuzzy=位掩码（1 z/zh c/ch s/sh，2 n/l，4 an/ang en/eng in/ing，8 f/h）
        FUZZ = int(args[0][8:])
        args = args[1:]
    for s in args:
        ctx, _, rest = s.rpartition("@") if "@" in s else ("", "", s)
        if "@" in s and not rest:
            print(s, "→", " ".join(predict(lm, ctx, 12)))
            continue
        if rest.startswith("#"):      # 九键：#64426 = 数字串（可夹已选好的音节字母和 '）
            t = rest[1:]
            print(s, "→", " ".join(f"{w}[{k}{c} {p}]" for w, c, k, p in t9_candidates(D, t, 14, False, lm, ctx)))
            print(f"{s}*", "→", " ".join(f"{w}[{k}{c} {p}]" for w, c, k, p in t9_candidates(D, t, 200, True, lm, ctx)))
            syl, at = t9_syllables(D, t)
            print(f"{s}~", "→", " ".join(syl), "@", at)
            continue
        tag = (ctx + "@") if ctx else ""
        def fmt(cs):
            return " ".join(f"{t}[{k}{c}{'~' + f if f else ''}]" for t, c, k, f, _ in cs)
        print(s, f"({display(rest)})", "→", fmt(candidates(D, rest, 14, False, lm, ctx, user)))
        print(f"{s}*", "→", fmt(candidates(D, rest, 200, True, lm, ctx, user)))
