import SwiftUI

/// 首次启动引导：授权 → 装键盘 → 试一句，三步。
/// 老用户升级也会看到一次（hasOnboarded 默认 false），右上角随时可跳过。
struct OnboardingView: View {
    @ObservedObject var d: Dictation
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @State private var step = 0
    let onDone: () -> Void

    private var granted: Bool { d.micOK && d.speechOK }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("第 \(step + 1) 步 · 共 3 步")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.deep)
                Spacer()
                Button("跳过") { done() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: permissionStep
                    case 1: keyboardStep
                    default: tryStep
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(action: primaryAction) {
                Text(primaryTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Brand.green)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .top) { RecordingHintBanner(d: d) }
    }

    /* 第 1 步：授权 */

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            iconCircle("mic.fill")
            Text("先授权麦克风")
                .font(.system(size: 24, weight: .bold))
            Text("授权后键盘才能直接调用麦克风，不用每次跳回本 App。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permRow("麦克风", ok: d.micOK)
                permRow("语音识别", ok: d.speechOK)
            }
        }
    }

    private func permRow(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Brand.green : Color.secondary)
            Text("\(name) · \(ok ? "已授权" : "未授权")")
                .font(.subheadline)
        }
    }

    /* 第 2 步：装键盘 */

    private var keyboardStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            iconCircle("keyboard")
            Text("把芽音加进键盘")
                .font(.system(size: 24, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                StepRow(index: 1, text: "设置 → 通用 → 键盘 → 添加「芽音」，点进去打开「允许完全访问」")
                StepRow(index: 2, text: "任意输入框里长按 🌐 切到芽音")
            }
        }
    }

    /* 第 3 步：试一句 */

    private var tryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            iconCircle("waveform")
            Text("试一句")
                .font(.system(size: 24, weight: .bold))
            Text("对着手机说一句，看看上屏和润色。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Card {
                TrySentenceView(d: d)
            }
        }
    }

    /* 底部主按钮 */

    private var primaryTitle: String {
        switch step {
        case 0: return granted ? "下一步" : "授权麦克风和语音识别"
        case 1: return "下一步"
        default: return "完成"
        }
    }

    private func primaryAction() {
        switch step {
        case 0:
            if granted { step = 1 } else { Task { _ = await d.ensurePermissions() } }
        case 1:
            step = 2
        default:
            done()
        }
    }

    private func done() {
        hasOnboarded = true
        onDone()
    }

    private func iconCircle(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 80)
            .background(Brand.green)
            .clipShape(Circle())
    }
}
