import SwiftUI

/// 设置页：系统 Form 形态（分组列表 + 彩色图标 + 开关）。
/// 所有 @AppStorage 的 key 跟旧版首页完全一致，老用户的设置原样保留。
struct SettingsView: View {
    @ObservedObject var d: Dictation
    @AppStorage("keepMin") private var keepMin = 30
    @AppStorage("onDevice") private var onDevice = false
    @AppStorage("polish") private var polish = true
    @AppStorage("style") private var style = "light"
    @State private var serviceMsg = "检查中…"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "waveform", color: Brand.green)
                    Picker("后台待命时长", selection: $keepMin) {
                        Text("不待命").tag(0)
                        Text("5 分钟").tag(5)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                        Text("一直开").tag(-1)
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: 12) {
                    IconBadge(systemImage: "cpu", color: Color(uiColor: .systemTeal))
                    Toggle("只用本机识别", isOn: $onDevice)
                }
            } header: {
                Text("语音")
            } footer: {
                Text(d.onDeviceOK ? "离线识别，声音不出手机" : "这台设备不支持，会走苹果云端")
            }

            Section {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "sparkles", color: Color(uiColor: .systemPurple))
                    Toggle("说完润色", isOn: $polish)
                }

                if polish {
                    Picker("润色风格", selection: $style) {
                        Text("轻润色").tag("light")
                        Text("书面语").tag("formal")
                    }
                    .pickerStyle(.menu)

                    LabeledContent {
                        Text(serviceMsg)
                            .foregroundStyle(serviceMsg == "正常" ? Brand.deep : Color.secondary)
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(systemImage: "server.rack", color: Color(uiColor: .systemOrange))
                            Text("润色服务")
                        }
                    }
                }
            } header: {
                Text("润色")
            } footer: {
                Text("补标点、去口癖，约 1~2 秒")
            }

            Section {
                LabeledContent("版本", value: version)

                NavigationLink {
                    DiagnosticsView(d: d)
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "stethoscope", color: Color(uiColor: .systemRed))
                        Text("诊断")
                    }
                }
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
        .task { serviceMsg = await Server.check() ?? "正常" }
    }

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1")
    }
}
