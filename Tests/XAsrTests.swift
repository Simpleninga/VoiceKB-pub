import AVFoundation
import XCTest

/// X-ASR 本机识别的测试。端到端那条要模型，CI 下载到 /tmp/xasr，模拟器能直接读到；本地没有就跳过
final class XAsrTests: XCTestCase {
    func testCleanText() {
        XCTAssertEqual(AsrText.clean("你好， 今天天气不错。 我们走吧"), "你好，今天天气不错。我们走吧")
        XCTAssertEqual(AsrText.clean("这个 P R 先别 merge， C I 还没过"), "这个 PR 先别 merge，CI 还没过")
        XCTAssertEqual(AsrText.clean("新的 I P A 发到软件源"), "新的 IPA 发到软件源")
        XCTAssertEqual(AsrText.clean("用 R G B Mode 看"), "用 RGB Mode 看")
        XCTAssertEqual(AsrText.clean("Chat G P T 和 Gemini"), "Chat GPT 和 Gemini")
        XCTAssertEqual(AsrText.clean(" I am OK  "), "I am OK")
    }

    func testHotwordsFormat() {
        XCTAssertEqual(AsrText.hotwords(["芽音", "Claude Code", "API key"]), "芽 音/Claude Code/API key")
        XCTAssertEqual(AsrText.hotwords(["ESP32芯片"]), "ESP32 芯 片")
        XCTAssertEqual(AsrText.hotwords(["a/b", ":x", "  ", ""]), "a b/x")
    }

    func testFixRules() {
        let r = [("deep shake", "DeepSeek"), ("Cloud Code", "Claude Code"), ("小 IAPP", "小芽 App"), ("精一", "精益")]
        XCTAssertEqual(AsrText.fix("用 deep shake 跑", rules: r, words: []), "用 DeepSeek 跑")
        XCTAssertEqual(AsrText.fix("用Deep  Shake跑", rules: r, words: []), "用DeepSeek跑")
        XCTAssertEqual(AsrText.fix("cloud code 改一下", rules: r, words: []), "Claude Code 改一下")
        XCTAssertEqual(AsrText.fix("我的小IAPP和小 IAPP", rules: r, words: []), "我的小芽 App和小芽 App")
        XCTAssertEqual(AsrText.fix("deep shaker 不是整词", rules: r, words: []), "deep shaker 不是整词")
        XCTAssertEqual(AsrText.fix("精一求精", rules: [], words: []), "精一求精")
    }

    func testFixHomophones() {
        XCTAssertEqual(AsrText.fix("打开易幻通后台", rules: [], words: ["医患通", "小芽"]), "打开医患通后台")
        XCTAssertEqual(AsrText.fix("医患通已经对了", rules: [], words: ["医患通"]), "医患通已经对了")
        XCTAssertEqual(AsrText.fix("小牙齿", rules: [], words: ["小芽"]), "小牙齿")      // 两个字的同音词不换
        XCTAssertEqual(AsrText.fix("OpenCode", rules: [], words: ["医患通"]), "OpenCode")
    }

    func testCorrectionDiff() {
        typealias P = CorrectionDiff.Pair
        XCTAssertEqual(CorrectionDiff.pairs(old: "用 deep shake 跑一下", new: "用 DeepSeek 跑一下"),
                       [P(from: "deep shake", to: "DeepSeek", left: "用 ", right: " 跑")])
        XCTAssertEqual(CorrectionDiff.pairs(old: "Cloud Code 改", new: "Claude Code 改"),
                       [P(from: "Cloud", to: "Claude", left: "", right: " C")])
        XCTAssertEqual(CorrectionDiff.pairs(old: "打开易幻通后台", new: "打开医患通后台"),
                       [P(from: "易幻", to: "医患", left: "打开", right: "通后")])
        XCTAssertEqual(CorrectionDiff.pairs(old: "这是精一的", new: "这是荆一的"),
                       [P(from: "精", to: "荆", left: "这是", right: "一的")])
        XCTAssertEqual(CorrectionDiff.pairs(old: "前面易幻通中间deep后面", new: "前面医患通中间Deep后面").count, 2)
        XCTAssertEqual(CorrectionDiff.pairs(old: "你好世界", new: "你好世界再见"), [])      // 接着往后打不是纠错
        XCTAssertEqual(CorrectionDiff.pairs(old: "这个deep", new: "这个deep shake"), [])
        XCTAssertEqual(CorrectionDiff.pairs(old: "今天天气不错", new: "完全不一样的一句话"), [])      // 重写不学
        XCTAssertEqual(CorrectionDiff.pairs(old: "你好", new: "你好"), [])
    }

