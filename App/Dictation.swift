import AVFoundation
import Combine
import Speech
import SwiftUI

/// 麦克风数据的接收端。回调在音频线程里，所以不放进 MainActor 的类里，自己加锁。
final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastBeat: TimeInterval = 0

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); let r = request; lock.unlock()
        r?.append(buf)
        if r != nil { Hub.shared.push(levels: Self.levels(of: buf)) }   // 说话时才算音量，待命时不费这个电
        let now = Date().timeIntervalSince1970
        if now - lastBeat >= 1 { lastBeat = now; Hub.shared.hb = now }   // 每秒一次心跳：键盘靠它知道 App 还活着
    }

    /// 把这一块声音切成最多 4 小段，每段算一个音量（0~1）：-50 分贝以下算 0，-10 分贝以上算 1
    private static func levels(of buf: AVAudioPCMBuffer) -> [Double] {
        guard let ch = buf.floatChannelData?[0] else { return [] }
        let n = Int(buf.frameLength)
        guard n >= 64 else { return [] }
        let parts = min(4, n / 256 + 1)
        let size = n / parts
        var out: [Double] = []
        for p in 0..<parts {
            var sum: Float = 0
            for i in (p * size)..<((p + 1) * size) { sum += ch[i] * ch[i] }
            let db = 20 * log10(max((sum / Float(size)).squareRoot(), 0.000_01))
            out.append((Double(min(1, max(0, (db + 50) / 40))) * 100).rounded() / 100)
        }
        return out
    }
}

