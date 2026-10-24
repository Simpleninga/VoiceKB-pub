import Foundation

/// 主 App 和键盘扩展共用：端口号、Darwin 通知名。
/// 内容走本机回环 HTTP（主 App 端 App/Bridge.swift，键盘端 Keyboard/Link.swift）；Darwin 通知只负责叫醒对方、不带内容。
/// 不用 App Group：SideStore 免费签名下拿不到（2026-10-22 实测「App Group 不可用」）。
enum KB {
    static let port: UInt16 = 47821
    static let nState = "com.simpleninga.voicekb.state"
    static let nResult = "com.simpleninga.voicekb.result"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// 监听 Darwin 通知（跨进程）。回调可能不在主线程。
final class DarwinListener {
    private let handler: () -> Void

    init(_ name: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), me, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<DarwinListener>.fromOpaque(observer).takeUnretainedValue().handler()
        }, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
