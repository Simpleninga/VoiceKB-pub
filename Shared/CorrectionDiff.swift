import Foundation

/// 听写打进输入框之后，用户改了哪些词。只比这段话的前后两个样子，算出「原来 → 改成」，
/// 再带上左右各两个字（只改了一个字时，服务器拿它补成词）。值不值得学由服务器判断
enum CorrectionDiff {
    struct Pair: Equatable {
        let from: String, to: String, left: String, right: String
    }

    private static func word(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 改动太多（超过一半的字）当成重写，不学
    static func pairs(old: String, new: String) -> [Pair] {
        let o = Array(old), n = Array(new)
        let d = n.difference(from: o)
        var rm = Set<Int>(), ins = Set<Int>()
        for c in d {
            switch c {
            case let .remove(i, _, _): rm.insert(i)
            case let .insert(i, _, _): ins.insert(i)
            }
        }
        guard !rm.isEmpty, rm.count * 2 <= o.count else { return [] }
        // 走一遍两个数组，连续的改动并成一段：(原文起止, 新文起止)
        var hunks: [(Int, Int, Int, Int)] = []
        var i = 0, j = 0
        while i < o.count || j < n.count {
            if rm.contains(i) || ins.contains(j) {
                let a = i, b = j
                while rm.contains(i) || ins.contains(j) {
                    if rm.contains(i) { i += 1 }
                    if ins.contains(j) { j += 1 }
                }
                // Cloud→Claude 在字母中间断成两段：隔得近的并起来
                if let l = hunks.last, a - l.1 <= 2 { hunks[hunks.count - 1] = (l.0, i, l.2, j) } else { hunks.append((a, i, b, j)) }
            } else {
                i += 1
                j += 1
            }
        }
        // 英文要整词：Cloud→Claude 只算 ou→au 没有意义。补完整词后相交的段再并起来
        func isWord(_ c: Character?) -> Bool { c.map(word) ?? false }
        var whole: [(Int, Int, Int, Int)] = []
        for var h in hunks {
            while h.0 > 0, h.2 > 0, o[h.0 - 1] == n[h.2 - 1], word(o[h.0 - 1]),
                  isWord(h.0 < h.1 ? o[h.0] : nil) || isWord(h.2 < h.3 ? n[h.2] : nil) { h.0 -= 1; h.2 -= 1 }
            while h.1 < o.count, h.3 < n.count, o[h.1] == n[h.3], word(o[h.1]),
                  isWord(h.1 > h.0 ? o[h.1 - 1] : nil) || isWord(h.3 > h.2 ? n[h.3 - 1] : nil) { h.1 += 1; h.3 += 1 }
            if let l = whole.last, h.0 <= l.1 {
                whole[whole.count - 1] = (min(l.0, h.0), max(l.1, h.1), min(l.2, h.2), max(l.3, h.3))
            } else {
                whole.append(h)
            }
        }
        var out: [Pair] = []
        for h in whole where h.1 > h.0 && h.3 > h.2 {
            out.append(Pair(from: String(o[h.0..<h.1]), to: String(n[h.2..<h.3]),
                            left: String(o[max(0, h.0 - 2)..<h.0]), right: String(o[h.1..<min(o.count, h.1 + 2)])))
        }
        return out
    }
}