    func testEnglishExtraWords() {
        let path = NSTemporaryDirectory() + "enwords-test.txt"
        try? "deep\ndeeply\nclaude\n".write(toFile: path, atomically: true, encoding: .utf8)
        let e = EnglishWords(path: path)!
        e.extra = ["deepseek": "DeepSeek", "claudecode": "Claude Code"]
        XCTAssertEqual(e.mixedWord("deepseek"), "DeepSeek")
        XCTAssertEqual(e.complete("deep", limit: 3), ["DeepSeek", "deeply"])
        XCTAssertEqual(e.complete("cla", limit: 3).first, "Claude Code")
    }

    func testSegmentsReplaceIsCumulative() {
        var s = SpeechSegments()
        s.replace("你好世界")
        s.replace("你好")      // 集束搜索偶尔回退：跟着改，不能当成「从头重来」把前面的又接一遍
        XCTAssertEqual(s.text, "你好")
    }

    private func buffer(_ rate: Double, _ channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: frames)!
        b.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { b.floatChannelData![c][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        }
        return b
    }

    /// 录音中途换设备，采样率和声道都会变：转换器要跟着换，出来的还是 16 kHz
    func testResamplerFollowsFormatChange() {
        let r = Resampler16k()
        var n = 0
        for _ in 0..<12 { n += r.convert(buffer(48_000, 1, frames: 4096)).count }
        XCTAssertEqual(Double(n), 4096 * 12 / 3, accuracy: 500)
        n = 0
        for _ in 0..<12 { n += r.convert(buffer(44_100, 2, frames: 4096)).count }
        XCTAssertEqual(Double(n), 4096 * 12 * 16_000 / 44_100, accuracy: 500)
        XCTAssertGreaterThan(r.convert(buffer(48_000, 1, frames: 4096)).map(abs).max() ?? 0, 0.1)
    }

    /// 和真机同一条路：48 kHz、4096 帧一块进重采样，再进模型；词表要真的起作用
    func testRecognizeWithHotwords() throws {
        let dir = URL(fileURLWithPath: "/tmp/xasr")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.appendingPathComponent("encoder.int8.onnx").path), "没有模型")
        let file = try AVAudioFile(forReading: dir.appendingPathComponent("test.wav"))
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        let f48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let up = AVAudioConverter(from: src.format, to: f48)!
        let big = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: src.frameLength * 3 + 4096)!
        var given = false
        var err: NSError?
        up.convert(to: big, error: &err) { _, st in
            if given { st.pointee = .endOfStream; return nil }
            given = true
            st.pointee = .haveData
            return src
        }
        XCTAssertNil(err)

        var logs: [String] = []
        XAsr.shared.log = { logs.append($0) }
        XAsr.shared.resetTries()
        let done = expectation(description: "final")
        var finalText: String?, failure: String?, partials = 0
        XAsr.shared.begin(dir: dir, hotwords: AsrText.hotwords(["CodeBuddy", "OpenCode", "芽音"])) { text, isFinal, e in
            failure = e
            if isFinal { finalText = text; done.fulfill() } else { partials += 1 }
        }
        let r = Resampler16k()
        var off: AVAudioFrameCount = 0
        while off < big.frameLength {
            let n = min(4096, big.frameLength - off)
            let b = AVAudioPCMBuffer(pcmFormat: f48, frameCapacity: n)!
            b.frameLength = n
            memcpy(b.floatChannelData![0], big.floatChannelData![0] + Int(off), Int(n) * MemoryLayout<Float>.size)
            XAsr.shared.feed(r.convert(b))
            off += n
        }
        XAsr.shared.end()
        wait(for: [done], timeout: 120)
        print("XASR:", finalText ?? "nil", logs)
        XCTAssertNil(failure)
        XCTAssertGreaterThan(partials, 0, "边说边出字")
        XCTAssertTrue(finalText?.contains("OpenCode") == true, finalText ?? "nil")
        XCTAssertTrue(finalText?.contains("CodeBuddy") == true, "词表没起作用：\(finalText ?? "nil")")
        XCTAssertFalse(XAsr.shared.gaveUp)
    }

    /// 路径不对：要报错退回，不能把 App 带崩
    func testBadModelFailsSoftly() {
        XAsr.shared.unload()
        let done = expectation(description: "fail")
        XAsr.shared.begin(dir: URL(fileURLWithPath: "/nonexistent"), hotwords: "") { _, isFinal, e in
            XCTAssertTrue(isFinal)
            XCTAssertNotNil(e)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XAsr.shared.resetTries()
    }
}
