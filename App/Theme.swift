import SwiftUI

/// 芽音的品牌色。键盘那边用的是 UIColor（KeyboardViewController 里的 green / deep / lightGreen），
/// 这里给主 App 一份对应的 SwiftUI 版本，两边的绿保持同一个值。
enum Brand {
    /// #16985E，跟键盘麦克风同一个绿
    static let green = Color(light: 0x16985E, dark: 0x4CC98A)
    /// 浅绿底：胶囊、选中态背景
    static let soft = Color(light: 0xE7F4EC, dark: 0x14301F)
    /// 深绿：按压、强调文字
    static let deep = Color(light: 0x0F7448, dark: 0x6FDB9F)
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    /// 跟随深浅色的颜色：亮色用 light，暗色用 dark。
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }
}

/// 统一的卡片容器：白底、18 圆角、无阴影。
struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 列表行前面的彩色小图标（28×28 圆角方块 + 白色 SF Symbol），
/// 仿 iOS 系统设置的行图标，首页入口行和设置页共用。
struct IconBadge: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 录音时自动跳回失败的手动返回提示。挂在首页和引导页顶部：
/// 键盘拉起 App 录音时用户可能停在任意一页（包括引导 cover），横幅哪都得看得见。
struct RecordingHintBanner: View {
    @ObservedObject var d: Dictation

    @ViewBuilder
    var body: some View {
        if d.swipeBackHint && d.state == "recording" {
            VStack(spacing: 4) {
                Text("正在录音，请回到刚才的 App").font(.headline)
                Text("从屏幕最底部的横条向右滑，回去接着说话").font(.subheadline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.red)
        }
    }
}
