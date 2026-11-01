import SwiftUI

/// 主 App 首页：一个语义化的状态卡 + 两个入口行。
/// 设置（SettingsView）、使用说明（HelpView）、诊断（DiagnosticsView）都是独立页面；
/// 首次启动会全屏弹新手引导（OnboardingView）。
/// 键盘（KeyboardViewController）的界面不在这里，那边一行都没改。
struct ContentView: View {
    @ObservedObject var d: Dictation
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("keepMin") private var keepMin = 30
    @AppStorage("polish") private var polish = true
    @AppStorage("style") private var style = "light"
    @State private var showOnboarding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("说话就出字，按住空格也能说")
                }

                Section {
                    NavigationLink {
                        SettingsView(d: d)
                    } label: {
                        entryRow("设置", systemImage: "gearshape", color: Brand.green)
                    }

                    NavigationLink {
                        HelpView(d: d)
                    } label: {
                        entryRow("使用说明", systemImage: "questionmark.circle", color: Color(uiColor: .systemBlue))
                    }
                }
            }
            .navigationTitle("芽音")
            .task {
                d.refreshPerms()
                if !hasOnboarded { showOnboarding = true }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(d: d) { showOnboarding = false }
            }
            .safeAreaInset(edge: .top) { RecordingHintBanner(d: d) }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 状态卡                                                                  */
    /* ---------------------------------------------------------------------- */

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("后台待命")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(standbyTitle)
                            .font(.system(size: 26, weight: .bold))
                        Text(standbySub)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    StandbyRing(progress: standbyProgress, active: d.engineRunning)
                }

                HStack(spacing: 8) {
                    StatusPill(text: d.onDeviceOK ? "识别 · 本机" : "识别 · 苹果云端")
                    StatusPill(text: polish ? (style == "formal" ? "润色 · 书面语" : "润色 · 轻润色") : "润色 · 已关闭")
                }

                if !d.micOK || !d.speechOK {
                    Button {
                        Task { _ = await d.ensurePermissions() }
                    } label: {
                        Text("去授权麦克风和语音识别")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Brand.green)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 大字只说状态（待命中/未待命），不搞秒级倒计时——那是仪表盘，不是产品首页。
    private var standbyTitle: String {
        guard d.engineRunning else { return "未待命" }
        return d.remain < 0 ? "一直待命" : "待命中"
    }

    /// 剩余时间按 5 分钟取整；没待命时才解释机制（上下文相关，只在该状态出现）。
    private var standbySub: String {
        guard d.engineRunning else { return "点键盘麦克风时会先跳回这里，录完自动回去" }
        if d.remain < 0 { return "随时可以直接说话" }
        let mins = d.remain / 60
        if mins < 3 { return "还剩不到 3 分钟" }
        let rounded = Int((Double(mins) / 5).rounded()) * 5
        return "还剩约 \(max(rounded, 5)) 分钟"
    }

    private var standbyProgress: Double {
        guard d.engineRunning else { return 0 }
        if d.remain < 0 { return 1 }
        guard keepMin > 0 else { return 0 }
        return min(1, max(0, Double(d.remain) / Double(keepMin * 60)))
    }

    /* ---------------------------------------------------------------------- */
    /* 入口行                                                                  */
    /* ---------------------------------------------------------------------- */

    private func entryRow(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, color: color)
            Text(title)
        }
    }
}

/* -------------------------------------------------------------------------- */
/* 小组件                                                                      */
/* -------------------------------------------------------------------------- */

private struct StandbyRing: View {
    let progress: Double
    let active: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0.04, progress))
                .stroke(
                    active ? Brand.green : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
            Image(systemName: active ? "waveform" : "mic.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Brand.green : Color.secondary)
        }
        .frame(width: 54, height: 54)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Brand.deep)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Brand.soft)
            .clipShape(Capsule())
    }
}
