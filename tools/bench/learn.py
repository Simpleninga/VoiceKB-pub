#!/usr/bin/env python3
"""个人学习的留出测试：一组句子里前 N 句模拟「打过一遍」（逐段从前 5 个候选里选，选完按键盘的规矩学），
剩下没见过的句子看整句首选涨了多少；也测「语音说过」（只喂语音整理好的文字）和「同一句再打一遍」。
用法：python3 tools/bench/learn.py <句子.tsv（原句\\t拼音\\t每个字的拼音）> [--train=训练句数，默认 3/4] [--seed=1] [--dump=学完的模型存到哪]
学的规矩（键盘 KeyboardViewController 照这个做）：
  一次拼字（输入串从有到空）选出来的每一段 → 它的切词按顺序记词频、词对（第一个词和上文最后一个词也记一对）；
  分了 ≥2 段选、合起来 2~6 个字、词典里没有这个键+词 → 记成自造词。"""
import os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pyengine

RES = os.path.join(ROOT, "Keyboard", "Resources")


def arg(name, default=None):
    return next((a.split("=", 1)[1] for a in sys.argv if a.startswith(f"--{name}=")), default)


def type_session(D, lm, user, s, syl, ctx):
    """模拟打一句：每次在前 5 个候选里挑「是剩下原句的开头、吃掉的拼音正好是这几个字的拼音」里最长的那个。
    返回 [(文字, 吃掉的字母（纠错过的取纠正后的）, 切词)]；挑不到返回 None（真人得翻页或删了重打）"""
    rest, raw, chunks, i = s, "".join(syl), [], 0
    prev = ctx
    while rest:
        best = None
        for t, cons, kind, fix, parts in pyengine.candidates(D, raw, 5, False, lm, prev, user)[:5]:
            k = len(t)
            if rest.startswith(t) and cons == len("".join(syl[i:i + k])) and (best is None or k > len(best[0])):
                best = (t, fix or raw[:cons], parts, cons)
        if not best:
            return None
        t, key, parts, cons = best
        chunks.append((t, key, parts))
        rest, raw, i, prev = rest[len(t):], raw[cons:], i + len(t), parts[-1]
    return chunks


def learn_session(D, user, chunks, prev):
    user.learn([w for _, _, parts in chunks for w in parts], prev)
    if len(chunks) >= 2:
        text = "".join(t for t, _, _ in chunks)
        key = "".join(k for _, k, _ in chunks).encode()
        if 2 <= len(text) <= 6 and not any(D.entry(e)[0] == text for e in D.exact(key)):
            user.add_phrase(key, text)


def top1(D, lm, user, rows):
    ok = 0
    for s, p, _ in rows:
        c = pyengine.candidates(D, p, 14, False, lm, None, user)
        ok += bool(c and c[0][0] == s and c[0][1] == len(p))
    return ok / len(rows)


def main():
    D = pyengine.Dict(os.path.join(RES, "pinyin.dat"))
    pyengine.load_syllables(os.path.join(ROOT, "tools", "syllables.txt"))
    lm = pyengine.LM(os.path.join(RES, "lm.dat"))
    rows = []
    for l in open(sys.argv[1], encoding="utf8"):
        f = l.rstrip("\n").split("\t")
        if len(f) == 3:
            rows.append((f[0], f[1], f[2].split(" ")))
    random.Random(int(arg("seed", "1"))).shuffle(rows)
    ntr = int(arg("train", str(len(rows) * 3 // 4)))
    train, test = rows[:ntr], rows[ntr:]
    print(f"训练 {len(train)} 句，留出 {len(test)} 句")
    print(f"[不学] 留出 {top1(D, lm, None, test):.1%}  训练句 {top1(D, lm, None, train):.1%}", flush=True)
    u = pyengine.User()
    typed = 0
    for s, p, syl in train:
        ch = type_session(D, lm, u, s, syl, None)
        if ch:
            typed += 1
            learn_session(D, u, ch, None)
    print(f"[打过训练句后] 能在前 5 里逐段选完 {typed}/{len(train)}；学到 词 {len(u.w)} 词对 {len(u.b)} 自造词 {len(u.p)}")
    print(f"    留出 {top1(D, lm, u, test):.1%}  同一句再打一遍 {top1(D, lm, u, train):.1%}", flush=True)
    if arg("dump"):
        open(arg("dump"), "w", encoding="utf8").write(u.dump())
    v = pyengine.User()
    for s, _, _ in train:
        pyengine.learn_text(v, lm, s)
    print(f"[语音说过训练句后] 学到 词 {len(v.w)} 词对 {len(v.b)}")
    print(f"    留出 {top1(D, lm, v, test):.1%}  同一句再打一遍 {top1(D, lm, v, train):.1%}", flush=True)


if __name__ == "__main__":
    main()
