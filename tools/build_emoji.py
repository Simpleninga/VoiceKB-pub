#!/usr/bin/env python3
"""生成 Keyboard/Resources/emoji.txt：拼音 → 表情联想（三期）。
数据：Unicode CLDR 的中文表情注释（annotations/zh，Unicode 许可）+ tools/emoji_aliases.txt（手写的口语叫法：哈哈、谢谢、加油…）。
每行 `拼音键\t关键词\t表情 表情 …`：键盘里「输入的拼音正好是这个键」就在候选后面补表情；选了一个词（比如「哈哈」）后联想行里也先给它的表情。
关键词的拼音取词典里这个词的写法（没有就逐字取每个字最常用的读音）；太泛的词（脸、手、表情、动物…）和一个字的词（别名表里点名的除外）不收。
用法：python3 tools/build_emoji.py annotations-zh.json 输出 emoji.txt"""
import json, os, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pyengine

src, out = sys.argv[1], sys.argv[2]
D = pyengine.Dict(os.path.join(HERE, "..", "Keyboard", "Resources", "pinyin.dat"))

# 词 → 最常用读音（整词优先）；单字 → 最常用读音
best = {}
for i in range(D.n):
    w, q = D.entry_raw(i)
    k = D.keys[i].decode()
    if w not in best or q > best[w][0]:
        best[w] = (q, k)


def pinyin_of(word):
    if word in best:
        return best[word][1]
    parts = []
    for ch in word:
        if ch not in best:
            return None
        parts.append(best[ch][1])
    return "".join(parts)


GENERIC = set("脸 手 表情 动物 人 人物 符号 标志 颜色 食物 饮食 水果 蔬菜 交通 运动 天气 自然 物品 工具 乐器 建筑 地点 旗帜 国旗 时间 钟 箭头 几何 图形 方块 圆 圈 点 线 星座 十二生肖 字母 数字 肤色 男 女 男人 女人 孩子 儿童 成人 老人 身体 衣服 服装 帽子 鞋 动植物 植物 花 树 鸟 鱼 昆虫 爬行动物 哺乳动物 月 日 周 年 季节 节日 活动 游戏 艺术 音乐 办公 文件 电脑 电子 设备 通信 声音 灯光 医疗 医学 科学 货币 金融 家 家庭 家具 厨房 容器 餐具 饮料 酒 甜点 糕点 零食 汤 面 饭 肉 海鲜".split())
KEEP_ONE = set("笑 哭 爱 赞 心 吻 怒 睡 酷 汗 病 钱 花 雨 雪 火 猫 狗 猪 牛 鸡 鸭 鱼 虫 龙 蛇 马 羊 猴 兔 鼠 虎 茶 酒 饭 面 药 吐 惊 怕 烦 累 饿 困 晕 臭 呆 傻 萌 哈 嘿 嗯 哦".split())

ann = json.load(open(src, encoding="utf8"))["annotations"]["annotations"]
kw = collections.OrderedDict()      # 关键词 → [表情…]（按 CLDR 顺序，去重）

# 不带 FE0F 就会画成黑白小字符的 BMP 表情（补上 FE0F 变成彩色表情）；不在这个表里的 BMP 符号（♪ ★ ☆ 箭头括号…）不收
BMP_EMOJI = set("☀☁☂☃☄☎☑☔☕☘☝☠☢☣☦☪☮☯☸☹☺♀♂♈♉♊♋♌♍♎♏♐♑♒♓♟♠♣♥♦♨♻♾♿⚒⚓⚔⚕⚖⚗⚙⚛⚜⚠⚡⚧⚪⚫⚰⚱⚽⚾⛄⛅⛈⛎⛏⛑⛓⛔⛩⛪⛰⛱⛲⛳⛴⛵⛷⛸⛹⛺⛽✂✅✈✉✊✋✌✍✏✒✔✖✝✡✨✳✴❄❇❌❎❓❔❕❗❣❤➕➖➗➡➰➿⤴⤵⬅⬆⬇⬛⬜⭐⭕〰〽㊗㊙©®‼⁉™ℹ↔↕↖↗↘↙↩↪⌚⌛⌨⏏⏩⏪⏫⏬⏭⏮⏯⏰⏱⏲⏳⏸⏹⏺Ⓜ▪▫▶◀◻◼◽◾")


def good_emoji(e):
    cps = [ord(c) for c in e]
    if any(0x1F1E6 <= c <= 0x1F1FF for c in cps) or any(0x1F3FB <= c <= 0x1F3FF for c in cps):
        return None            # 国旗、肤色版本不要
    if 0x200D in cps:
        return None            # 组合表情（男医生、情侣…）只在别名表里手写
    if len(cps) == 1 and cps[0] < 0x1F000:
        return e + "\ufe0f" if e in BMP_EMOJI else None
    if len(cps) == 2 and cps[1] == 0xFE0F:
        return e if e[0] in BMP_EMOJI else None
    return e if cps[0] >= 0x1F000 else None


def add(word, e):
    word = word.strip()
    if not (2 <= len(word) <= 5) or word in GENERIC or not all("\u4e00" <= c <= "\u9fff" for c in word):
        return
    e = good_emoji(e)
    if not e:
        return
    lst = kw.setdefault(word, [])
    if e not in lst:
        lst.append(e)


for e, v in ann.items():
    names = list(v.get("tts", []))      # 只用 CLDR 的标准名（红心、玫瑰、生日蛋糕…）；零散关键词（笑、脸、手…）太泛，口语叫法靠别名表
    for w in names:
        add(w, e)

# 手写的口语叫法放最前（覆盖 CLDR 的排序）
aliases = set()
for line in open(os.path.join(HERE, "emoji_aliases.txt"), encoding="utf8"):
    line = line.split("#")[0].strip()
    if not line:
        continue
    word, _, es = line.partition("\t")
    es = es.split()
    aliases.add(word)
    old = kw.get(word, [])
    kw[word] = es + [x for x in old if x not in es]

rows = []
for word, es in kw.items():
    if len(es) > 8 and word not in aliases:
        continue        # 一个词对着一大堆表情：太泛，不收
    k = pinyin_of(word)
    if k:
        rows.append((k, word, es[:4]))
rows.sort()
with open(out, "w", encoding="utf8") as f:
    for k, w, es in rows:
        f.write(f"{k}\t{w}\t{' '.join(es)}\n")
print(len(rows), "行", os.path.getsize(out), "字节")
