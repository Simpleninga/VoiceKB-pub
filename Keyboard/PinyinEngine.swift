import Foundation

/// 内存映射的拼音词典（格式见 tools/build_dict.py）。文件是只读映射，不占键盘扩展那点可怜的内存。
final class PinyinDict {
    private let base: UnsafeRawPointer
    private let size: Int
    let count: Int
    private let keyOff: Int, wordOff: Int, tableOff: Int
    private let initCount: Int, initTableOff: Int, initKeyOff: Int

    init?(path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 40 else { return nil }
        let len = Int(st.st_size)
        guard let p = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0), p != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        let b = UnsafeRawPointer(p)
        func u32(_ o: Int) -> Int { Int(b.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        guard u32(0) == 0x3144_5950 else { munmap(p, len); return nil }    // "PYD1"
        base = b
        size = len
        count = u32(4)
        keyOff = u32(8)
        wordOff = u32(12)
        tableOff = u32(16)
        initCount = u32(20)
        initTableOff = u32(24)
        initKeyOff = u32(28)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    // MARK: 词条

    @inline(__always) private func ent(_ i: Int) -> UnsafeRawPointer { base + tableOff + i * 12 }

    @inline(__always) func keyPtr(_ i: Int) -> (UnsafePointer<UInt8>, Int) {
        let e = ent(i)
        let ko = Int(e.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        let kl = Int(e.load(fromByteOffset: 8, as: UInt8.self))
        return ((base + keyOff + ko).assumingMemoryBound(to: UInt8.self), kl)
    }

    func keyLength(_ i: Int) -> Int { Int(ent(i).load(fromByteOffset: 8, as: UInt8.self)) }

    func key(_ i: Int) -> [UInt8] {
        let (p, l) = keyPtr(i)
        return Array(UnsafeBufferPointer(start: p, count: l))
    }

    func word(_ i: Int) -> String {
        let e = ent(i)
        let wo = Int(e.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let wl = Int(e.load(fromByteOffset: 9, as: UInt8.self))
        let p = (base + wordOff + wo).assumingMemoryBound(to: UInt8.self)
        return String(decoding: UnsafeBufferPointer(start: p, count: wl), as: UTF8.self)
    }

    /// 权重整数 q = round(ln(权重 + 1) * 2048)
    func rawWeight(_ i: Int) -> Int { Int(ent(i).loadUnaligned(fromByteOffset: 10, as: UInt16.self)) }

    /// ln(权重 + 1)
    func logWeight(_ i: Int) -> Double {
        Double(ent(i).loadUnaligned(fromByteOffset: 10, as: UInt16.self)) / 2048.0
    }

    // MARK: 查找

    private func compare(_ i: Int, _ k: UnsafePointer<UInt8>, _ kl: Int) -> Int {
        let (p, pl) = keyPtr(i)
        let r = memcmp(p, k, min(pl, kl))
        return r != 0 ? Int(r) : pl - kl
    }

    private func lowerBound(_ k: UnsafePointer<UInt8>, _ kl: Int) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if compare(mid, k, kl) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// [lo, hi) 里第一个键 ≥ k 的位置（词典按键的字节序排好）
    func lowerBound(_ k: [UInt8], from lo: Int, to hi: Int) -> Int {
        k.withUnsafeBufferPointer { kp in
            var lo = lo, hi = hi
            while lo < hi {
                let mid = (lo + hi) / 2
                if compare(mid, kp.baseAddress!, kp.count) < 0 { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// 键刚好等于 k 的词条（权重从大到小），最多 60 条
    func exact(_ k: UnsafePointer<UInt8>, _ kl: Int) -> Range<Int> {
        let lo = lowerBound(k, kl)
        var hi = lo
        while hi < count, hi - lo < 60, compare(hi, k, kl) == 0 { hi += 1 }
        return lo..<hi
    }

    /// 键以 k 开头的词条的区间（不限条数）
    func prefix(_ k: UnsafePointer<UInt8>, _ kl: Int) -> Range<Int> {
        let lo = lowerBound(k, kl)
        var hi = lo
        while hi < count {
            let (p, pl) = keyPtr(hi)
            if pl < kl || memcmp(p, k, kl) != 0 { break }
            hi += 1
        }
        return lo..<hi
    }

    /// 简拼键等于 k 的词条序号（权重从大到小）
    func initials(_ k: UnsafePointer<UInt8>, _ kl: Int, limit: Int) -> [Int] {
        @inline(__always) func row(_ i: Int) -> (UnsafePointer<UInt8>, Int, Int) {
            let e = base + initTableOff + i * 12
            let ko = Int(e.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            let idx = Int(e.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let l = Int(e.load(fromByteOffset: 8, as: UInt8.self))
            return ((base + initKeyOff + ko).assumingMemoryBound(to: UInt8.self), l, idx)
        }
        func cmp(_ i: Int) -> Int {
            let (p, pl, _) = row(i)
            let r = memcmp(p, k, min(pl, kl))
            return r != 0 ? Int(r) : pl - kl
        }
        var lo = 0, hi = initCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if cmp(mid) < 0 { lo = mid + 1 } else { hi = mid }
        }
        var out: [Int] = []
        var i = lo
        while i < initCount, out.count < limit, cmp(i) == 0 {
            out.append(row(i).2)
            i += 1
        }
        return out
    }
}

enum PinyinKind: String {
    case full = "全", sentence = "句", assoc = "联", prefixSentence = "前句", prefix = "前", initials = "简", raw = "原", fuzzy = "纠", user = "自"
}

struct PinyinCandidate {
    let text: String
    /// 选了它以后，从输入串（含分词符 '）左边吃掉多少个字符
    let consume: Int
    let kind: PinyinKind
    /// 九键：这个词在词典里的拼音键（顶栏上显示「ni hao」用）
    var key = ""
    /// 纠错：纠正后的拼音（只算吃掉的那段，不含 '）；没改过拼音的是空串。顶栏显示纠正后的拼音、改过的字母标红
    var fix = ""
    /// 由哪几个词组成（整句的切词；其它就是它自己），个人学习用
    var parts: [String] = []
}

/// 拼音引擎：整词 / 整句（词频动态规划）/ 联想 / 简拼。Python 参考实现在 tools/pyengine.py，两边要保持一致（CI 里会对拍）。
final class PinyinEngine {
    static let lnTotal = 21.0
    static let maxKey = 60

    static let uniBase = Int(lnTotal * 2048)     // 一元代价（整数，单位 1/2048 纳特）= uniBase - q
    static let beam = 4          // 整句动态规划：每个位置留几条「最后一个词不同」的最优路径
    static let perKey = 4        // 每段拼音最多试几个候选词

    // 整句纠错：词格里给每段拼音加「改一处就成词」的边（和 Python 版 typo_edges 一致，说明见那边）。罚分按错法分（1/2048 纳特）
    static let penSub = Int(7.0 * 2048), penTrans = Int(6.0 * 2048), penExtra = Int(10.0 * 2048), penMiss = Int(6.0 * 2048), penGH = Int(6.0 * 2048)
    static let typoMin = 2, typoMax = 14
    // 另一路整句比最好的贵不超过这么多，才当第二个候选给出来：最好的改过 → 原样那句宽一点（退路）；最好的没改 → 纠正句要很接近才给
    static let altRawMargin = Int(8.0 * 2048), altFixMargin = Int(3.0 * 2048)

    private let dict: PinyinDict
    let lm: LMDict?
    /// 个人学习（nil = 不用）：整句选词按用过的次数打折，自造词进词格，整词按用过的往前挪
    var user: UserModel?
    private var lmIDs: [Int: Int] = [:]      // 词条序号 → 语言模型里的词 id（-1 = 不在模型里）

    init(dict: PinyinDict, lm: LMDict? = nil) {
        self.dict = dict
        self.lm = lm
    }

    private func lmID(_ e: Int) -> Int {
        guard let lm else { return -1 }
        if let v = lmIDs[e] { return v }
        let v = lm.id(of: dict.word(e))
        lmIDs[e] = v
        return v
    }

    /// 上一个词 last（语言模型的词 id，-1 = 没有上文）后面接词 lid 的代价；uni = 它的一元代价
    private func stepCost(_ last: Int, _ lid: Int, _ uni: Int) -> Int {
        guard let lm, last >= 0 else { return uni }
        if lid >= 0, let c = lm.pair(last, lid) { return c }
        return uni + lm.backoff(last)      // 没见过的词对（含不在模型里的词）：一元代价 + 回退代价
    }

    /// 上文最后一个词之后最可能接的词 / 标点
    func predict(after ctx: String, limit: Int = 12) -> [String] {
        guard let lm, !ctx.isEmpty else { return [] }
        let a = lm.id(of: ctx)
        return a >= 0 ? lm.followers(a, limit: limit) : []
    }

    /// 词典里有没有这个键 + 词（个人学习：有的就不用再记成自造词）
    func hasWord(_ key: [UInt8], _ word: String) -> Bool {
        key.withUnsafeBufferPointer { dict.exact($0.baseAddress!, key.count) }.contains { dict.word($0) == word }
    }

    /// 语言模型里有没有这个词（上文是不是个词）
    func knows(_ w: String) -> Bool { (lm?.id(of: w) ?? -1) >= 0 }

    private struct State {
        var cost: Int
        var last: Int
        var path: [Int]      // 词条序号、字母数 交替排（和 Python 的 ((e, n), …) 逐项对应，用来在代价相同时定先后）
        var fix = false      // 这条路改过拼音（走过纠错的边）
    }

    private func lexLess(_ a: [Int], _ b: [Int]) -> Bool {
        for k in 0..<min(a.count, b.count) where a[k] != b[k] { return a[k] < b[k] }
        return a.count < b.count
    }

    /// 同一路（改没改过拼音）里同一个「最后一个词」只留代价最小的（代价相同留路径小的），每路再留最好的 beam 条，合起来按（代价, 路径）排
    private func prune(_ states: [State]) -> [State] {
        var best: [Int: State] = [:]
        for st in states {
            let k = st.last &* 2 &+ (st.fix ? 1 : 0)
            if let cur = best[k], !(st.cost < cur.cost || (st.cost == cur.cost && lexLess(st.path, cur.path))) { continue }
            best[k] = st
        }
        func less(_ a: State, _ b: State) -> Bool { a.cost != b.cost ? a.cost < b.cost : lexLess(a.path, b.path) }
        var out: [State] = []
        for f in [false, true] { out += best.values.filter { $0.fix == f }.sorted(by: less).prefix(Self.beam) }
        return out.sorted(by: less)
    }

    // MARK: 整句纠错的边

    /// [lo, hi) 里的键都以同一个长 depth 的前缀开头：按下一个字母分组，[(字母, 起, 止)]
    private func children(_ lo: Int, _ hi: Int, _ depth: Int) -> [(UInt8, Int, Int)] {
        var out: [(UInt8, Int, Int)] = []
        var x = lo
        while x < hi, dict.keyLength(x) == depth { x += 1 }
        while x < hi {
            var k = Array(dict.key(x).prefix(depth + 1))
            let ch = k[depth]
            k.append(0xFF)
            let z = dict.lowerBound(k, from: x, to: hi)
            out.append((ch, x, z))
            x = z
        }
        return out
    }

    private func narrow(_ lo: Int, _ hi: Int, _ key: [UInt8]) -> (Int, Int) {
        let a = dict.lowerBound(key, from: lo, to: hi)
        return (a, dict.lowerBound(key + [0xFF], from: a, to: hi))
    }

    private struct TypoKey: Hashable { let p: Int; let key: [UInt8] }

    /// 从 b[i] 起（不越过 end）改一处能成词典键的段：按（吃掉几个字母, 词典键）排好的（吃掉几个字母, 词典键, 罚分），
    /// 不含和原样相同的；同一段同一个键有几种改法的取罚分最小的
    private func typoEdges(_ b: [UInt8], _ i: Int, _ end: Int) -> [(Int, [UInt8], Int)] {
        var out: [TypoKey: Int] = [:]
        func emit(_ p: Int, _ lo: Int, _ hi: Int, _ depth: Int, _ pen: Int) {
            guard p >= Self.typoMin, p <= Self.typoMax, lo < hi, dict.keyLength(lo) == depth else { return }
            let k = dict.key(lo)
            if k.elementsEqual(b[i..<(i + p)]) { return }
            let t = TypoKey(p: p, key: k)
            if let cur = out[t], cur <= pen { return }
            out[t] = pen
        }
        func follow(_ lo: Int, _ hi: Int, _ depth: Int, _ p: Int, _ canEmit: Bool, _ pen: Int) {     // 已经改过一处：后面只能原样对上
            if canEmit { emit(p, lo, hi, depth, pen) }
            if p >= Self.typoMax || i + p >= end || lo >= hi { return }
            let (a, z) = narrow(lo, hi, Array(dict.key(lo).prefix(depth)) + [b[i + p]])
            if a < z { follow(a, z, depth + 1, p + 1, true, pen) }
        }
        func walk(_ lo: Int, _ hi: Int, _ depth: Int, _ p: Int) {     // 还没改过：键的前 depth 个字母 = b[i..<i+p]
            if i + p < end { follow(lo, hi, depth, p + 1, true, Self.penExtra) }          // 多打了 b[i+p]
            let nxt = i + p < end ? Int(b[i + p]) : -1
            for (ch, a, z) in children(lo, hi, depth) {
                if Int(ch) == nxt {
                    if p + 1 <= Self.typoMax { walk(a, z, depth + 1, p + 1) }
                } else if nxt >= 97, nxt <= 122, ch >= 97, ch <= 122, Self.nearTable[(nxt - 97) * 26 + Int(ch - 97)] {
                    follow(a, z, depth + 1, p + 1, true, Self.penSub)                      // 邻键替换
                }
                if nxt >= 0 { follow(a, z, depth + 1, p, false, Self.penMiss) }            // 漏打了 ch（后面至少还要对上一个）
                if ch == 103 || ch == 104 { emit(p, a, z, depth + 1, Self.penGH) }         // 段尾漏打 g / h
                if i + p + 1 < end, ch == b[i + p + 1], nxt != Int(ch) {                  // 相邻对调
                    let (a2, z2) = narrow(a, z, Array(dict.key(a).prefix(depth + 1)) + [UInt8(nxt)])
                    if a2 < z2 { follow(a2, z2, depth + 2, p + 2, true, Self.penTrans) }
                }
            }
        }
        walk(0, dict.count, 0, 0)
        return out.map { ($0.key.p, $0.key.key, $0.value) }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.lexicographicallyPrecedes($1.1) }
    }

    // MARK: 输入串处理

    private struct Split {
        var letters: [UInt8] = []
        var cuts: [Int] = []          // 分词符把字母串切开的位置（升序）
        var rawPos: [Int] = [0]       // rawPos[k] = 吃掉 k 个字母（连同紧跟的 '）后，原串里的位置
    }

    private func split(_ raw: String) -> Split {
        var s = Split()
        let c = Array(raw.utf8)
        var i = 0
        while i < c.count {
            if c[i] == 39 {                       // '
                if !s.letters.isEmpty, s.cuts.last != s.letters.count { s.cuts.append(s.letters.count) }
                i += 1
                continue
            }
            s.letters.append(c[i])
            i += 1
            while i < c.count, c[i] == 39 {
                if s.cuts.last != s.letters.count { s.cuts.append(s.letters.count) }
                i += 1
            }
            s.rawPos.append(i)
        }
        return s
    }

    /// 音节边界：贪心取最长音节，不越过分词符
    private func boundaries(_ b: [UInt8], _ cuts: [Int]) -> [Int] {
        let n = b.count
        var out: [Int] = []
        var i = 0
        while i < n {
            let limit = cuts.first(where: { $0 > i }) ?? n
            var hit = false
            var l = min(6, limit - i)
            while l >= 1 {
                if pinyinSyllables.contains(String(decoding: b[i..<(i + l)], as: UTF8.self)) {
                    i += l
                    out.append(i)
                    hit = true
                    break
                }
                l -= 1
            }
            if !hit { break }
        }
        return out
    }

    /// 键盘上方显示的拼音：音节之间空格，末尾还没成音节的字母原样跟着
    func display(_ raw: String) -> String {
        let s = split(raw)
        let bs = boundaries(s.letters, s.cuts)
        var parts: [String] = []
        var prev = 0
        for e in bs {
            parts.append(String(decoding: s.letters[prev..<e], as: UTF8.self))
            prev = e
        }
        if prev < s.letters.count { parts.append(String(decoding: s.letters[prev...], as: UTF8.self)) }
        return parts.joined(separator: " ")
    }

    // MARK: 词条查询

    private func exact(_ b: [UInt8], _ i: Int, _ j: Int) -> Range<Int> {
        b.withUnsafeBufferPointer { dict.exact($0.baseAddress! + i, j - i) }
    }

    /// key 能不能切成恰好 nchar 个合法音节，且每个分词符位置都是音节边界
    private func segOK(_ key: ArraySlice<UInt8>, _ nchar: Int, _ cutsRel: [Int]) -> Bool {
        let k = Array(key)
        var cur: Set<Int> = [0]
        for _ in 0..<nchar {
            var nxt = Set<Int>()
            for pos in cur {
                for l in 1...6 {
                    let e = pos + l
                    if e > k.count { break }
                    if !pinyinSyllables.contains(String(decoding: k[pos..<e], as: UTF8.self)) { continue }
                    if cutsRel.contains(where: { pos < $0 && $0 < e }) { continue }
                    nxt.insert(e)
                }
            }
            cur = nxt
            if cur.isEmpty { return false }
        }
        return cur.contains(k.count)
    }

    private func entryOK(_ e: Int, _ b: [UInt8], _ i: Int, _ j: Int, _ cuts: [Int]) -> Bool {
        let cr = cuts.filter { i < $0 && $0 < j }.map { $0 - i }
        if cr.isEmpty { return true }
        return segOK(b[i..<j], dict.word(e).count, cr)
    }

    private func okEntries(_ b: [UInt8], _ i: Int, _ j: Int, _ cuts: [Int]) -> [Int] {
        exact(b, i, j).filter { entryOK($0, b, i, j, cuts) }
    }

    /// 键以 b[..<j] 开头、更长，并且前 k 个音节恰好就是 b[..<j]（xi 后面接 an 不算：xian 是另一个音节）的词，按权重取前 cap 个
    private func prefixWords(_ b: [UInt8], _ j: Int, _ k: Int, _ cap: Int) -> [Int] {
        let r = b.withUnsafeBufferPointer { dict.prefix($0.baseAddress!, j) }
        var cand: [(Double, Int)] = []
        for i in r where dict.keyLength(i) > j { cand.append((dict.logWeight(i), i)) }
        cand.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        var out: [Int] = []
        for (_, i) in cand.prefix(400) {
            let key = dict.key(i)
            let wl = dict.word(i).count
            if wl > k, segOK(key[0..<j], k, []), segOK(key[j...], wl - k, []) {
                out.append(i)
                if out.count == cap { break }
            }
        }
        return out
    }

    // MARK: 纠错（打错键 / 漏打 / 多打 / 相邻两个字母对调 / 模糊音）
    // 把输入串和词典里每个键算一个带权的编辑距离（替换、插入、删除、相邻对调），代价小的排前面，再按词频折算。代价全是整数，和 Python 版逐字一致。

    static let fNear = 2, fFar = 4, fTrans = 2, fIndel = 3, fIndelSoft = 2
    static let fLambda = 2048           // 每个代价单位折合的词频（1/2048 纳特）
    static let weakQ = Int(9.5 * 2048)  // 整词里最常用的那个权重低于这个，就算「可能打错了」

    /// 邻键 = 手机键盘上挨着的键（半键错位）+ 常见模糊音（l/n、f/h、r/l）
    private static let nearTable: [Bool] = {
        let near: [Character: String] = [
            "a": "qswz", "b": "fghnv", "c": "dfvx", "d": "cefrsx", "e": "drsw", "f": "bcdghrtv", "g": "bfhtvy", "h": "bfgjnuy",
            "i": "jkou", "j": "hikmnu", "k": "ijlmo", "l": "knopr", "m": "jkn", "n": "bhjlm", "o": "iklp", "p": "lo",
            "q": "aw", "r": "deflt", "s": "adewxz", "t": "fgry", "u": "hijy", "v": "bcfg", "w": "aeqs", "x": "cdsz",
            "y": "ghtu", "z": "asx",
        ]
        var t = [Bool](repeating: false, count: 26 * 26)
        for (a, ns) in near {
            for c in ns.utf8 { t[Int(a.asciiValue! - 97) * 26 + Int(c - 97)] = true }
        }
        return t
    }()

    static func fBudget(_ n: Int) -> Int { n < 2 ? 0 : (n < 4 ? 2 : (n < 6 ? 4 : 6)) }

    /// 这个字母夹在 prev 后面，少打 / 多打了它也算模糊音（zh ch sh 的 h；an en in 后面的 g）
    @inline(__always) private static func fSoft(_ ch: UInt8, _ prev: UInt8) -> Bool {
        (ch == 104 && (prev == 122 || prev == 99 || prev == 115)) || (ch == 103 && prev == 110)
    }

    /// 纠错候选：（词条序号, 代价）按得分（权重整数 - 代价 * fLambda）从高到低，同一个词只留得分最高的那条。
    /// 结果和原来「拿带权编辑距离把整本词典每个键算一遍」逐条一致（2026-10-24 改写时对拍过；和 Python 版 fuzzy 一样）：编辑距离表按键的字母一列一列算，
    /// 按词典顺序走时同前缀的键共用前面的列；某个前缀往后连着两列都超了预算（所有路径必经其中一列），以它开头的键全部跳过。
    private func fuzzy(_ b: [UInt8], cap: Int) -> [(Int, Int)] {
        let n = b.count
        let bud = Self.fBudget(n)
        if bud == 0 { return [] }
        let win = min(2, bud / 2)
        let w = n + 1
        let maxT = n + win
        let cols = UnsafeMutablePointer<Int>.allocate(capacity: (maxT + 1) * w)     // 第 t 列 = cols[t*w ..< t*w+w]
        let rmin = UnsafeMutablePointer<Int>.allocate(capacity: (maxT + 1) * w)     // 每一行在前 t 列里的最小值
        var mins = [Int](repeating: 0, count: maxT + 1)                             // 第 t 列的最小值
        defer { cols.deallocate(); rmin.deallocate() }
        cols[0] = 0
        rmin[0] = 0
        for r in 1...n {
            cols[r] = cols[r - 1] + (r >= 2 && Self.fSoft(b[r - 1], b[r - 2]) ? Self.fIndelSoft : Self.fIndel)
            rmin[r] = cols[r]
        }
        var cur: [UInt8] = []          // cols 里算好的列对应的键前缀（cur.count 列之后的都作废）
        var hits: [(sc: Int, i: Int, c: Int)] = []
        var i = 0
        while i < dict.count {
            let (kp, kl) = dict.keyPtr(i)
            var l = 0
            let top = min(kl, cur.count)
            while l < top, kp[l] == cur[l] { l += 1 }
            cur.removeLast(cur.count - l)
            var cut = 0
            var t = l + 1
            while t <= kl {
                if t > maxT { cut = t; break }
                let c1 = (t - 1) * w, c2 = (t - 2) * w, co = t * w
                let kc = kp[t - 1]
                let kv: UInt8 = t >= 2 ? kp[t - 2] : 0
                let ins = t >= 2 && Self.fSoft(kc, kv) ? Self.fIndelSoft : Self.fIndel
                cols[co] = cols[c1] + ins
                rmin[co] = min(rmin[c1], cols[co])
                var mn = cols[co]
                for r in 1...n {
                    let ar = b[r - 1]
                    var best = cols[c1 + r - 1]
                    if ar != kc {
                        best += (ar >= 97 && ar <= 122 && kc >= 97 && kc <= 122 && Self.nearTable[Int(ar - 97) * 26 + Int(kc - 97)]) ? Self.fNear : Self.fFar
                    }
                    var v = cols[co + r - 1] + (r >= 2 && Self.fSoft(ar, b[r - 2]) ? Self.fIndelSoft : Self.fIndel)
                    if v < best { best = v }
                    v = cols[c1 + r] + ins
                    if v < best { best = v }
                    if r >= 2, t >= 2, ar == kv, b[r - 2] == kc {
                        v = cols[c2 + r - 2] + Self.fTrans
                        if v < best { best = v }
                    }
                    cols[co + r] = best
                    rmin[co + r] = min(rmin[c1 + r], best)
                    if best < mn { mn = best }
                }
                mins[t] = mn
                cur.append(kc)
                if mn > bud, mins[t - 1] > bud { cut = t; break }
                t += 1
            }
            if cut > 0 {
                var k = Array(UnsafeBufferPointer(start: kp, count: cut))
                k.append(0xFF)
                i = dict.lowerBound(k, from: i + 1, to: dict.count)
                continue
            }
            if kl >= n - win {
                let c = cols[kl * w + n]
                if c <= bud, c != 0, (1...n).allSatisfy({ rmin[kl * w + $0] <= bud }) {
                    hits.append((dict.rawWeight(i) - c * Self.fLambda, i, c))
                }
            }
            i += 1
        }
        hits.sort { $0.sc != $1.sc ? $0.sc > $1.sc : $0.i < $1.i }
        var seen = Set<String>()
        var out: [(Int, Int)] = []
        for h in hits {
            if seen.insert(dict.word(h.i)).inserted {
                out.append((h.i, h.c))
                if out.count == cap { break }
            }
        }
        return out
    }

    // MARK: 九键（2 abc 3 def 4 ghi 5 jkl 6 mno 7 pqrs 8 tuv 9 wxyz）
    // 输入串里：数字 2~9 = 这个键上的任意一个字母；小写字母 = 已经选定的音节（点左边的音节列表选的）；' = 分词。
    // 扫整本词典，键的每一位对得上就算命中，按词频排。和 Python 版（t9_scan / t9_candidates / t9_syllables）逐字一致。

    private static let t9Digit: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 256)
        for (d, ls) in [(UInt8(50), "abc"), (51, "def"), (52, "ghi"), (53, "jkl"), (54, "mno"), (55, "pqrs"), (56, "tuv"), (57, "wxyz")] {
            for c in ls.utf8 { t[Int(c)] = d }
        }
        return t
    }()

    private static let t9Letters: [[UInt8]] = {
        var t = [[UInt8]](repeating: [], count: 256)
        for (d, ls) in [(50, "abc"), (51, "def"), (52, "ghi"), (53, "jkl"), (54, "mno"), (55, "pqrs"), (56, "tuv"), (57, "wxyz")] { t[d] = Array(ls.utf8) }
        return t
    }()

    /// 键和 b[0..<m] 逐位对得上的词条序号（升序）。prefix = false：长度相等；true：键比它更长（联想）。
    /// 按位在有序词典里收窄区间（数字 = 这个键上的几个字母挨个试，字母 = 只试它），不扫全词典（和 Python 版 t9_scan 一致）
    private func t9Scan(_ b: [UInt8], _ m: Int, prefix: Bool) -> [Int] {
        var out: [Int] = []
        var key: [UInt8] = []
        func walk(_ x: Int, _ lo: Int, _ hi: Int) {
            if lo >= hi { return }
            if x == m {
                var e = lo          // 键正好等于 key 的排在区间最前面
                while e < hi, dict.keyLength(e) == m { e += 1 }
                out.append(contentsOf: prefix ? e..<hi : lo..<e)
                return
            }
            let c = b[x]
            for ch in c >= 97 ? [c] : Self.t9Letters[Int(c)] {
                key.append(ch)
                let a = dict.lowerBound(key, from: lo, to: hi)
                key.append(0xFF)
                let z = dict.lowerBound(key, from: a, to: hi)
                key.removeLast()
                walk(x + 1, a, z)
                key.removeLast()
            }
        }
        walk(0, 0, dict.count)
        return out
    }

    /// b[..<j] 整个对上一个词的键（分词符位置要是音节边界），按（权重大 → 小，序号小 → 大）
    private func t9Whole(_ b: [UInt8], _ j: Int, _ cuts: [Int]) -> [Int] {
        t9Scan(b, j, prefix: false)
            .filter { cuts.isEmpty || entryOK($0, dict.key($0), 0, j, cuts) }
            .sorted { dict.rawWeight($0) != dict.rawWeight($1) ? dict.rawWeight($0) > dict.rawWeight($1) : $0 < $1 }
    }

    static let t9PerKey = 8        // 九键每段最多试几个候选词（同一串数字能拼出好几个音节，4 个不够）

    /// 从 b[i] 起（不越过 lim）所有对得上词典键的段：[(j, [词条序号…])]，j 升序；每段按（权重大 → 小，序号小 → 大）留 t9PerKey 个。
    /// 一次沿词典走完所有长度（走到词典里没有这个开头的键就停），不用每个长度各扫一遍（和 Python 版 t9_edges 一致）
    private func t9Edges(_ b: [UInt8], _ i: Int, _ lim: Int, _ cuts: [Int]) -> [(Int, [Int])] {
        var hit: [Int: [Int]] = [:]
        var key: [UInt8] = []
        func walk(_ x: Int, _ lo: Int, _ hi: Int) {
            if lo >= hi { return }
            if x > 0 {
                var e = lo          // 键正好等于 key 的排在区间最前面
                while e < hi, dict.keyLength(e) == x { e += 1 }
                if e > lo { hit[i + x, default: []].append(contentsOf: lo..<e) }
            }
            if i + x >= lim || x >= Self.maxKey { return }
            let c = b[i + x]
            for ch in c >= 97 ? [c] : Self.t9Letters[Int(c)] {
                key.append(ch)
                let a = dict.lowerBound(key, from: lo, to: hi)
                key.append(0xFF)
                let z = dict.lowerBound(key, from: a, to: hi)
                key.removeLast()
                walk(x + 1, a, z)
                key.removeLast()
            }
        }
        walk(0, 0, dict.count)
        let inner = cuts.map { $0 - i }
        var out: [(Int, [Int])] = []
        for j in hit.keys.sorted() {
            let es = hit[j]!.filter { entryOK($0, dict.key($0), 0, j - i, inner) }
                .sorted { dict.rawWeight($0) != dict.rawWeight($1) ? dict.rawWeight($0) > dict.rawWeight($1) : $0 < $1 }
            if !es.isEmpty { out.append((j, Array(es.prefix(Self.t9PerKey)))) }
        }
        return out
    }

    /// 九键的整句动态规划（和 26 键同一套代价：词频 + 二元语法）：beams[j] = 盖住 b[0..<j] 的几条最优路径。不纠错、不用个人学习
    private func t9Beams(_ b: [UInt8], _ cuts: [Int], _ ctxID: Int) -> [[State]] {
        let n = b.count
        var beams = [[State]](repeating: [], count: n + 1)
        beams[0] = [State(cost: 0, last: ctxID, path: [])]
        for i in 0..<n {
            if i > 0 { beams[i] = prune(beams[i]) }
            if beams[i].isEmpty { continue }
            let lim = cuts.first(where: { $0 > i }) ?? n
            for (j, es) in t9Edges(b, i, lim, cuts) {
                for e in es {
                    let uni = Self.uniBase - dict.rawWeight(e)
                    let lid = lmID(e)
                    let key = lid >= 0 ? lid : -(e + 1)
                    for st in beams[i] {
                        beams[j].append(State(cost: st.cost + stepCost(st.last, lid, uni), last: key, path: st.path + [e, j - i], fix: false))
                    }
                }
            }
        }
        beams[n] = prune(beams[n])
        return beams
    }

    /// key = 这个候选对应的拼音（顶栏显示「ni hao」用）；整句是各词的拼音拼起来
    func t9Candidates(_ raw: String, limit: Int = 40, expanded: Bool = false, ctx: String? = nil) -> [PinyinCandidate] {
        let s = split(raw)
        let b = s.letters
        let n = b.count
        if n == 0 { return [] }
        let ctxID = (lm != nil && ctx != nil && !ctx!.isEmpty) ? lm!.id(of: ctx!) : -1
        let beams = t9Beams(b, s.cuts, ctxID)
        var out: [PinyinCandidate] = []
        var seen = Set<String>()
        func push(_ text: String, _ consume: Int, _ kind: PinyinKind, _ key: [UInt8] = [], _ parts: [String] = []) {
            if seen.insert(text).inserted {
                out.append(PinyinCandidate(text: text, consume: s.rawPos[consume], kind: kind, key: String(decoding: key, as: UTF8.self), parts: parts.isEmpty ? [text] : parts))
            }
        }
        func pushEntry(_ i: Int, _ consume: Int, _ kind: PinyinKind) { push(dict.word(i), consume, kind, dict.key(i)) }
        /// 盖住 b[..<j] 的第 k 好的整句；不足两个词的不算句子
        func sentence(_ j: Int, _ k: Int = 0) -> (text: String, key: [UInt8], parts: [String])? {
            guard beams[j].count > k, beams[j][k].path.count >= 4 else { return nil }
            let es = stride(from: 0, to: beams[j][k].path.count, by: 2).map { beams[j][k].path[$0] }
            return (es.map { dict.word($0) }.joined(), es.flatMap { dict.key($0) }, es.map { dict.word($0) })
        }
        let full = t9Whole(b, n, s.cuts)
        for i in full.prefix(8) { pushEntry(i, n, .full) }
        for k in 0..<2 {          // 九键歧义多，整句给最好的两条（第二条是退路）
            if let t = sentence(n, k) { push(t.text, n, .sentence, t.key, t.parts) }
        }
        var assoc: [Int] = []
        if s.cuts.isEmpty {
            assoc = t9Scan(b, n, prefix: true).sorted { dict.rawWeight($0) != dict.rawWeight($1) ? dict.rawWeight($0) > dict.rawWeight($1) : $0 < $1 }
        }
        for i in assoc.prefix(3) { pushEntry(i, n, .assoc) }
        var hit: [(Int, [Int])] = []          // 前缀：b[..<j] 整个能成词的最长三处（只试最后 14 个位置）
        var j = n - 1
        while j > max(0, n - 15) {
            let es = t9Whole(b, j, s.cuts)
            if !es.isEmpty {
                hit.append((j, es))
                if hit.count == 3 { break }
            }
            j -= 1
        }
        for (j, es) in hit {
            if let t = sentence(j) { push(t.text, j, .prefixSentence, t.key, t.parts) }
            for i in es.prefix(3) { pushEntry(i, j, .prefix) }
        }
        for i in assoc.dropFirst(3).prefix(3) { pushEntry(i, n, .assoc) }
        if out.isEmpty { push(String(decoding: b, as: UTF8.self), n, .raw) }
        if expanded {
            for i in full { pushEntry(i, n, .full) }
            for i in assoc.prefix(40) { pushEntry(i, n, .assoc) }
            for (j, es) in hit { for i in es.prefix(40) { pushEntry(i, j, .prefix) } }
        }
        return Array(out.prefix(limit))
    }

    /// 点左边列表选音节：下一个还没选的数字串（前面选好的字母不算）开头能拼出哪些音节，常用的在前。start = 这串数字在原串里的起点
    func t9Syllables(_ raw: String, limit: Int = 12) -> (opts: [String], start: Int) {
        let s = split(raw)
        let b = s.letters
        let n = b.count
        var p = 0
        while p < n, b[p] >= 97 { p += 1 }
        if p >= n { return ([], 0) }
        let end = s.cuts.first(where: { $0 > p }) ?? n
        var opts: [(Int, String)] = []
        for syl in pinyinSyllables {
            let u = Array(syl.utf8)
            if u.count <= end - p, (0..<u.count).allSatisfy({ Self.t9Digit[Int(u[$0])] == b[p + $0] }) {
                let r = u.withUnsafeBufferPointer { dict.exact($0.baseAddress!, u.count) }
                opts.append((-(r.isEmpty ? 0 : dict.rawWeight(r.lowerBound)), syl))
            }
        }
        opts.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return (opts.prefix(limit).map { $0.1 }, s.rawPos[p])
    }

    // MARK: 候选

    func candidates(_ raw: String, limit: Int = 40, expanded: Bool = false, ctx: String? = nil) -> [PinyinCandidate] {
        let s = split(raw)
        let b = s.letters
        let n = b.count
        if n == 0 { return [] }
        let ctxID = (lm != nil && ctx != nil && !ctx!.isEmpty) ? lm!.id(of: ctx!) : -1
        let ctxw = (ctx?.isEmpty ?? true) ? nil : ctx
        let u = user
        let pl = u?.plist ?? []
        let nd = dict.count
        // 词条：< nd 是词典里的，≥ nd 是自造词（pl 的下标 + nd）
        func wordOf(_ e: Int) -> String { e < nd ? dict.word(e) : pl[e - nd].word }
        func keyOf(_ e: Int) -> [UInt8] { e < nd ? dict.key(e) : pl[e - nd].key }

        // 整句动态规划（带二元语法）：beams[j] = 盖住 b[0..<j] 的几条最优路径
        var beams = [[State]](repeating: [], count: n + 1)
        beams[0] = [State(cost: 0, last: ctxID, path: [])]
        func extend(_ i: Int, _ j: Int, _ es: [Int], _ pen: Int) {
            for e in es {
                let uni = Self.uniBase - (e < nd ? dict.rawWeight(e) : UserModel.phraseQ)
                let lid = e < nd ? lmID(e) : (lm?.id(of: pl[e - nd].word) ?? -1)
                let key = lid >= 0 ? lid : -(e + 1)
                let w = u == nil ? "" : wordOf(e)
                for st in beams[i] {
                    var step = stepCost(st.last, lid, uni)
                    if let u { step = max(0, step - u.bonus(st.path.isEmpty ? ctxw : wordOf(st.path[st.path.count - 2]), w)) }
                    beams[j].append(State(cost: st.cost + step + pen, last: key, path: st.path + [e, j - i], fix: st.fix || pen > 0))
                }
            }
        }
        for i in 0..<n {
            if i > 0 { beams[i] = prune(beams[i]) }
            if beams[i].isEmpty { continue }
            let lim = s.cuts.first(where: { $0 > i }) ?? n
            var j = i + 1
            let jmax = min(lim, i + Self.maxKey)
            while j <= jmax {
                let r = exact(b, i, j)
                if !r.isEmpty {
                    var es: [Int] = []
                    for x in r where entryOK(x, b, i, j, s.cuts) {
                        es.append(x)
                        if es.count == Self.perKey { break }
                    }
                    extend(i, j, es, 0)
                }
                if let u, u.hasPhrases {
                    let ph = u.phrases(Array(b[i..<j]))
                    if !ph.isEmpty { extend(i, j, ph.map { nd + $0 }, 0) }
                }
                j += 1
            }
            for (p, k, pen) in typoEdges(b, i, lim) {
                let r = k.withUnsafeBufferPointer { dict.exact($0.baseAddress!, k.count) }
                extend(i, i + p, Array(r.prefix(Self.perKey)), pen)
            }
        }
        beams[n] = prune(beams[n])
        /// 纠正后的拼音：路径上每个词条的键拼起来；和原样一样就是空串
        func fixed(_ path: [Int], _ j: Int) -> String {
            var k: [UInt8] = []
            for x in stride(from: 0, to: path.count, by: 2) { k += keyOf(path[x]) }
            return k.elementsEqual(b[0..<j]) ? "" : String(decoding: k, as: UTF8.self)
        }
        /// （整句, 纠正后的拼音, 切词）；st 不给就用这一位置最好的那条；不足两个词的不算句子
        func sentence(_ j: Int, _ st: State? = nil) -> (text: String, fix: String, parts: [String])? {
            guard let st = st ?? beams[j].first, st.path.count >= 4 else { return nil }
            let ws = stride(from: 0, to: st.path.count, by: 2).map { wordOf(st.path[$0]) }
            return (ws.joined(), fixed(st.path, j), ws)
        }

        var out: [PinyinCandidate] = []
        var seen = Set<String>()
        func push(_ text: String, _ consume: Int, _ kind: PinyinKind, _ fix: String = "", _ parts: [String] = []) {
            if seen.insert(text).inserted { out.append(PinyinCandidate(text: text, consume: s.rawPos[consume], kind: kind, fix: fix, parts: parts.isEmpty ? [text] : parts)) }
        }
        func fixKey(_ i: Int) -> String { String(decoding: dict.key(i), as: UTF8.self) }

        // 1. 整串刚好是一个词
        var full = okEntries(b, 0, n, s.cuts)
        if lm != nil, ctxID >= 0, full.count > 1 {      // 有上文：整词按「接在上文后面」的代价重排（代价相同保持原顺序）
            full = full.enumerated().map { (k, e) in (stepCost(ctxID, lmID(e), Self.uniBase - dict.rawWeight(e)), k, e) }
                .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
        }
        if let u, !full.isEmpty, full.contains(where: { u.bonus(ctxw, dict.word($0)) > 0 }) {     // 用过的词往前挪（打折后代价相同保持原顺序）
            full = full.enumerated().map { (k, e) -> (Int, Int, Int) in
                let uni = Self.uniBase - dict.rawWeight(e)
                let base = lm != nil && ctxID >= 0 ? stepCost(ctxID, lmID(e), uni) : uni
                return (base - u.bonus(ctxw, dict.word(e)), k, e)
            }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map { $0.2 }
        }
        // 自造词：键正好是整个输入串的，排在最前面（用得多的在前）
        let mine: [String] = (u == nil || !s.cuts.isEmpty) ? [] : u!.phrases(b).sorted {
            let a = u!.count(of: pl[$0]), c = u!.count(of: pl[$1])
            return a != c ? a > c : $0 < $1
        }.map { pl[$0].word }
        let top = full.isEmpty ? 0 : full.map { dict.logWeight($0) }.max()!
        let whole = sentence(n)
        // 纠错：输入串不是任何词（也不是任何词的开头、连不成句）= 多半打错了，纠错候选排最前；
        // 是个词但很冷僻（zhidan 制单、haide 害的）= 可能打错，纠错候选插在前两个整词后面；展开面板里总是补在最后
        let typo = full.isEmpty && mine.isEmpty && whole == nil && b.withUnsafeBufferPointer({ dict.prefix($0.baseAddress!, n) }).isEmpty
        let weak = !full.isEmpty && full.map { dict.rawWeight($0) }.max()! < Self.weakQ
        var fz: [(Int, Int)] = []
        if s.cuts.isEmpty, (n >= 3 && (typo || weak)) || (expanded && n >= 2) {
            fz = fuzzy(b, cap: expanded ? 30 : 4)
        }
        if typo { for (i, _) in fz.prefix(4) { push(dict.word(i), n, .fuzzy, fixKey(i)) } }
        for w in mine { push(w, n, .user) }
        let pick = full.prefix(8).enumerated().filter { $0.offset < 3 || dict.logWeight($0.element) >= top - 4.5 }.map { $0.element }
        for i in (weak ? Array(pick.prefix(2)) : pick) { push(dict.word(i), n, .full) }
        if weak {
            for (i, _) in fz.prefix(3) { push(dict.word(i), n, .fuzzy, fixKey(i)) }
            for i in pick.dropFirst(2) { push(dict.word(i), n, .full) }
        }
        // 2. 整句；另一路（改过拼音 ↔ 没改过）的最好整句紧跟在后面：纠错改错了点它就回到原样，没敢改的点它就是纠正后的
        if let t = whole {
            push(t.text, n, .sentence, t.fix, t.parts)
            if let top = beams[n].first, let alt = beams[n].first(where: { $0.fix != top.fix }), alt.cost - top.cost <= (top.fix ? Self.altRawMargin : Self.altFixMargin),
               let a = sentence(n, alt) {
                push(a.text, n, .sentence, a.fix, a.parts)
            }
        }
        // 3. 联想：键以输入开头的更长的词，取权重最高的 6 个（展开时 40 个）
        func assocTop(_ cap: Int) -> [Int] {
            var top: [(Double, Int)] = []       // 按（权重大 → 小，序号小 → 大）保持有序，最多 cap 个
            let r = b.withUnsafeBufferPointer { dict.prefix($0.baseAddress!, n) }
            for i in r where dict.keyLength(i) > n {
                let q = dict.logWeight(i)
                if top.count == cap, let last = top.last, q <= last.0 { continue }
                var pos = top.count
                while pos > 0, top[pos - 1].0 < q { pos -= 1 }
                top.insert((q, i), at: pos)
                if top.count > cap { top.removeLast() }
            }
            return top.map { $0.1 }
        }
        let assoc = s.cuts.isEmpty ? assocTop(expanded ? 40 : 6) : []
        for i in assoc.prefix(3) { push(dict.word(i), n, .assoc) }     // 联想先给 3 个，后面接上「首字 / 前几个字」，其余的联想排在它们后面
        // 4. 前缀：只在音节边界 / 分词符处切，最多三处，从长到短
        var bs = boundaries(b, s.cuts).filter { $0 < n }
        for c in s.cuts where c < n && !bs.contains(c) { bs.append(c) }
        for j in bs.sorted(by: >).prefix(3) {
            if beams[j].isEmpty { continue }
            if let t = sentence(j) { push(t.text, j, .prefixSentence, t.fix, t.parts) }
            for i in okEntries(b, 0, j, s.cuts).prefix(3) { push(dict.word(i), j, .prefix) }
        }
        for i in assoc.dropFirst(3).prefix(3) { push(dict.word(i), n, .assoc) }
        // 5. 简拼
        if n >= 2, n <= 6, s.cuts.isEmpty {
            for idx in b.withUnsafeBufferPointer({ dict.initials($0.baseAddress!, n, limit: 10) }) { push(dict.word(idx), n, .initials) }
        }
        // 6. 什么都没有：把字母原样给出
        if out.isEmpty { push(String(decoding: b, as: UTF8.self), n, .raw) }
        // 7. 展开（候选栏的向下箭头）：前面的顺序不变，后面补上其余的
        if expanded {
            for i in full { push(dict.word(i), n, .full) }
            for i in assoc { push(dict.word(i), n, .assoc) }
            // 最长的三处、再加首字：每处先给最常用的 12 个同音词，接着是以它开头的联想词，同音的冷僻字放到最后
            let sb = s.cuts.isEmpty ? boundaries(b, s.cuts).filter { $0 < n } : []
            var order = Array(bs.sorted(by: >).prefix(3))
            if let f = sb.first, !order.contains(f) { order.append(f) }
            var rest: [(Int, Int)] = []
            for j in order where !beams[j].isEmpty {
                let ex = okEntries(b, 0, j, s.cuts).prefix(60)
                for i in ex.prefix(12) { push(dict.word(i), j, .prefix) }
                rest += ex.dropFirst(12).map { ($0, j) }
                if let k = sb.firstIndex(of: j) {
                    for i in prefixWords(b, j, k + 1, 12) { push(dict.word(i), j, .assoc) }
                }
            }
            for (i, j) in rest { push(dict.word(i), j, .prefix) }
            if n >= 2, n <= 6, s.cuts.isEmpty {
                for idx in b.withUnsafeBufferPointer({ dict.initials($0.baseAddress!, n, limit: 40) }) { push(dict.word(idx), n, .initials) }
            }
            for (i, _) in fz { push(dict.word(i), n, .fuzzy, fixKey(i)) }
        }
        return Array(out.prefix(limit))
    }
}
