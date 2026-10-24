import Foundation

/// 表情联想（三期）：拼音 → 表情、词 → 表情。数据 Keyboard/Resources/emoji.txt 由 tools/build_emoji.py 生成
/// （Unicode CLDR 的中文表情名 + 手写的口语叫法），每行 `拼音键\t关键词\t表情 表情 …`。
/// 用法：打的拼音正好是某个关键词的拼音（haha、aixin、zuqiu…）就在候选后面补表情；选了一个词（哈哈）后联想行里也先给它的表情。
final class EmojiIndex {
    private var byKey: [String: [String]] = [:]
    private var byWord: [String: [String]] = [:]

    init?(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            let es = f[2].split(separator: " ").map(String.init)
            byKey[String(f[0]), default: []].append(contentsOf: es.filter { !(byKey[String(f[0])]?.contains($0) ?? false) })
            byWord[String(f[1]), default: []] = es
        }
        if byKey.isEmpty { return nil }
    }

    func forKey(_ k: String) -> [String] { byKey[k] ?? [] }
    func forWord(_ w: String) -> [String] { byWord[w] ?? [] }
}
