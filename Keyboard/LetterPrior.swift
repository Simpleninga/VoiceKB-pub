import Foundation

/// 动态热区用的「下一个字母更可能是谁」（三期，触点模型的简化版）：
/// 拼音字母不是乱打的——打了 x 之后下一个只可能是 i / u（xo、xe 不是音节），打了 zh 之后只可能是元音。手指落在两个字母键的交界处时，
/// 让更可能的那个多占几个点（KeyboardRoot.letterBias，最多 ±3pt），按偏了也更容易落对。键中间不受影响（只在交界 3pt 以内起作用）。
/// 做法：输入串末尾那个「还没打完的音节」p（取最长的、前面的部分能切成合法音节的）→ 看音节表里 p 后面能接哪些字母，按音节的常用程度（该音节最常用字的词频）加权；
/// p 本身已经是个完整音节时，下一个字母也可能开始新的音节（按「p 结束」的权重混进来）。
final class LetterPrior {
    private let syl: [(s: [UInt8], w: Double)]
    private let total: Double
    private var cacheKey = "\u{0}"
    private var cache: [UInt8: Double] = [:]

    /// weight：音节 → 权重（词典里这个音节最常用字的词频，没有就给 1）
    init(weight: (String) -> Double) {
        var list: [(s: [UInt8], w: Double)] = []
        for s in pinyinSyllables.sorted() { list.append((Array(s.utf8), max(1, weight(s)))) }
        syl = list
        total = list.reduce(0) { $0 + $1.w }
    }

    /// 字母串 r（全是小写字母）能不能整个切成合法音节
    private func canSegment(_ r: ArraySlice<UInt8>) -> Bool {
        let a = Array(r)
        if a.isEmpty { return true }
        var ok = [Bool](repeating: false, count: a.count + 1)
        ok[0] = true
        for i in 0..<a.count where ok[i] {
            for l in 1...6 where i + l <= a.count {
                if pinyinSyllables.contains(String(decoding: a[i..<(i + l)], as: UTF8.self)) { ok[i + l] = true }
            }
        }
        return ok[a.count]
    }

    /// buffer（拼音输入串，可含 '）之后下一个字母的相对可能性：字母（ASCII）→ 0...1，最可能的是 1，不可能的没有
    func prior(buffer: String) -> [UInt8: Double] {
        if buffer == cacheKey { return cache }
        var letters = Array(buffer.utf8.filter { $0 >= 97 && $0 <= 122 })
        if let q = buffer.lastIndex(of: "'") { letters = Array(buffer[buffer.index(after: q)...].utf8.filter { $0 >= 97 && $0 <= 122 }) }
        var p: [UInt8] = []
        for l in stride(from: min(5, letters.count), through: 1, by: -1) {
            let cand = Array(letters.suffix(l))
            if syl.contains(where: { $0.s.starts(with: cand) }), canSegment(letters.dropLast(l)) {
                p = cand
                break
            }
        }
        var mass: [UInt8: Double] = [:]
        var ext = 0.0, end = 0.0
        for e in syl where e.s.starts(with: p) {
            if e.s.count > p.count {
                ext += e.w
                mass[e.s[p.count], default: 0] += e.w
            } else {
                end = e.w
            }
        }
        let denom = ext + end
        var out: [UInt8: Double] = [:]
        if denom > 0 {
            for (c, m) in mass { out[c] = m / denom }
            if end > 0 {      // p 已经是完整音节：下一个字母也可能是新音节的开头
                for e in syl { out[e.s[0], default: 0] += end / denom * e.w / total }
            }
        }
        let top = out.values.max() ?? 0
        if top > 0 { for (c, v) in out { out[c] = v / top } }
        cacheKey = buffer
        cache = out
        return out
    }

    /// 交界处让出 / 多占的点数：最可能的 +3，不可能的 −3，中间按可能性（取 0.35 次方让「还算可能」的也有些好处）
    static func bias(_ prior: Double?) -> CGFloat {
        guard let p = prior else { return -3 }
        return CGFloat(3 * (2 * pow(p, 0.35) - 1))
    }
}
