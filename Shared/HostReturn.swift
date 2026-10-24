import Foundation

/// 从键盘跳到本 App 录音之后，按宿主 App 的 bundle id 找回去的地址（URL scheme）。
/// 苹果没给键盘「回到上一个 App」的公开接口，只能打开对方的 scheme；没登记的 App 就只能让用户手动划回去。
/// 前半（国外 App）取自开源项目 Dictus（MIT，getdictus/dictus-ios 的 KnownAppSchemes，其中备忘录 / 信息 / 邮件 / WhatsApp / Claude 等是它在真机上验过「回到原来界面」的），
/// 后半（国内 App）是按各家公开的 scheme 写的，没在真机验过：不灵就在日志里看到「跳回失败」，再改。
/// 不放 Safari：能打开它的 scheme 全都会新开空白页、丢掉用户正在看的页面，比手动划回去还糟。
enum HostReturn {
    static let schemes: [String: String] = [
        // 苹果自带（Dictus 真机验过）
        "com.apple.mobilenotes": "mobilenotes://",
        "com.apple.MobileSMS": "ichat://",           // 不能用 sms://，那个会跳到「新信息」
        "com.apple.mobilemail": "message://",
        "com.apple.reminders": "x-apple-reminderkit://",
        "com.apple.Pages": "pages://",
        "com.apple.Numbers": "numbers://",
        "com.apple.Keynote": "keynote://",
        // 国外常见
        "net.whatsapp.WhatsApp": "whatsapp-consumer://",
        "com.telegram.telegram-ios": "tg://",
        "ph.telegra.Telegraph": "tg://",
        "com.tinyspeck.chatlyio": "slack://open",
        "com.anthropic.claude": "claude://",
        "com.openai.chat": "com.openai.chat://",
        "com.google.chrome.ios": "googlechrome://",
        "com.microsoft.Office.Word": "ms-word://",
        "com.microsoft.Office.Outlook": "ms-outlook://",
        "com.microsoft.skype.teams": "msteams://",
        "md.obsidian": "obsidian://",
        "com.facebook.Messenger": "fb-messenger://",
        "com.atebits.Tweetie2": "twitter://",
        "com.burbn.instagram": "instagram://",
        "com.evernote.iPhone.Evernote": "evernote://",
        // 自家 App：小芽（1.19 起注册了 xiaoya://；SideStore 签名后 bundle id 带 .团队号，下面 canonical 会去掉）
        "com.esplink.remote": "xiaoya://",
        // 国内（没在真机验过）
        "com.tencent.xin": "weixin://",              // 微信（Dictus 列为真机验过）
        "com.tencent.ww": "wxwork://",               // 企业微信
        "com.tencent.mqq": "mqq://",                 // QQ
        "com.laiwang.DingTalk": "dingtalk://",       // 钉钉
        "com.bytedance.ee.lark": "feishu://",        // 飞书
        "com.alipay.iphoneclient": "alipay://",
        "com.xingin.discover": "xhsdiscover://",     // 小红书
        "com.ss.iphone.ugc.Aweme": "snssdk1128://",  // 抖音
        "com.sina.weibo": "sinaweibo://",
        "com.taobao.taobao4iphone": "taobao://",
        "com.meituan.imeituan": "imeituan://",
        "com.zhihu.ios": "zhihu://",
        "tv.danmaku.bilianime": "bilibili://",
        "com.baidu.BaiduMobile": "baiduboxapp://",
    ]

    /// SideStore / Sideloadly 签名后的 App，bundle id 末尾会多一段团队号（com.esplink.remote.ABCDE12345）：去掉它再查表
    static func canonical(_ bundleId: String) -> String {
        let parts = bundleId.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 3, let last = parts.last, last.count == 10, last.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }) {
            return parts.dropLast().joined(separator: ".")
        }
        return bundleId
    }

    static func url(for bundleId: String) -> URL? {
        (schemes[bundleId] ?? schemes[canonical(bundleId)]).flatMap(URL.init(string:))
    }

    /// 认不出 bundle id 时的备用办法：按宿主进程的可执行文件路径里的 App 目录名找（/…/WeChat.app/WeChat）。
    /// 能不能读到别的 App 的路径要真机试；目录名对不对也要真机看日志，不灵就在日志里补
    static let byAppDir: [String: String] = [
        "WeChat": "weixin://", "WXWork": "wxwork://", "wxwork": "wxwork://", "QQ": "mqq://", "DingTalk": "dingtalk://", "Lark": "feishu://",
        "MobileNotes": "mobilenotes://", "MobileSMS": "ichat://", "MobileMail": "message://", "Reminders": "x-apple-reminderkit://",
        "Claude": "claude://", "Telegram": "tg://", "XiaoHongShu": "xhsdiscover://", "discover": "xhsdiscover://", "Weibo": "sinaweibo://",
        "Aweme": "snssdk1128://", "Alipay": "alipay://", "ZhihuHybrid": "zhihu://", "BiliApp": "bilibili://",
    ]

    /// 进程名（可执行文件名，WeChat / QQ …）直接查
    static func url(forName name: String) -> URL? {
        byAppDir[name].flatMap(URL.init(string:))
    }

    static func url(forPath path: String) -> URL? {
        guard let dir = path.split(separator: "/").last(where: { $0.hasSuffix(".app") }) else { return nil }
        return byAppDir[String(dir.dropLast(4))].flatMap(URL.init(string:))
    }
}
