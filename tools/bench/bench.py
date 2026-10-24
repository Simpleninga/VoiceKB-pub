#!/usr/bin/env python3
"""拼音引擎跑分（CI 里每次都跑，数字低于 baseline.json 就判失败）。只用标准库 + tools/pyengine.py。
用法：python3 tools/bench/bench.py [--lm=lm.dat] [--user=用户模型] [--set=名字:文件.tsv ...] [--check] [--fails=目录]
测试集是「原句\t拼音[\t每个字的拼音（空格隔开）]」：chat = 110 句日常聊天（拼音全对），chat_typo = 同样的句子拼音里打错一个键，daily = 41 条网络用语 / 口语 / 专有名词（天胡、恰个饭、医患通…）。
分数 = 整句首选全对：第一个候选就是原句、而且吃掉了整串拼音。"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import pyengine

RES = os.path.join(ROOT, "Keyboard", "Resources")


def arg(name, default=None):
    return next((a.split("=", 1)[1] for a in sys.argv if a.startswith(f"--{name}=")), default)


def load(path):
    out = []
    for l in open(path, encoding="utf8"):
        f = l.rstrip("\n").split("\t")
        if len(f) >= 2 and f[0] and f[1]:
            out.append((f[0], f[1]))
    return out


def main():
    D = pyengine.Dict(os.path.join(RES, "pinyin.dat"))
    pyengine.load_syllables(os.path.join(ROOT, "tools", "syllables.txt"))
    lm = pyengine.LM(arg("lm", os.path.join(RES, "lm.dat")))
    sets = [(n, os.path.join(HERE, "data", n + ".tsv")) for n in ("chat", "chat_typo", "daily")]
    sets += [tuple(a.split("=", 1)[1].split(":", 1)) for a in sys.argv if a.startswith("--set=")]
    faildir = arg("fails")
    scores = {}
    for name, path in sets:
        rows = load(path)
        ok = ok2 = 0
        t, fails = 0.0, []
        for s, p in rows:
            t0 = time.time()
            c = pyengine.candidates(D, p, 14, False, lm, None)
            t += time.time() - t0
            hit = [x[0] == s and x[1] == len(p) for x in c[:2]]
            ok2 += any(hit)
            if hit and hit[0]:
                ok += 1
            else:
                fails.append(f"{s}\t{p}\t{c[0][0] if c else ''}")
        scores[name] = ok / len(rows)
        print(f"[{name}] {ok}/{len(rows)} = {ok / len(rows):.1%}  前两个里有 {ok2 / len(rows):.1%}  Python 平均 {t / len(rows) * 1000:.0f}ms/句", flush=True)
        if faildir:
            os.makedirs(faildir, exist_ok=True)
            open(os.path.join(faildir, name + ".txt"), "w", encoding="utf8").write("\n".join(fails) + "\n")
    if "--check" in sys.argv:
        base = json.load(open(os.path.join(HERE, "baseline.json")))
        bad = [f"{k} {scores[k]:.1%} < {v:.1%}" for k, v in base.items() if k in scores and scores[k] < v]
        if bad:
            print("跑分退步：" + "；".join(bad))
            sys.exit(1)
        print("跑分不低于基线 OK")


if __name__ == "__main__":
    main()
