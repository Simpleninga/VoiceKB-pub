import Foundation

/// 英文联想：词表（tools/build_en.py 生成，按词频从高到低）按首字母分桶，打一个字母查一次，桶里顺着找前缀。
final class EnglishWords {
    private var buckets: [UInt8: [String]] = [:]

    init?(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for w in text.split(separator: "\n") where !w.isEmpty {
            buckets[w.utf8.first!, default: []].append(String(w))
        }
        if buckets.isEmpty { return nil }
    }

    /// 以 prefix（不分大小写）开头、比它长的词，词频高的在前，最多 limit 个；结果的大小写跟着输入走（Tak → Take，TAK → TAKE）
    func complete(_ prefix: String, limit: Int) -> [String] {
        let p = prefix.lowercased()
        guard let first = p.utf8.first, let list = buckets[first] else { return [] }
        let upperAll = prefix.count > 1 && prefix == prefix.uppercased()
        let capFirst = prefix.first.map { String($0) == String($0).uppercased() && String($0) != String($0).lowercased() } ?? false
        var out: [String] = []
        for w in list where w.count > p.count && w.hasPrefix(p) {
            out.append(upperAll ? w.uppercased() : (capFirst ? w.prefix(1).uppercased() + w.dropFirst() : w))
            if out.count >= limit { break }
        }
        return out
    }

    /// 中文拼音输入时，打的字母本身是个常见英文词 / 缩写（wifi、ok、ppt…）就返回要给的英文候选（缩写给大写写法）；不是就 nil。
    /// 三个字母以下的普通词不管（an、me、he 同时是拼音，别抢）；只收缩写白名单
    private static let known: [String: String] = [
        "wifi": "WiFi", "ok": "OK", "ppt": "PPT", "pdf": "PDF", "vip": "VIP", "id": "ID", "ip": "IP", "qq": "QQ", "ai": "AI", "pc": "PC",
        "usb": "USB", "gps": "GPS", "cpu": "CPU", "vpn": "VPN", "iphone": "iPhone", "ipad": "iPad", "ios": "iOS", "api": "API", "gpt": "GPT",
        "ktv": "KTV", "atm": "ATM", "app": "App", "excel": "Excel", "word": "Word", "wechat": "WeChat", "mac": "Mac", "tiktok": "TikTok",
        "pdca": "PDCA", "hr": "HR", "ceo": "CEO", "ui": "UI", "ux": "UX", "bug": "bug", "his": "HIS", "crm": "CRM", "icu": "ICU", "ct": "CT",
    ]

    func mixedWord(_ buf: String) -> String? {
        guard buf.count >= 2, buf.count <= 16, buf.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let l = buf.lowercased()
        if let w = Self.known[l] { return w }
        guard l.count >= 4, let first = l.utf8.first, let list = buckets[first], list.contains(l) else { return nil }
        return buf
    }
}
