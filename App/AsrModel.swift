import CryptoKit
import SwiftUI

/// X-ASR 模型（约 170MB）不进安装包：App 经常发版，每次更新都重下太重。第一次打开时从服务器分片下载，
/// 只走 Wi-Fi，断了下次接着下，装新版不用重下。下载好之前、或者设置里选了苹果，就用苹果识别
@MainActor
final class AsrModel: ObservableObject {
    static let shared = AsrModel()

    private static let id = "x-asr-480-v1"
    private static let files: [(name: String, size: Int, sha256: String)] = [
        ("tokens.txt", 58_806, "b818a60878b9aae978cbb8ad594acbd403d76d1af2e31ef4197c84e2dbdba27c"),
        ("bpe.vocab", 69_594, "28fc94d67aae53d8c58010fcfb16fc8c2f8dd263e03f3490c98210e354e8f914"),
        ("joiner.int8.onnx", 2_581_422, "aedb7fa697b2ab43f20499826fff7c997eea7d67db77be97769aeeeb726e63b3"),
        ("decoder.onnx", 11_309_084, "a1cbc9eac2d5e3fb6617a218c67ad6daaa7f4e0fd225f08b2c22ab0413c8c257"),
        ("encoder.int8.onnx", 155_278_641, "908596dcc137a73b95be908ca55e88caa1b3dbbe8027c171615f4b0609c5eb1e"),
    ]
    private static let chunk = 4 << 20

    @Published private(set) var ready = false
    @Published private(set) var status = "未下载"
    private var running = false

    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("asr/\(AsrModel.id)")

    private var choice: String { UserDefaults.standard.string(forKey: "asrEngine") ?? "xasr" }
    /// 这次说话用不用 X-ASR
    var usable: Bool { ready && choice == "xasr" && !XAsr.shared.gaveUp }

    private init() {
        ready = Self.files.allSatisfy { size(dir.appendingPathComponent($0.name)) == $0.size }
        if ready { status = "已就绪" }
    }

    private func size(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    /// 打开 App、回前台、设置里切到 X-ASR 时调：缺文件就下
    func ensure() {
        guard choice == "xasr", !ready, !running else { return }
        running = true
        Task {
            defer { running = false }
            let t = Date()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var d = dir, v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? d.setResourceValues(v)
                let total = Self.files.reduce(0) { $0 + $1.size }
                var before = 0
                for f in Self.files {
                    try await fetch(f, before: before, total: total)
                    before += f.size
                }
                ready = true
                status = "已就绪"
                Dictation.shared.log(String(format: "X-ASR 模型下载完成，用了 %.0f 秒", Date().timeIntervalSince(t)))
                if Dictation.shared.engineRunning { XAsr.shared.preload(dir: dir) }
            } catch {
                let noWifi = (error as? URLError)?.networkUnavailableReason != nil
                status = noWifi ? "等连上 Wi-Fi 再下载" : "下载中断，下次打开接着下"
                Dictation.shared.log("X-ASR 模型没下完：\(error.localizedDescription)")
            }
        }
    }

    private func fetch(_ f: (name: String, size: Int, sha256: String), before: Int, total: Int) async throws {
        let fm = FileManager.default
        let url = dir.appendingPathComponent(f.name), part = url.appendingPathExtension("part")
        if size(url) == f.size { return }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let h = try FileHandle(forWritingTo: part)
        defer { try? h.close() }
        var off = Int(try h.seekToEnd())      // 文件有多长就下到哪了，这就是断点续传
        while off < f.size {
            let d = try await Server.modelChunk("\(Self.id)/\(f.name)", off: off, len: min(Self.chunk, f.size - off))
            guard !d.isEmpty else { throw Server.Fail(msg: "服务器没给数据") }
            try h.write(contentsOf: d)
            off += d.count
            status = "下载中 \((before + off) * 100 / total)%"
        }
        guard await Self.sha256(part) == f.sha256 else {
            try? fm.removeItem(at: part)
            throw Server.Fail(msg: "\(f.name) 校验没过")
        }
        try fm.moveItem(at: part, to: url)
    }

    private nonisolated static func sha256(_ u: URL) async -> String {
        await Task.detached {
            guard let h = try? FileHandle(forReadingFrom: u) else { return "" }
            defer { try? h.close() }
            var s = SHA256()
            while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { s.update(data: d) }
            return s.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
