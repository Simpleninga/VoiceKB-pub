import Foundation

/// 键盘这边的通道客户端：主 App 在 127.0.0.1 上开了小服务（见 App/Bridge.swift）。
/// 主 App 没在跑（或被系统冻结）时连不上，`ok` 为 false，调用方就当「App 没待命」。
enum Link {
    struct Snap {
        var ok = false
        var app: [String: Any] = [:]
        var kbd: [String: Any] = [:]
        var hb: TimeInterval = 0
        var levels: [Double] = []
        /// 主 App 的录音引擎多久没跳心跳了（连不上 = 无穷大）
        var beatAge: TimeInterval { ok && hb > 0 ? Date().timeIntervalSince1970 - hb : .infinity }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 0.8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(KB.port)\(path)")! }

    /// 回调在主线程
    static func fetch(_ done: @escaping (Snap) -> Void) {
        session.dataTask(with: url("/s")) { data, _, _ in
            var s = Snap()
            if let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                s.ok = true
                s.app = o["app"] as? [String: Any] ?? [:]
                s.kbd = o["kbd"] as? [String: Any] ?? [:]
                s.hb = o["hb"] as? Double ?? 0
                s.levels = o["lv"] as? [Double] ?? []
            }
            DispatchQueue.main.async { done(s) }
        }.resume()
    }

    static func putKbd(_ d: [String: Any]) {
        var r = URLRequest(url: url("/kbd"))
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: d)
        session.dataTask(with: r) { _, _, _ in }.resume()
    }
}
