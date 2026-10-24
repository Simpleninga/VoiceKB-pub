#!/usr/bin/env python3
"""模糊音跑分：把 chat 句子里的音节按模糊音随机换成「口音版」（z↔zh、n↔l、an↔ang、f↔h…），看打开模糊音后整句首选能不能还原；
同时看打对的句子（干净输入）打开模糊音后有没有变差。用法：python3 tools/bench/fuzzy.py [--mask=15] [--prob=0.35] [--seed=1] [--n=110]"""
import os, random, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pyengine

RES = os.path.join(ROOT, "Keyboard", "Resources")


def arg(name, default):
    return next((a.split("=", 1)[1] for a in sys.argv if a.startswith(f"--{name}=")), default)


def main():
    if arg("pen", None):
        pyengine.PEN_FUZZ = int(float(arg("pen", 1.2)) * 2048)
    mask, prob, seed, nmax = int(arg("mask", 15)), float(arg("prob", 0.35)), int(arg("seed", 1)), int(arg("n", 110))
    D = pyengine.Dict(os.path.join(RES, "pinyin.dat"))
    pyengine.load_syllables(os.path.join(ROOT, "tools", "syllables.txt"))
    lm = pyengine.LM(os.path.join(RES, "lm.dat"))
    rng = random.Random(seed)
    rows = []
    for l in open(os.path.join(HERE, "data", "chat.tsv"), encoding="utf8"):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 3:
            rows.append((f[0], f[1], f[2].split()))
    rows = rows[:nmax]
    acc = {"clean_off": 0, "clean_on": 0, "fuzzy_off": 0, "fuzzy_on": 0, "fuzzy_on2": 0}
    t_on = 0.0
    changed_total = 0
    fails = []
    for s, p, syls in rows:
        out = []
        ch = 0
        for t in syls:
            vs = pyengine.syl_variants(t, mask)
            if vs and rng.random() < prob:
                out.append(rng.choice(vs))
                ch += 1
            else:
                out.append(t)
        changed_total += ch
        typed = "".join(out)

        def top(raw, m):
            pyengine.FUZZ = m
            t0 = time.time()
            c = pyengine.candidates(D, raw, 14, False, lm, None)
            return c, time.time() - t0

        for name, raw, m in (("clean_off", p, 0), ("clean_on", p, mask), ("fuzzy_off", typed, 0), ("fuzzy_on", typed, mask)):
            c, dt = top(raw, m)
            if name in ("clean_on", "fuzzy_on"):
                t_on += dt
            hit = [x[0] == s and x[1] == len(raw) for x in c[:2]]
            if hit and hit[0]:
                acc[name] += 1
            if name == "fuzzy_on":
                if any(hit):
                    acc["fuzzy_on2"] += 1
                elif ch:
                    fails.append(f"{s}\t{typed}\t{c[0][0] if c else ''}")
    n = len(rows)
    print(f"句数 {n}，换了 {changed_total} 个音节（{changed_total / sum(len(r[2]) for r in rows):.0%}），mask={mask}")
    for k, v in acc.items():
        print(f"  {k}: {v}/{n} = {v / n:.1%}")
    print(f"  打开模糊音后 Python 平均 {t_on / (2 * n) * 1000:.0f}ms/句")
    if "--fails" in sys.argv:
        print("\n".join(fails[:40]))
    if "--check" in sys.argv:       # 门槛：口音版输入打开模糊音要 ≥ 74%；打对的句子打开模糊音不许掉到 80% 以下
        bad = []
        if acc["fuzzy_on"] / n < 0.74:
            bad.append(f"口音版 {acc['fuzzy_on'] / n:.1%} < 74%")
        if acc["clean_on"] / n < 0.80:
            bad.append(f"打对的句子开模糊音后 {acc['clean_on'] / n:.1%} < 80%")
        if bad:
            print("模糊音跑分退步：" + "；".join(bad))
            sys.exit(1)
        print("模糊音跑分 OK")


if __name__ == "__main__":
    main()
