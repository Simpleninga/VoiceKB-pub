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

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
