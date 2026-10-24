import Foundation

// 对拍用：swiftc Keyboard/Syllables.swift Keyboard/LanguageModel.swift Keyboard/UserModel.swift Keyboard/PinyinEngine.swift tools/EngineTest/main.swift
// 用法：enginetest pinyin.dat [lm.dat] [--user=个人学习文件] 输入串...  （输出格式和 tools/pyengine.py 一样，CI 里两边 diff）
// 输入串可以写成「上文词@拼音」（上文词 = 光标前最后一个词）；「上文词@」= 只看联想预测
var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 1, let dict = PinyinDict(path: args.removeFirst()) else {
    print("打不开词典")
    exit(1)
}
var lm: LMDict?
if let f = args.first, f.hasSuffix(".dat") {
    lm = LMDict(path: f)
    args.removeFirst()
}
let engine = PinyinEngine(dict: dict, lm: lm)
if let f = args.first, f.hasPrefix("--user=") {      // 个人学习：--user=文件（格式见 UserModel.dump）
    engine.user = UserModel(text: (try? String(contentsOfFile: String(f.dropFirst(7)), encoding: .utf8)) ?? "")
    args.removeFirst()
}
// 量速度：enginetest pinyin.dat lm.dat [--user=…] --bench 测试集.tsv…（原句\t拼音）：每句一个字母一个字母地打，量每次出候选要多久
if args.first == "--bench" {
    var ms: [Double] = []
    var worst = ("", 0.0)
    for f in args.dropFirst() {
        guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count >= 2 else { continue }
            let p = String(cols[1])
            for k in 1...p.count {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = engine.candidates(String(p.prefix(k)), limit: 40)
                let d = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                ms.append(d)
                if d > worst.1 { worst = (String(p.prefix(k)), d) }
            }
        }
    }
    ms.sort()
    func q(_ x: Double) -> String { String(format: "%.2f", ms[min(ms.count - 1, Int(Double(ms.count) * x))]) }
    print("按键 \(ms.count) 次：中位 \(q(0.5))ms  p90 \(q(0.9))ms  p95 \(q(0.95))ms  p99 \(q(0.99))ms  最慢 \(String(format: "%.2f", worst.1))ms（\(worst.0)）")
    exit(0)
}
for s in args {
    var ctx = "", rest = s
    if let at = s.lastIndex(of: "@") {
        ctx = String(s[..<at])
        rest = String(s[s.index(after: at)...])
    }
    if rest.hasPrefix("#") {      // 九键：#64426 = 数字串（可夹已选好的音节字母和 '）
        let t = String(rest.dropFirst())
        func fmt(_ cs: [PinyinCandidate]) -> String { cs.map { "\($0.text)[\($0.kind.rawValue)\($0.consume) \($0.key)]" }.joined(separator: " ") }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let first = engine.t9Candidates(t, limit: 14, ctx: ctx)
        FileHandle.standardError.write(Data("九键 \(t) 出候选 \(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)ms\n".utf8))
        print("\(s) → \(fmt(first))")
        print("\(s)* → \(fmt(engine.t9Candidates(t, limit: 200, expanded: true, ctx: ctx)))")
        let syl = engine.t9Syllables(t)
        print("\(s)~ → \(syl.opts.joined(separator: " ")) @ \(syl.start)")
        continue
    }
    if s.contains("@"), rest.isEmpty {
        print("\(s) → \(engine.predict(after: ctx, limit: 12).joined(separator: " "))")
        continue
    }
    func tag(_ c: PinyinCandidate) -> String { "\(c.text)[\(c.kind.rawValue)\(c.consume)\(c.fix.isEmpty ? "" : "~" + c.fix)]" }
    let cs = engine.candidates(rest, limit: 14, ctx: ctx).map(tag)
    print("\(s) (\(engine.display(rest))) → \(cs.joined(separator: " "))")
    let ex = engine.candidates(rest, limit: 200, expanded: true, ctx: ctx).map(tag)
    print("\(s)* → \(ex.joined(separator: " "))")
}
