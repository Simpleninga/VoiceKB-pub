import Foundation

/// 苹果的识别器在你停顿之后，常常把新的一句从头开始转写、不再带着前面的话
/// （2026-10-23 用户反馈：停顿一下再说，前面说的会被覆盖）。
/// 这里把前面几段接起来：新结果和上一条「一点也不连着」（开头对不上、还变短了）就当作识别器从头重来了，
/// 上一条定稿，后面接着往它后面写。
struct SpeechSegments {
    private(set) var committed = ""   // 前面几段（定稿）
    private(set) var current = ""     // 识别器现在这一段
    var text: String { committed + current }

    /// 收到识别器的新结果；返回 true = 判断它是从头重来的（前面那段已经定稿接在前面）
    @discardableResult
    mutating func update(_ new: String) -> Bool {
        let reset = SpeechSegments.looksLikeRestart(prev: current, new: new)
        if reset { committed += current }
        current = new
        return reset
    }

    /// 识别器这个任务结束了（要接着开新任务）：这一段定稿
    mutating func commitCurrent() {
        committed += current
        current = ""
    }

    mutating func clear() {
        committed = ""
        current = ""
    }

    /// 实字数：不算标点、空格、符号。识别器会在已经出来的字中间补标点，所以对位置只能数实字
    static func solid(_ s: String) -> Int {
        s.reduce(0) { $0 + ($1.isPunctuation || $1.isWhitespace || $1.isSymbol ? 0 : 1) }
    }

    /// 跳过前 n 个实字之后剩下的部分（紧跟在第 n 个实字后面的标点留在剩下的部分里）。
    /// 用户在说话中途动手改了输入框，前面的字就冻结了，后面只接「冻结之后新说的」。
    static func remainder(_ s: String, skipping n: Int) -> String {
        guard n > 0 else { return s }
        var seen = 0
        for (i, c) in zip(s.indices, s) where !(c.isPunctuation || c.isWhitespace || c.isSymbol) {
            seen += 1
            if seen == n { return String(s[s.index(after: i)...]) }
        }
        return ""
    }

    /// 上一条够长（≥4 个字）、新的这条比它短、而且开头对不上（公共开头不到 2 个字）
    /// 前几个字在一句话刚开口时本来就会反复改（「是」→「我是」），所以上一条太短时不算。
    static func looksLikeRestart(prev: String, new: String) -> Bool {
        guard prev.count >= 4, new.count < prev.count else { return false }
        let common = zip(prev, new).prefix { $0 == $1 }.count
        return common < 2
    }
}
