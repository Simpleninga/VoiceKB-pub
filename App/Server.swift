import Foundation

/// 语音键盘自己的服务（润色、日志）：不用任何账号。服务密钥和服务器地址都不写在源码里，发版时由发版脚本塞进安装包主 App 的 Info.plist（VoiceKBKey / VoiceKBHosts）。
/// 服务端是独立的 voicekb-server；地址按顺序试，前一个不通再试下一个。
enum Server {
    static var hosts: [String] {
        Bundle.main.object(forInfoDictionaryKey: "VoiceKBHosts") as? [String] ?? []
    }

    struct Fail: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    /// 服务密钥：安装包里带的；没有就用设置页里手填的（一般用不到）
    static var key: String {
        let built = (Bundle.main.object(forInfoDictionaryKey: "VoiceKBKey") as? String ?? "").trimmingCharacters(in: .whitespaces)
        if !built.isEmpty && !built.hasPrefix("$(") { return built }
        return (UserDefaults.standard.string(forKey: "serviceKey") ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func call(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 8) async throws -> [String: Any] {
        let k = key
        guard !k.isEmpty else { throw Fail(msg: "安装包里没有服务密钥") }
        var lastErr: Error = Fail(msg: "连不上服务器")
        for h in hosts {
            guard let url = URL(string: "http://\(h)\(path)?key=\(k)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = method
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
                    throw Fail(msg: (obj["error"] as? String) ?? "服务器返回 \(code)")
                }
                return obj
            } catch let e as Fail {
                throw e
            } catch {
                lastErr = error
            }
        }
        throw lastErr
    }

    /// 返回（润色后的文字，服务器上花的毫秒）。润色要 2 秒左右，超时放宽到 25 秒
    /// context = 输入框里光标前的字（只给服务器判断语境，不会被改写）；hints = 识别器对没把握的词给的备选（「词→候选/候选」）
    static func polish(_ text: String, style: String, context: String = "", hints: [String] = []) async throws -> (String, Int) {
        var body: [String: Any] = ["text": text, "style": style]
        if !context.isEmpty { body["context"] = context }
        if !hints.isEmpty { body["hints"] = hints }
        let r = try await call("POST", "/kb/v1/polish", body: body, timeout: 25)
        guard let t = r["text"] as? String else { throw Fail(msg: (r["error"] as? String) ?? "润色失败") }
        return (t, r["ms"] as? Int ?? 0)
    }

    /// 开始录音时通知服务器：先把润色用的进程起好，说完润色省掉启动的约 1 秒；失败不影响
    static func warm(style: String) async {
        _ = try? await call("POST", "/kb/v1/warm", body: ["style": style], timeout: 5)
    }

    /// 一行日志传到服务器（出了问题我在服务器上直接看，不用你截图）；传不上也不管
    static func sendLog(_ line: String) async {
        _ = try? await call("POST", "/kb/v1/log", body: ["line": line], timeout: 5)
    }

    /// 设置页上显示「润色服务」是不是通的：nil = 通；否则是原因
    static func check() async -> String? {
        do {
            _ = try await call("GET", "/kb/v1/ping", timeout: 6)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
