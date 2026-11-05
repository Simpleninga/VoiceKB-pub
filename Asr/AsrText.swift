import Foundation

/// X-ASR 的文字整理和热词格式：纯字符串处理，测试在 Tests/XAsrTests.swift
enum AsrText {
    /// 模型吐出来的是「你好， 这个 C I 过了」：中文标点后多个空格、缩写的字母之间有空格。这里只修这两样，别的交给润色
    static func clean(_ s: String) -> String {
        var t = sub(s, "([，。！？、；：])\\s+", "$1")
        t = sub(t, "(?<![A-Za-z])([A-Z]) (?=[A-Z](?![A-Za-z]))", "$1")
        t = sub(t, " {2,}", " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 给 sherpa-onnx 的热词串，词之间用 /。模型里每个汉字是单独的 token（▁芽 ▁音），所以汉字要用空格隔开，
    /// 不隔开就编码成「▁芽 音」，模型根本不会输出这串 token，热词白给（11-05 实测：隔开后专名命中 58%→84%）。
    /// sherpa 把 / 当分隔、把 : 开头的当权重，这两个字符从词里去掉
    static func hotwords(_ words: [String]) -> String {
        words.compactMap { w -> String? in
            var out = ""
            for u in w.unicodeScalars {
                switch u {
                case "/", ":", "\n", "\t", "\r": out += " "
                case "\u{3400}"..."\u{9FFF}": out += " \(u) "
                default: out.unicodeScalars.append(u)
                }
            }
            let parts = out.split(separator: " ")
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }.joined(separator: "/")
    }

    /// 词库纠错：先按规则换（「deep shake → DeepSeek」），再把读音和常用词完全一样的换掉（「易幻通 → 医患通」）。
    /// 字母不分大小写，字母和汉字之间有没有空格都算；英文词要整词才算，不会把别的词拆开改
    static func fix(_ s: String, rules: [(String, String)], words: [String]) -> String {
        var t = s
        for (a, b) in rules.sorted(by: { $0.0.count > $1.0.count }) {
            guard let re = try? NSRegularExpression(pattern: pattern(a), options: .caseInsensitive) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: NSRegularExpression.escapedTemplate(for: b))
        }
        return homophones(t, words)
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }

    /// 规则左边写成正则：汉字一个一个、英文一串一串，中间允许空格
    private static func pattern(_ from: String) -> String {
        var parts: [String] = [], run = ""
        for c in from {
            if c.isASCII, c.isLetter || c.isNumber { run.append(c); continue }
            if !run.isEmpty { parts.append(run); run = "" }
            if !c.isWhitespace { parts.append(String(c)) }
        }
        if !run.isEmpty { parts.append(run) }
        let body = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s*")
        let edge = "A-Za-z0-9"
        let head = from.first?.isASCII == true ? "(?<![\(edge)])" : ""
        let tail = from.last?.isASCII == true ? "(?![\(edge)])" : ""
        return head + body + tail
    }

    private static func pinyin(_ c: Character) -> String {
        String(c).applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? ""
    }

    /// 三个字以上的常用词才按读音换：两个字的同音词太多（荆一 / 经意），靠规则
    private static func homophones(_ s: String, _ words: [String]) -> String {
        var cs = Array(s)
        var cache: [Character: String] = [:]
        func py(_ c: Character) -> String {
            if let p = cache[c] { return p }
            let p = pinyin(c)
            cache[c] = p
            return p
        }
        for w in words {
            let target = Array(w)
            guard target.count >= 3, target.allSatisfy(isHan) else { continue }
            let want = target.map(py)
            var i = 0
            while i + target.count <= cs.count {
                let win = Array(cs[i..<(i + target.count)])
                if win != target, win.allSatisfy(isHan), win.map(py) == want {
                    cs.replaceSubrange(i..<(i + target.count), with: target)
                    i += target.count
                } else {
                    i += 1
                }
            }
        }
        return String(cs)
    }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
