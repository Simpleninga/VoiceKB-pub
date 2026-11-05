import AVFoundation
import SherpaOnnxC

/// 麦克风的声音转成模型要的 16 kHz 单声道。
/// 不交给 sherpa-onnx 自己转：同一路流里采样率一变（录音中途换耳机）它会直接退出进程
final class Resampler16k {
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var conv: AVAudioConverter?
    private var from: AVAudioFormat?

    func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        if conv == nil || from != buf.format {
            conv = AVAudioConverter(from: buf.format, to: out)
            from = buf.format
        }
        guard let conv, buf.format.sampleRate > 0 else { return [] }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 64
        guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return [] }
        var given = false, err: NSError?
        conv.convert(to: o, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true
            st.pointee = .haveData
            return buf
        }
        guard err == nil, let p = o.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(o.frameLength)))
    }
}

/// sherpa-onnx 的 C 接口包一层。不是线程安全的，只在 XAsr 的串行队列上用
private final class XAsrRecognizer {
    private let rec: OpaquePointer
    private var stream: OpaquePointer?

    /// 文件不对时 sherpa-onnx 返回空指针（Linux 上按同样的配置测过，不会退出进程）
    init?(dir: URL) {
        var keep: [UnsafeMutablePointer<CChar>] = []
        defer { keep.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            keep.append(p)
            return UnsafePointer(p)
        }
        func path(_ name: String) -> UnsafePointer<CChar> { c(dir.appendingPathComponent(name).path) }
        var cfg = SherpaOnnxOnlineRecognizerConfig()
        cfg.feat_config.sample_rate = 16_000
        cfg.feat_config.feature_dim = 80
        cfg.model_config.transducer.encoder = path("encoder.int8.onnx")
        cfg.model_config.transducer.decoder = path("decoder.onnx")
        cfg.model_config.transducer.joiner = path("joiner.int8.onnx")
        cfg.model_config.tokens = path("tokens.txt")
        cfg.model_config.num_threads = 2
        cfg.model_config.modeling_unit = c("bpe")
        cfg.model_config.bpe_vocab = path("bpe.vocab")
        cfg.decoding_method = c("modified_beam_search")     // 热词只在这个解码方式下生效
        cfg.max_active_paths = 4
        cfg.hotwords_score = 2.5                            // 11-05 实测：2.5 最好，4 反而把别的词带偏
        guard let r = SherpaOnnxCreateOnlineRecognizer(&cfg) else { return nil }
        rec = r
    }

    deinit {
        stop()
        SherpaOnnxDestroyOnlineRecognizer(rec)
    }

    func start(hotwords: String) {
        stop()
        stream = hotwords.isEmpty ? SherpaOnnxCreateOnlineStream(rec) : SherpaOnnxCreateOnlineStreamWithHotwords(rec, hotwords)
    }

    func accept(_ samples: [Float]) {
        guard let stream else { return }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, samples, Int32(samples.count))
        while SherpaOnnxIsOnlineStreamReady(rec, stream) != 0 { SherpaOnnxDecodeOnlineStream(rec, stream) }
    }

    /// 说完了：垫一小段静音把模型里压着的最后几个字挤出来
    func finish() {
        guard let stream else { return }
        accept([Float](repeating: 0, count: 12_800))
        SherpaOnnxOnlineStreamInputFinished(stream)
        while SherpaOnnxIsOnlineStreamReady(rec, stream) != 0 { SherpaOnnxDecodeOnlineStream(rec, stream) }
    }

    var text: String {
        guard let stream, let r = SherpaOnnxGetOnlineStreamResult(rec, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(r) }
        return r.pointee.text.map { String(cString: $0) } ?? ""
    }

    func stop() {
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        stream = nil
    }
}

/// 本机语音识别（X-ASR 流式模型）。加载、喂声音、解码都排在一条串行队列上：
/// 模型还没加载好就开口也不丢声音，排着队等它好了一起解码。一次录音从头到尾只有一路流，文字是累积的
final class XAsr: @unchecked Sendable {
    static let shared = XAsr()
    var log: ((String) -> Void)?

    private let q = DispatchQueue(label: "voicekb.xasr", qos: .userInitiated)
    private var rec: XAsrRecognizer?
    private var open = false
    private var last = ""
    private var onText: ((String?, Bool, String?) -> Void)?
    private var audioSec = 0.0, spentSec = 0.0

    // 进程要是死在模型里（内存被系统收了、库崩了），Swift 接不住，App 每次打开、每次说话都会死一遍。
    // 所以动模型前记一笔、顺利结束才清掉：连着 3 笔没清就不再用它，退回苹果识别，设置里切一下引擎重置
    private static let triesKey = "xasrTries"
    var gaveUp: Bool { UserDefaults.standard.integer(forKey: Self.triesKey) >= 3 }
    func resetTries() { UserDefaults.standard.set(0, forKey: Self.triesKey) }
    private func arm() { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: Self.triesKey) + 1, forKey: Self.triesKey) }

    private func load(_ dir: URL) -> XAsrRecognizer? {
        if let rec { return rec }
        guard !gaveUp else { return nil }
        arm()
        let t = Date()
        rec = XAsrRecognizer(dir: dir)
        if rec != nil {
            resetTries()
            log?(String(format: "X-ASR 模型加载 %.1f 秒", Date().timeIntervalSince(t)))
        }
        return rec
    }

    func preload(dir: URL) { q.async { [self] in _ = load(dir) } }

    /// 不待命了就把内存还回去（模型约占 300MB），下次说话再加载
    func unload() { q.async { [self] in if !open { rec = nil } } }

    /// onText(文字, 是否最终结果, 错误)：在串行队列上回调，按顺序来
    func begin(dir: URL, hotwords: String, onText: @escaping (String?, Bool, String?) -> Void) {
        q.async { [self] in
            guard let r = load(dir) else {
                onText(nil, true, "本机语音模型加载失败")
                return
            }
            arm()
            self.onText = onText
            last = ""
            audioSec = 0
            spentSec = 0
            open = true
            r.start(hotwords: hotwords)
        }
    }

    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        q.async { [self] in
            guard open, let r = rec else { return }
            let t = Date()
            r.accept(samples)
            let x = AsrText.clean(r.text)
            spentSec += Date().timeIntervalSince(t)
            audioSec += Double(samples.count) / 16_000
            if x != last {
                last = x
                onText?(x, false, nil)
            }
        }
    }

    func end() {
        q.async { [self] in
            guard open, let r = rec else { return }
            open = false
            r.finish()
            let x = AsrText.clean(r.text)
            r.stop()
            resetTries()
            log?(String(format: "X-ASR 说了 %.1f 秒，解码用 %.1f 秒", audioSec, spentSec))
            onText?(x, true, nil)
            onText = nil
        }
    }

    /// 这次录音作废
    func cancel() {
        q.async { [self] in
            guard open else { return }
            open = false
            rec?.stop()
            resetTries()
            onText = nil
        }
    }
}
