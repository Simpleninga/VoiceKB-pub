import Foundation

/// 二元语言模型（内存映射，格式见 tools/lm/export_lm.py）：词 a 后面紧跟词 b 的代价。代价全是整数（1/2048 纳特）。
/// 没有这个文件键盘照常用（只是整句选词不看上下文、没有联想预测）。
final class LMDict {
    private let base: UnsafeRawPointer
    private let size: Int
    let count: Int
    private let offWord: Int, offBlob: Int, offBack: Int, offRange: Int, offB: Int, offCost: Int
    private(set) var unk = -1
    private(set) var bos = -1

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
        guard u32(0) == 0x3144_4D4C else { munmap(p, len); return nil }      // "LMD1"
        base = b
        size = len
        count = u32(4)
        offWord = u32(12)
        offBlob = u32(16)
        offBack = u32(20)
        offRange = u32(24)
        offB = u32(28)
        offCost = u32(32)
        unk = id(of: "<unk>")
        bos = id(of: "<s>")
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    @inline(__always) private func u32(_ o: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }

    private func wordBytes(_ i: Int) -> (UnsafePointer<UInt8>, Int) {
        let a = u32(offWord + 4 * i), b = u32(offWord + 4 * (i + 1))
        return ((base + offBlob + a).assumingMemoryBound(to: UInt8.self), b - a)
    }

    func word(_ i: Int) -> String {
        let (p, l) = wordBytes(i)
        return String(decoding: UnsafeBufferPointer(start: p, count: l), as: UTF8.self)
    }

    /// 词 → id（按 UTF-8 字节序二分），没有返回 -1
    func id(of w: String) -> Int {
        let k = Array(w.utf8)
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            let (p, l) = wordBytes(mid)
            let r = k.withUnsafeBufferPointer { kp -> Int in
                let m = memcmp(p, kp.baseAddress!, min(l, k.count))
                return m != 0 ? Int(m) : l - k.count
            }
            if r < 0 { lo = mid + 1 } else { hi = mid }
        }
        if lo < count {
            let (p, l) = wordBytes(lo)
            if l == k.count, k.withUnsafeBufferPointer({ memcmp(p, $0.baseAddress!, l) }) == 0 { return lo }
        }
        return -1
    }

    /// 没见过的词对的额外代价
    func backoff(_ a: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: offBack + 2 * a, as: UInt16.self)) }

    @inline(__always) private func range(_ a: Int) -> (Int, Int) { (u32(offRange + 4 * a), u32(offRange + 4 * (a + 1))) }
    @inline(__always) private func follower(_ i: Int) -> Int { u32(offB + 4 * i) }
    @inline(__always) private func cost(_ i: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: offCost + 2 * i, as: UInt16.self)) }

    /// a 后面紧跟 b 的代价（词对没出现过返回 nil）
    func pair(_ a: Int, _ b: Int) -> Int? {
        var (lo, hi) = range(a)
        let end = hi
        while lo < hi {
            let mid = (lo + hi) / 2
            if follower(mid) < b { lo = mid + 1 } else { hi = mid }
        }
        return lo < end && follower(lo) == b ? cost(lo) : nil
    }

    /// a 后面最可能接的词 / 标点（代价小的在前，不含 <unk> / <s>）
    func followers(_ a: Int, limit: Int) -> [String] {
        let (lo, hi) = range(a)
        var top: [(Int, Int)] = []        // （代价, 词 id），按（代价, id）升序，最多 limit 个
        for i in lo..<hi {
            let b = follower(i)
            if b == unk || b == bos { continue }
            let c = cost(i)
            if top.count == limit, let last = top.last, (c, b) >= (last.0, last.1) { continue }
            var pos = top.count
            while pos > 0, (top[pos - 1].0, top[pos - 1].1) > (c, b) { pos -= 1 }
            top.insert((c, b), at: pos)
            if top.count > limit { top.removeLast() }
        }
        return top.map { word($0.1) }
    }
}
