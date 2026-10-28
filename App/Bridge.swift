import Foundation
import Network

/// 主 App 这边的内存状态（App 退出就没了），键盘通过 Bridge 来取 / 来写。
///   app  主 App 写：state / partial / result / rseq / rtime / err / errtime / keepUntil
///   kbd  键盘写：cmd / cseq / dseq（键盘已经插入到哪一条结果）
///   hb   主 App 的录音引擎活着时每秒写一次时间戳（键盘靠它判断 App 还在不在后台待命）
///   lv   录音时最近的音量（键盘画声波）
final class Hub: @unchecked Sendable {
    static let shared = Hub()
    private let lock = NSLock()
    private var _app: [String: Any] = [:]
    private var _kbd: [String: Any] = [:]
    private var _hb: TimeInterval = 0
    private var _levels: [Double] = []

    var app: [String: Any] { get { lock.withLock { _app } } set { lock.withLock { _app = newValue } } }
    var kbd: [String: Any] { get { lock.withLock { _kbd } } set { lock.withLock { _kbd = newValue } } }
    var hb: TimeInterval { get { lock.withLock { _hb } } set { lock.withLock { _hb = newValue } } }

    /// 最近一小段时间的音量（0~1，新的在后面），键盘用它画声波
    var levels: [Double] { lock.withLock { _levels } }

    func push(levels new: [Double]) {
        lock.withLock { _levels = Array((_levels + new).suffix(48)) }
    }

    func clearLevels() { lock.withLock { _levels = [] } }
}

/// 只准成功一次的开关（verify 里连接成功、失败、超时三条路谁先到算谁）
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// 键盘 ↔ 主 App 的通道：免费签名拿不到 App Group，所以主 App 在本机回环地址 127.0.0.1 上开一个极小的 HTTP 服务，
/// 键盘（用户开了「允许完全访问」才有网络）来取状态、递指令。App 被系统冻结或退出时连不上，键盘就当「没待命」。
///   GET  /s    → {"app": …, "kbd": …, "hb": …, "lv": …}
///   POST /kbd  ← 键盘写的 JSON（整个替换），写完立刻通知 onKbd
final class Bridge: @unchecked Sendable {
    static let shared = Bridge()
    private let queue = DispatchQueue(label: "voicekb.bridge")
    private let lock = NSLock()
    private var listener: NWListener?
    private var _ready = false
    private var _lastHit: Date?
    private var lastStart: Date?          // 只在 queue 里读写
    var onKbd: (() -> Void)?

    private var ready: Bool { get { lock.withLock { _ready } } set { lock.withLock { _ready = newValue } } }
    private var lastHit: Date? { get { lock.withLock { _lastHit } } set { lock.withLock { _lastHit = newValue } } }

    /// 给主界面「状态」一栏看的
    var statusText: String {
        guard ready else { return "未启动 ✗" }
        guard let t = lastHit else { return "监听中，键盘还没连过" }
        return "监听中，键盘 \(Int(Date().timeIntervalSince(t))) 秒前连过"
    }

    /// 已经在监听就什么也不做；回到前台、监听挂了时再调一次就能补上。force = 不管状态强制重建（verify 发现监听其实不通时用）
    func start(force: Bool = false) {
        queue.async { [self] in
            if force, let t = lastStart, Date().timeIntervalSince(t) < 2 { return }      // 刚重建过，别来回折腾
            if ready && !force { return }
            lastStart = Date()
            listener?.cancel()
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: KB.port)!)
            guard let l = try? NWListener(using: params) else { return }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                guard let self, let l, self.listener === l else { return }   // 旧监听的回调不管
                switch st {
                case .ready: self.ready = true
                case .failed, .cancelled:
                    self.ready = false
                    self.listener = nil
                    self.queue.asyncAfter(deadline: .now() + 1) { self.start() }
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        }
    }

    /// 自己连一下自己的监听。App 被系统冻结又唤醒以后，监听可能已被悄悄收走、状态却还显示「就绪」，start() 就以为没事——
    /// 键盘连不上、判成「主 App 没起来」，只有划掉重开才好（10-28 16:17、16:29 日志）。连不通就强制重建；done(false) = 刚重建过
    func verify(_ done: (@Sendable (Bool) -> Void)? = nil) {
        guard let port = NWEndpoint.Port(rawValue: KB.port) else { return }
        let c = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let once = Once()
        let finish: @Sendable (Bool) -> Void = { [weak self] ok in
            guard once.first() else { return }
            c.cancel()
            if !ok { self?.start(force: true) }
            done?(ok)
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .ready:
                c.send(content: Data("GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                c.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in finish(!(data ?? Data()).isEmpty) }
            case .failed, .waiting: finish(false)
            default: break
            }
        }
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { c.cancel(); return }
            var b = buf
            if let data { b.append(data) }
            if let (method, path, body) = Self.parse(b) { self.reply(c, method, path, body); return }
            if done || err != nil || b.count > 1_000_000 { c.cancel(); return }
            self.read(c, b)
        }
    }

    /// 请求头 + 正文收齐了才返回
    private static func parse(_ d: Data) -> (String, String, Data)? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: d[..<r.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var len = 0
        for l in lines.dropFirst() where l.lowercased().hasPrefix("content-length:") {
            len = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = d[r.upperBound...]
        guard body.count >= len else { return nil }
        return (String(first[0]), String(first[1]), Data(body.prefix(len)))
    }

    private func reply(_ c: NWConnection, _ method: String, _ path: String, _ body: Data) {
        if path != "/ping" { lastHit = Date() }      // /ping 是 App 自己查自己，不算键盘连过
        var status = "200 OK"
        var obj: [String: Any] = ["ok": 1]
        switch (method, path) {
        case ("GET", "/ping"):
            break
        case ("GET", "/s"):
            obj = ["app": Hub.shared.app, "kbd": Hub.shared.kbd, "hb": Hub.shared.hb, "lv": Hub.shared.levels]
        case ("POST", "/kbd"):
            if let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                Hub.shared.kbd = o
                onKbd?()
            } else {
                status = "400 Bad Request"
            }
        default:
            status = "404 Not Found"
        }
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(json)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