/// 主 App 的核心：录音引擎（后台保活）+ 苹果自带语音识别 + 可选的服务器润色，跟键盘用本机回环 HTTP（Bridge）+ Darwin 通知对话。
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    @Published var engineRunning = false
    @Published var state = "idle"            // idle / recording / processing
    @Published var partial = ""
    @Published var lastRaw = ""
    @Published var lastPolished = ""
    @Published var lastInfo = ""
    @Published var remain = 0                // 保活还剩几秒；-1 = 一直开
    @Published var micOK = false
    @Published var speechOK = false
    @Published var onDeviceOK = false
    @Published var logLines: [String] = []
    @Published var swipeBackHint = false     // 没法自动跳回时，提示用户手动划回去

    private var engine = AVAudioEngine()
    private let sink = TapSink()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var gen = 0                      // 第几次录音（也是发给键盘的 sid）
    private var taskSeq = 0                  // 这次录音里第几个识别任务，旧任务的回调靠它认出来丢掉
    private var taskStart = Date()
    private var quickRestarts = 0
    private var segs = SpeechSegments()      // 识别器停顿后会从头重来，前面的话要接上
    private var cutBase = 0                  // 用户中途动手改过输入框：前面这么多个实字已经冻结，不再往键盘送
    private var cutCount = 0                 // 这次录音里冻结过几回（键盘靠它认出哪些结果是新的）
    private var resultCuts = 0               // resultText 是在第几回冻结之后给的
    private var pendingStart = false         // 开始录音在等权限，用户松手了就取消
    private var finished = true
    private var wantEngine = false
    private var deadline = Date.distantPast // 保活到什么时候
    private var recStart = Date()
    private var resultText = ""
    private var resultSID = 0                // resultText 是第几次录音的（键盘靠它认出这条结果是不是它亲眼看着的那次录音）
    private var lastHeal = Date.distantPast
    private var lastVerify = Date.distantPast
    private var ctxBefore = ""               // 开始说话时输入框里光标前的字（键盘给的）：只交给润色当语境，用一次就清
    private var altHints: [String] = []      // 识别器对没把握的词给的别的写法（「词→候选/候选」）：交给润色，让它按语境选
    private var rseq = 0
    private var rtime: TimeInterval = 0
    private var errText = ""
    private var errTime: TimeInterval = 0
    private var lastCmdSeq = 0
    private var lastKLogSeq = 0
    private var tick: Timer?
    private var finishTimer: Timer?
    private var autoStop: Timer?

    private var keepMin: Int { UserDefaults.standard.object(forKey: "keepMin") as? Int ?? 30 }   // -1 一直开，0 关闭
    // 默认走苹果云端识别：本机模型对生僻词、古文、专名明显更弱（10-28 「璧礼天琮礼地」被听成「伊犁天从你弟」）；设置里还能改回只用本机
    private var onDevicePref: Bool { UserDefaults.standard.object(forKey: "onDevice") as? Bool ?? false }
    private var polishOn: Bool { UserDefaults.standard.object(forKey: "polish") as? Bool ?? true }
    private var style: String { UserDefaults.standard.string(forKey: "style") ?? "light" }
    private var serviceReady: Bool { !Server.key.isEmpty }      // 安装包里有服务密钥才能润色 / 传日志

    private init() {
        rseq = Int(Date().timeIntervalSince1970)   // 内存状态重启就没了，用时间起头保证比键盘记着的「已插入到第几条」大
        gen = rseq                                 // 录音号也用时间起头：键盘记着「哪次录音已经作废」，App 重启后不能撞号
        Bridge.shared.onKbd = { [weak self] in
            Task { @MainActor in self?.handleCmd() }
        }
        Bridge.shared.start()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in self?.interruption(type) }
        }
        refreshPerms()
        refreshHot()
        publish()
    }

    // MARK: 日志 / 状态

    /// remote = true 的日志同时传到服务器，出问题时不用用户截图，直接去服务器上看
    func log(_ s: String, remote: Bool = true) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.insert("\(f.string(from: Date())) \(s)", at: 0)
        if logLines.count > 40 { logLines.removeLast() }
        if remote, serviceReady { Task { await Server.sendLog(s) } }
    }

    /// 把状态写给键盘看，并叫醒它
    private func publish() {
        Hub.shared.app = [
            "state": state, "partial": partial, "result": resultText, "rseq": rseq, "rtime": rtime,
            "sid": gen, "rsid": resultSID, "cuts": cutCount, "rcuts": resultCuts, "base": cutBase, "err": errText, "errtime": errTime, "keepUntil": min(deadline.timeIntervalSince1970, 4_000_000_000), "engine": engine.isRunning,
        ]
        KB.post(KB.nState)
    }

    func refreshPerms() {
        micOK = AVAudioApplication.shared.recordPermission == .granted
        speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized
        onDeviceOK = recognizer?.supportsOnDeviceRecognition ?? false
    }

    /// 取服务器上的常用词表存下来，识别时当提示；取不到就沿用上次的
    func refreshHot() {
        guard serviceReady else { return }
        Task {
            if let r = try? await Server.call("GET", "/kb/v1/hot", timeout: 6), let w = r["words"] as? [String], !w.isEmpty {
                UserDefaults.standard.set(w, forKey: "serverHot")
            }
        }
    }

    /// 给识别器的提示词：服务器的常用词表 + 键盘里我用得最多的词（最近一次说话时键盘带来的），去重，最多 100 个
    private func hotwords() -> [String] {
        let d = UserDefaults.standard
        var seen = Set<String>(), out: [String] = []
        for w in (d.stringArray(forKey: "serverHot") ?? []) + (d.stringArray(forKey: "kbHot") ?? []) where !w.isEmpty && seen.insert(w).inserted {
            out.append(w)
        }
        return Array(out.prefix(100))
    }

    func ensurePermissions() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        }
        refreshPerms()
        if !micOK || !speechOK {
            fail("没有麦克风或语音识别权限：到 设置 → 芽音 里打开")
            return false
        }
        return true
    }

    // MARK: 录音引擎（后台保活就靠它一直转着）

    private func ensureEngine() throws {
        wantEngine = true
        guard !engine.isRunning else { return }
        let s = AVAudioSession.sharedInstance()
        // 蓝牙只开 A2DP（高音质输出），不能开 .allowBluetooth（HFP 通话模式）：开了以后一连耳机，系统就把耳机切成电话音质——
        // 正在听的歌变糊、音量突变，耳机麦克风也只有窄带，识别很差；还会因为「后台不许打断别人」让引擎重启报 !int（10-25 实测）。
        // 这样耳机只管放声音，收音一律用手机自己的麦克风。
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
        try s.setActive(true)
        if let mic = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? s.setPreferredInput(mic) }
        var input = engine.inputNode
        var fmt = input.outputFormat(forBus: 0)
        if fmt.sampleRate <= 0 || fmt.channelCount == 0 {
            // 这个引擎的输入格式卡在 0 Hz 不再更新（10-27 戴耳机后，同一个引擎重试十几分钟、隔几个小时都读到 0）：换一个全新的引擎对象再读一次。
            // 换完还是 0 就是系统真没给输入，路由和可用输入写进日志，下次一眼看出是耳机还是别的 App 占着
            input.removeTap(onBus: 0)
            engine = AVAudioEngine()
            input = engine.inputNode
            fmt = input.outputFormat(forBus: 0)
            let avail = s.availableInputs?.map { $0.portType.rawValue }.joined(separator: "+") ?? "无"
            log("麦克风格式 0 Hz，换了新引擎：现在 \(Int(fmt.sampleRate)) Hz \(fmt.channelCount) 声道；\(routeText())；可用输入 \(avail)；系统说有输入=\(s.isInputAvailable)")
        }
        // 切换音频设备的瞬间格式可能是 0 Hz / 0 声道，这时 installTap 会直接抛 ObjC 异常把 App 弄崩，先挡住，交给 heal() 稍后重试
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "VoiceKB", code: 1, userInfo: [NSLocalizedDescriptionKey: "麦克风格式还没就绪（\(fmt.sampleRate) Hz，\(fmt.channelCount) 声道）"])
        }
        input.removeTap(onBus: 0)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in sink.feed(buf) }
        engine.prepare()
        try engine.start()
        engineRunning = true
        log("录音引擎启动，后台待命（\(routeText())；\(Int(fmt.sampleRate)) Hz）")
    }

    /// 当前音频路由，写进日志：以后出事一眼看出输入是不是手机麦克风、有没有掉进蓝牙通话模式（BluetoothHFP）
    private func routeText() -> String {
        let r = AVAudioSession.sharedInstance().currentRoute
        func names(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.isEmpty ? "无" : ports.map { $0.portType.rawValue }.joined(separator: "+")
        }
        return "输入 \(names(r.inputs)) / 输出 \(names(r.outputs))"
    }

    func stopEngine() {
        wantEngine = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        engineRunning = false
        Hub.shared.hb = 0
        publish()
    }

    private func restartEngine() {
        guard wantEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try ensureEngine(); log("音频设备变化，引擎已重启（\(routeText())）") } catch { log("引擎重启失败：\(error.localizedDescription)") }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        if type == .began {
            log("音频被打断（来电/Siri 等）")
            if state != "idle" { finish() }
        } else if type == .ended, wantEngine {
            do { try ensureEngine(); log("打断结束，引擎恢复") } catch { log("引擎恢复失败：\(error.localizedDescription)") }
        }
    }

    private func extendKeepalive() {
        let m = keepMin
        deadline = m < 0 ? .distantFuture : Date().addingTimeInterval(Double(m) * 60)
    }

    private func onTick() {
        engineRunning = engine.isRunning
        remain = deadline == .distantFuture ? -1 : max(0, Int(deadline.timeIntervalSinceNow))
        if wantEngine, state == "idle", deadline != .distantFuture, Date() > deadline {
            log("保活时间到，停止后台待命")
            stopEngine()
            return
        }
        if Date().timeIntervalSince(lastVerify) >= 5 {      // 键盘靠本机通道找我：它悄悄坏了要尽快发现、重建
            lastVerify = Date()
            Bridge.shared.verify { [weak self] ok in
                if !ok { Task { @MainActor in self?.log("本机通道不通（键盘会连不上我），已重建监听") } }
            }
        }
        heal()
    }

    /// 待命中却出了岔子就自己修：引擎被系统停了（键盘会当成「没待命」、点麦克风只能走跳转），或者引擎在转但好几秒没有声音进来
    /// （麦克风被别的 App，比如小芽通话占了）。日志里留一行，下次出事能看出原因；10 秒最多试一次
    private func heal() {
        guard wantEngine, state == "idle", Date().timeIntervalSince(lastHeal) > 10 else { return }
        let silent = engineRunning && Date().timeIntervalSince1970 - Hub.shared.hb > 6
        guard !engineRunning || silent else { return }
        lastHeal = Date()
        log(engineRunning ? "引擎在转但 6 秒没有声音进来，重启" : "录音引擎被系统停了，重启")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try ensureEngine() } catch { log("引擎重启失败：\(error.localizedDescription)") }
    }

    // MARK: 听写

    func handle(url: URL) {
        guard url.host == "dictate" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let host = q.first { $0.name == "host" }?.value ?? ""
        let how = q.first { $0.name == "how" }?.value ?? ""
        let src = q.first { $0.name == "src" }?.value ?? "?"      // mic = 点麦克风，space = 按住空格（冷启动时都要跳进来）
        let pid = Int32(q.first { $0.name == "pid" }?.value ?? "") ?? 0
        log("键盘拉起本 App，开始录音（\(src)；宿主：\(host.isEmpty ? "没认出来" : host)；\(how.prefix(600))）")
        var path: String?, name: String?
        if host.isEmpty, pid > 0 {      // 认不出 bundle id：试着按进程号查宿主的可执行文件路径、进程名
            let r = Self.pidPath(pid)
            let n = Self.pidName(pid)
            log("宿主进程 \(pid)：路径 \(r)；进程名 \(n)")
            if r.hasPrefix("/") { path = r }
            if !n.hasPrefix("读不到") { name = n }
        }
        ctxBefore = q.first { $0.name == "ctx" }?.value ?? ""
        lastVerify = Date()
        Bridge.shared.verify { [weak self] ok in      // 键盘约 1.6 秒后会来连本机通道：先确认它是通的，不通立刻重建
            if !ok { Task { @MainActor in self?.log("本机通道不通（键盘会连不上我），已重建监听") } }
        }
        startRecording()
        returnToHost(host, path: path, name: name)
    }

    /// 进程号 → 进程名（可执行文件名，微信是 WeChat）：先用 sysctl 取 kinfo_proc 的 p_comm，不行再试 proc_name。
    /// 沙盒里能不能读别的进程要真机试（proc_pidpath 已确认读不到），结果写进日志
    private static func pidName(_ pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 {
            let n = withUnsafePointer(to: &info.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
            }
            if !n.isEmpty { return n }
        }
        let e1 = errno
        typealias Fn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_name") {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = unsafeBitCast(sym, to: Fn.self)(pid, &buf, 64)
            if n > 0 { return String(decoding: buf[..<Int(n)], as: UTF8.self) }
        }
        return "读不到（sysctl errno \(e1)）"
    }

    /// 进程号 → 可执行文件路径（libproc 的 proc_pidpath；按名字取，编不过也不怕）
    private static func pidPath(_ pid: Int32) -> String {
        typealias Fn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pidpath") else { return "没有 proc_pidpath" }
        let f = unsafeBitCast(sym, to: Fn.self)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = f(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf[..<Int(n)], as: UTF8.self) : "读不到（errno \(errno)）"
    }

    /// 录上音以后自动跳回键盘所在的 App。
    /// 刚被拉到前台的 App 只有很短一段时间（约 0.3 秒）还能 open 别的 App，过了系统就拒绝，所以等录音真正开始最多 0.25 秒，到点就跳。
    private func returnToHost(_ host: String, path: String?, name: String? = nil) {
        func hint(_ why: String) {
            log(why)
            swipeBackHint = true
        }
        if host.hasPrefix("com.simpleninga.voicekb") { return }      // 就在本 App 里测试，不用跳
        let id = !host.isEmpty ? host : (path ?? name ?? "")
        guard !id.isEmpty else { return hint("没认出宿主 App，请手动划回去") }
        let found = !host.isEmpty ? HostReturn.url(for: host) : (path != nil ? HostReturn.url(forPath: id) : HostReturn.url(forName: id))
        guard let url = found else { return hint("没有「\(id)」的跳转地址，请手动划回去") }
        swipeBackHint = false
        var opened = false
        var bag = Set<AnyCancellable>()
        func go(_ via: String) {
            guard !opened else { return }
            opened = true
            bag.removeAll()
            UIApplication.shared.open(url, options: [:]) { ok in
                Task { @MainActor in
                    if ok { self.log("已跳回 \(id)（\(via)）") } else { hint("跳回 \(id) 失败，请手动划回去") }
                }
            }
        }
        $state.first { $0 == "recording" }.receive(on: DispatchQueue.main).sink { _ in go("录音已开始") }.store(in: &bag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { go("到点了") }
    }

    private func handleCmd() {
        let k = Hub.shared.kbd
        if let ls = k["lseq"] as? Int, ls > lastKLogSeq {      // 键盘的日志（键盘出现时的诊断等）
            lastKLogSeq = ls
            if let t = k["klog"] as? String, !t.isEmpty { log(t) }
        }
        let seq = k["cseq"] as? Int ?? 0
        guard seq > lastCmdSeq else { return }
        lastCmdSeq = seq
        switch k["cmd"] as? String ?? "" {
        case "start":
            log("键盘：开始")
            ctxBefore = k["ctx"] as? String ?? ""
            if let h = k["hot"] as? [String], !h.isEmpty { UserDefaults.standard.set(Array(h.prefix(60)), forKey: "kbHot") }
            startRecording()
        case "stop": log("键盘：停止（\(k["src"] as? String ?? "?")）"); stopRecording()
        case "cut": cut(upTo: k["n"] as? Int ?? 0, count: k["k"] as? Int)
        case "cancel": log("键盘：换了输入框，这次录音作废（\(k["src"] as? String ?? "?")）"); cancelRecording()
        default: break
        }
    }

    func startRecording() {
        guard state == "idle", !pendingStart else { return }
        pendingStart = true
        Task {
            let ok = await ensurePermissions()
            guard pendingStart else { return }      // 等权限的时候用户已经松手了
            pendingStart = false
            if ok { beginRecording() }
        }
    }

    /// 键盘换到了别的输入框（别的窗口 / 别的输入框）：这次录音作废——不收尾、不润色、不再给键盘结果，马上回到待命，
    /// 新输入框从干净状态开始（用户 10-24：每个输入框的语音要互相隔离）
    func cancelRecording() {
        if pendingStart { pendingStart = false; return }
        guard state != "idle" else { return }
        finished = true
        cleanup()
        gen += 1          // 还在等的润色结果对不上号了，回来也不发
        state = "idle"
        partial = ""
        errText = ""
        extendKeepalive()
        publish()
        if keepMin == 0 { stopEngine() }
    }

    /// 用户在说话中途动手改了输入框（删字、挪光标、打字）：键盘已经打进去的那 n 个实字就冻结了，
    /// 后面只送新说的，接着打在用户现在的光标处；最后的润色也只管冻结之后的部分（用户亲手改过的不再被覆盖）
    private func cut(upTo n: Int, count: Int?) {
        guard state == "recording" else { return }
        cutBase = max(cutBase, n)
        cutCount = count ?? cutCount + 1       // 以键盘数的为准（它的某条指令丢了也能对上）
        partial = SpeechSegments.remainder(segs.text, skipping: cutBase)
        log("键盘：输入框被动过，前 \(cutBase) 个字冻结，接着往后写")
        publish()
    }

    private func beginRecording() {
        guard state == "idle" else { return }
        guard let recognizer, recognizer.isAvailable else { fail("语音识别现在不可用"); return }
        if engine.isRunning, Date().timeIntervalSince1970 - Hub.shared.hb > 3 {      // 引擎开着但几秒没收到声音：这次录出来只会是「没听到内容」，先重启
            log("录音前发现引擎没有声音进来，重启")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        do { try ensureEngine() } catch { fail("录音引擎启动失败：\(error.localizedDescription)"); return }
        gen += 1
        finished = false
        segs.clear()
        cutBase = 0
        cutCount = 0
        resultCuts = 0
        altHints = []
        Hub.shared.clearLevels()
        quickRestarts = 0
        startTask(recognizer)
        partial = ""
        state = "recording"
        recStart = Date()
        errText = ""
        publish()
        if polishOn, serviceReady {      // 先把服务器上润色用的进程起好，说完就不用等它启动
            let style = self.style
            Task { await Server.warm(style: style) }
        }
        autoStop?.invalidate()
        autoStop = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
        }
    }

    /// 开一个识别任务，麦克风的声音接给它。一次录音里可能接连开好几个（识别器停顿后自己结束了，就接着开下一个）
    private func startTask(_ recognizer: SFSpeechRecognizer) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = onDevicePref && recognizer.supportsOnDeviceRecognition
        req.taskHint = .dictation
        let hot = hotwords()      // 常用词（医患通、小芽……）：告诉识别器这些词存在，听到近音优先往它们上靠
        if !hot.isEmpty { req.contextualStrings = hot }
        request = req
        taskSeq += 1
        let t = taskSeq
        taskStart = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let err = error?.localizedDescription
            let hints = result.map { Self.hintsFrom($0.bestTranscription) } ?? []
            Task { @MainActor in self?.onRecognition(t, text: text, isFinal: isFinal, err: err, hints: hints) }
        }
        sink.set(req)
    }

    func stopRecording() {
        if pendingStart { pendingStart = false; return }    // 还没开始就松手了
        guard state == "recording" else { return }
        state = "processing"
        Hub.shared.clearLevels()
        publish()
        autoStop?.invalidate()
        request?.endAudio()
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }   // 识别迟迟不给最终结果：用最后一次的中间结果
        }
    }

    /// 识别器对某个词没把握（置信度低）时会给出别的可能写法：整理成「词→候选/候选」，润色时让它按语境从里面选。
    /// 中间结果没有置信度（全是 0），这时不出备选，免得把每个词都当成不确定
    nonisolated static func hintsFrom(_ tr: SFTranscription) -> [String] {
        guard tr.segments.contains(where: { $0.confidence > 0 }) else { return [] }
        return tr.segments.compactMap { s in
            guard s.confidence < 0.5, !s.alternativeSubstrings.isEmpty else { return nil }
            return s.substring + "→" + s.alternativeSubstrings.prefix(3).joined(separator: "/")
        }
    }

    private func onRecognition(_ t: Int, text: String?, isFinal: Bool, err: String?, hints: [String]) {
        guard t == taskSeq, !finished else { return }
        for h in hints where !altHints.contains(h) { altHints.append(h) }
        if altHints.count > 12 { altHints.removeFirst(altHints.count - 12) }
        if let text, !text.isEmpty {
            if segs.update(text) { log("停顿后识别器从头重来，前面的话已接上") }
            partial = SpeechSegments.remainder(segs.text, skipping: cutBase)
            if state == "recording" { publish() }
        }
        if let err { log("识别：\(err)") }
        if isFinal || err != nil {
            // 你还没点结束，识别器自己停了（停顿太久 / 一句说完）：接着开下一个任务，不把这次录音收尾
            if state == "recording" { restartTask() } else { finish() }
        }
    }

    private func restartTask() {
        segs.commitCurrent()
        quickRestarts = Date().timeIntervalSince(taskStart) < 1.5 ? quickRestarts + 1 : 0
        guard quickRestarts < 3, let recognizer, recognizer.isAvailable else { finish(); return }   // 一开就结束 = 识别器有毛病，别空转
        task?.cancel()
        task = nil
        startTask(recognizer)
        log("识别器自己停了，已接着开始下一段")
    }

    private func cleanup() {
        ctxBefore = ""
        Hub.shared.clearLevels()
        finishTimer?.invalidate()
        autoStop?.invalidate()
        task?.cancel()
        task = nil
        sink.set(nil)
        request = nil
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let ctx = ctxBefore, hints = altHints      // cleanup 会清掉上文，先取走
        cleanup()
        let raw = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let secs = Date().timeIntervalSince(recStart)
        if raw.isEmpty {
            if cutCount > 0 { complete(info: String(format: "录音 %.1f 秒", secs)); return }   // 冻结之后没再说话，前面的字已经在输入框里了
            fail("没听到内容")
            return
        }
        lastRaw = raw
        state = "processing"
        emit(raw)   // 原文先给键盘打进输入框，润色好了再替换掉
        let info = String(format: "录音 %.1f 秒", secs)
        guard polishOn else {
            lastPolished = ""
            complete(info: info)
            return
        }
        guard serviceReady else {
            lastPolished = ""
            complete(info: info + "，没润色（没有服务密钥）", warn: "没润色：这个安装包没带服务密钥，请重新安装最新版")
            return
        }
        let style = self.style, g = gen
        if !hints.isEmpty { log("识别备选：\(hints.joined(separator: "；").prefix(200))") }      // 留个记录：看苹果到底给不给、给的有没有用
        Task {
            var note = info, warn: String?
            do {
                let (t, ms) = try await Server.polish(raw, style: style, context: ctx, hints: hints)
                guard g == gen else { return }      // 等润色时这次录音被作废了（键盘换了输入框）
                lastPolished = t; note += "，润色 \(ms) 毫秒"
                if t != raw { emit(t) }
            } catch {
                guard g == gen else { return }
                lastPolished = ""; note += "，润色失败（\(error.localizedDescription)），用原文"
                warn = "润色没成功，已用原文"
            }
            complete(info: note, warn: warn)
        }
    }

    /// 给键盘一条结果（键盘把输入框里这一段听写替换成它）：先是原文，润色好了再来一条
    private func emit(_ text: String) {
        resultText = text
        resultSID = gen
        resultCuts = cutCount
        rseq += 1
        rtime = Date().timeIntervalSince1970
        publish()
        KB.post(KB.nResult)
    }

    private func complete(info: String, warn: String? = nil) {
        swipeBackHint = false
        errText = warn ?? ""
        errTime = Date().timeIntervalSince1970
        lastInfo = info
        state = "idle"
        partial = ""
        extendKeepalive()
        publish()
        log("完成：\(resultText.prefix(24))", remote: false)
        if keepMin == 0 { stopEngine() }
    }

    private func fail(_ msg: String) {
        swipeBackHint = false
        finished = true
        cleanup()
        errText = msg
        errTime = Date().timeIntervalSince1970
        state = "idle"
        partial = ""
        log(msg)
        if wantEngine { extendKeepalive() }
        publish()
    }
}
