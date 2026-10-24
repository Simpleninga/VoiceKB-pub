import Foundation

/// 个人学习：选过的词、整句、语音整理好的话都记下来，按用过的次数给代价打折（「越用越懂你」）。
/// 和 Python 参考版 tools/pyengine.py 的 User 逐字一致（CI 对拍），参数怎么调出来的见那边和 tools/bench/learn.py。
/// w = 词（≥2 个字）的次数；b = （上一个词, 词）的次数；p = 自造词（分几次选出来的短词组，词典里没有这个键 + 词）。
/// 都留「最近一次的序号」，满了扔掉最久没用的。存成一个文本文件（键盘扩展自己的容器里，免费签名没有 App Group）。
final class UserModel {
    static let capW = 3000, capB = 6000, capP = 1000
    static let bonusW: [Int] = [0, 1.2, 1.8, 2.1, 2.4, 2.6, 2.8, 2.9, 3.0].map { Int($0 * 2048) }     // 词用过 0~8 次以上
    static let bonusB: [Int] = [0, 2.4, 3.6, 4.2, 4.6, 5.0, 5.2, 5.4, 5.6].map { Int($0 * 2048) }     // 词对用过 0~8 次以上
    static let phraseQ = Int(12.0 * 2048)      // 自造词的一元权重（ln 权重 × 2048）

    struct Count { var n: Int; var last: Int }
    struct Pair: Hashable { let a: String; let b: String }
    struct Phrase: Hashable { let key: [UInt8]; let word: String }

    private(set) var w: [String: Count] = [:]
    private(set) var b: [Pair: Count] = [:]
    private(set) var p: [Phrase: Count] = [:]
    private(set) var seq = 0
    private var plistCache: [Phrase]?
    private var pidx: [[UInt8]: [Int]] = [:]

    init() {}

    /// 读 dump() 写出的文本（坏行跳过）
    init(text: String) {
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch (f.first, f.count) {
            case ("w", 4): if let n = Int(f[2]), let t = Int(f[3]) { w[f[1]] = Count(n: n, last: t) }
            case ("b", 5): if let n = Int(f[3]), let t = Int(f[4]) { b[Pair(a: f[1], b: f[2])] = Count(n: n, last: t) }
            case ("p", 5): if let n = Int(f[3]), let t = Int(f[4]) { p[Phrase(key: Array(f[1].utf8), word: f[2])] = Count(n: n, last: t) }
            case ("s", 2): seq = Int(f[1]) ?? 0
            default: break
            }
        }
    }

    var isEmpty: Bool { w.isEmpty && b.isEmpty && p.isEmpty }
    var size: Int { w.count + b.count + p.count }

    /// 文本：首行 VKU1；w 词 次数 序号 / b 上一个词 词 次数 序号 / p 键 词 次数 序号 / s 当前序号（\t 分隔，各段按序号排）
    func dump() -> String {
        var out = ["VKU1"]
        out += w.sorted { $0.value.last < $1.value.last }.map { "w\t\($0.key)\t\($0.value.n)\t\($0.value.last)" }
        out += b.sorted { $0.value.last < $1.value.last }.map { "b\t\($0.key.a)\t\($0.key.b)\t\($0.value.n)\t\($0.value.last)" }
        out += p.sorted { $0.value.last < $1.value.last }.map { "p\t\(String(decoding: $0.key.key, as: UTF8.self))\t\($0.key.word)\t\($0.value.n)\t\($0.value.last)" }
        out.append("s\t\(seq)")
        return out.joined(separator: "\n") + "\n"
    }

    /// 自造词按（键, 词的 UTF-8）排好的表：词格里它们的虚词条序号 = 词典条数 + 下标
    var plist: [Phrase] {
        if let c = plistCache { return c }
        let l = p.keys.sorted { $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key) : Array($0.word.utf8).lexicographicallyPrecedes(Array($1.word.utf8)) }
        pidx = [:]
        for (i, x) in l.enumerated() { pidx[x.key, default: []].append(i) }
        plistCache = l
        return l
    }

    /// 键正好是 key 的自造词在 plist 里的下标（升序）
    func phrases(_ key: [UInt8]) -> [Int] {
        _ = plist
        return pidx[key] ?? []
    }

    var hasPhrases: Bool { !p.isEmpty }

    func count(of ph: Phrase) -> Int { p[ph]?.n ?? 0 }

    /// 词 w（接在 prev 后面）用过的打折
    func bonus(_ prev: String?, _ w: String) -> Int {
        var x = 0
        if let c = self.w[w] { x += Self.bonusW[min(c.n, 8)] }
        if let prev, let c = b[Pair(a: prev, b: w)] { x += Self.bonusB[min(c.n, 8)] }
        return x
    }

    private func touch<K: Hashable>(_ table: inout [K: Count], _ k: K, _ cap: Int) {
        seq += 1
        if var v = table[k] {
            v.n += 1
            v.last = seq
            table[k] = v
            return
        }
        table[k] = Count(n: 1, last: seq)
        if table.count > cap {         // 满了：按最近一次用的先后，扔掉最久没用的，留九成
            let drop = table.count - cap * 9 / 10
            for (old, _) in table.sorted(by: { $0.value.last < $1.value.last }).prefix(drop) { table[old] = nil }
        }
    }

    /// words = 挨着上屏的词（一次拼字选出来的、一句整句切出来的），prev = 它前面那个词（上文，没有就 nil）
    func learn(_ words: [String], prev: String?) {
        var prev = prev
        for x in words {
            if x.unicodeScalars.count >= 2 { touch(&w, x, Self.capW) }
            if let a = prev { touch(&b, Pair(a: a, b: x), Self.capB) }
            prev = x
        }
    }

    func addPhrase(key: [UInt8], word: String) {
        touch(&p, Phrase(key: key, word: word), Self.capP)
        plistCache = nil
    }

    private static func cjk(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) } }

    /// 按语言模型的词表正向最长匹配（最长 4 个字）切词；认不出的字单独一个（按 Unicode 码位走，和 Python 一致）
    static func segment(_ lm: LMDict, _ text: String) -> [String] {
        let u = Array(text.unicodeScalars)
        var out: [String] = []
        var i = 0
        func str(_ a: Int, _ l: Int) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: u[a..<(a + l)]); return String(v) }
        while i < u.count {
            var l = min(4, u.count - i)
            while l > 1, lm.id(of: str(i, l)) < 0 { l -= 1 }
            out.append(str(i, l))
            i += l
        }
        return out
    }

    /// 语音整理好的一段话：切词后连着的汉字词记词频和词对（标点、英文、数字处断开上下文）
    func learnText(_ lm: LMDict, _ text: String, prev: String? = nil) {
        var run: [String] = []
        var prev = prev
        for x in Self.segment(lm, text) {
            if Self.cjk(x) { run.append(x); continue }
            if !run.isEmpty { learn(run, prev: prev) }
            run = []
            prev = nil
        }
        if !run.isEmpty { learn(run, prev: prev) }
    }
}
