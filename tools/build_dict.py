#!/usr/bin/env python3
"""把雾凇拼音（rime-ice，GPL-3.0）的词库压成键盘用的二进制词典 Keyboard/Resources/pinyin.dat。

用法：python3 tools/build_dict.py <放着 8105.dict.yaml 和 base.dict.yaml 的目录> <输出 pinyin.dat>
源文件：https://github.com/iDvel/rime-ice/tree/main/cn_dicts

格式（小端）：
  头 40 字节：魔数 "PYD1"、条数 n、键区偏移、词区偏移、表偏移、简拼条数 m、简拼表偏移、简拼键区偏移
  词条表（n × 12 字节，按「键」字节序排，同键按权重从大到小）：键偏移 u32、词偏移 u32、键长 u8、词长 u8、权重 u16
  键 = 拼音去掉空格（nihao）；权重 = round(ln(rime 权重 + 1) * 2048)
  简拼表（m × 12 字节，按简拼键排，同键按权重从大到小）：键偏移 u32、词条序号 u32、键长 u8、补 3 字节
  简拼键 = 每个音节的首字母（nh）；只收 2~5 个音节、权重 ≥ 500、每个简拼键最多 25 条
"""
import math, struct, sys, collections

src, out = sys.argv[1], sys.argv[2]


def load(fn):
    hdr = True
    for line in open(fn, encoding="utf8"):
        line = line.rstrip("\n")
        if hdr:
            if line.strip() == "...":
                hdr = False
            continue
        if not line or line.startswith("#"):
            continue
        p = line.split("\t")
        if len(p) < 3 or not p[2].strip().isdigit():
            continue
        yield p[0], p[1].split(), int(p[2])


best = {}   # (词, 键) -> (权重, 首字母)


def add(word, syl, w):
    if len(syl) != len(word) or not all(s.isascii() and s.isalpha() for s in syl):
        return
    key = "".join(syl).lower()
    if len(key) > 60 or len(word.encode("utf8")) > 60:
        return
    k = (word, key)
    if k not in best or best[k][0] < w:
        best[k] = (w, "".join(s[0] for s in syl).lower(), len(syl))


for word, syl, w in load(src + "/8105.dict.yaml"):
    add(word, syl, w)          # 单字全收，保证任何字都打得出来
for word, syl, w in load(src + "/base.dict.yaml"):
    if len(word) <= 3 and w >= 100 or len(word) > 3 and w >= 1500:
        add(word, syl, w)

# 补词表：雾凇里没有、或权重压得太低的口语 / 网络用语 / 专有名词（天胡、恰饭、医患通…），格式见 tools/extra_words.txt
for line in open(__file__.rsplit("/", 1)[0] + "/extra_words.txt", encoding="utf8"):
    p = line.rstrip("\n").split("\t")
    if len(p) == 3 and not line.startswith("#") and p[2].isdigit():
        add(p[0], p[1].split(), int(p[2]))

# 领域词补全（THUOCL：成语 / 医学 / 财经 / 法律 / 地名…，tools/build_domain_words.py 生成）：同样格式，权重已经压得比日常词低
for line in open(__file__.rsplit("/", 1)[0] + "/extra_domain.txt", encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) == 3 and not line.startswith("#") and p[2].isdigit():
        add(p[0], p[1].split(), int(p[2]))

# 口语词校正：雾凇的词频来自网页语料，个别口语词被同音的书面词压得太狠（待会 12450 对 带回 96010）。
# tools/boost.txt 里每行一个词，把它提到同拼音的所有词前面（只抬到刚好比最高的那个多 1，别的不动）
top = collections.defaultdict(int)
for (word, key), v in best.items():
    top[key] = max(top[key], v[0])
for line in open(__file__.rsplit("/", 1)[0] + "/boost.txt", encoding="utf8"):
    word = line.split("#")[0].strip()
    for (w, key), v in list(best.items()) if word else []:
        if w == word and v[0] < top[key]:
            top[key] += 1
            best[(w, key)] = (top[key], v[1], v[2])

ents = sorted(((k[1], -v[0], k[0], v[1], v[2]) for k, v in best.items()))   # 键、权重倒序、词
n = len(ents)
keys, words = bytearray(), bytearray()
table = bytearray()
rows = []
for key, negw, word, ini, nsyl in ents:
    ko, wo = len(keys), len(words)
    kb, wb = key.encode(), word.encode("utf8")
    keys += kb
    words += wb
    q = max(0, min(65535, round(math.log(-negw + 1) * 2048)))
    table += struct.pack("<IIBBH", ko, wo, len(kb), len(wb), q)
    rows.append((ini, nsyl, -negw, len(rows)))

# 简拼表
per = collections.defaultdict(list)
for ini, nsyl, w, idx in rows:
    if 2 <= nsyl <= 5 and w >= 500:
        per[ini].append((-w, idx))
ikeys = bytearray()
itable = bytearray()
m = 0
for ini in sorted(per):
    lst = sorted(per[ini])[:25]
    ko = len(ikeys)
    ikeys += ini.encode()
    for _, idx in lst:
        itable += struct.pack("<IIBBBB", ko, idx, len(ini), 0, 0, 0)
        m += 1

HDR = 40
koff = HDR
woff = koff + len(keys)
toff = (woff + len(words) + 3) & ~3
ioff = toff + len(table)
ikoff = ioff + len(itable)
blob = bytearray()
blob += struct.pack("<4sIIIIIII", b"PYD1", n, koff, woff, toff, m, ioff, ikoff)
blob += b"\0" * (HDR - len(blob))
blob += keys
blob += words
blob += b"\0" * (toff - len(blob))
blob += table
blob += itable
blob += ikeys
open(out, "wb").write(blob)
print("条数", n, "简拼条", m, "文件", len(blob), "字节")
