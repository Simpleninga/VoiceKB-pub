import SwiftUI

/// 诊断页：排障用的状态键值行 + 日志。从 设置 → 关于 → 诊断 进来，不占首页。
struct DiagnosticsView: View {
    @ObservedObject var d: Dictation

    var body: some View {
        List {
            Section("状态") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("键盘通道", value: Bridge.shared.statusText)
                }
                LabeledContent("麦克风权限", value: d.micOK ? "已授权" : "未授权")
                LabeledContent("语音识别权限", value: d.speechOK ? "已授权" : "未授权")
                LabeledContent("本机中文识别", value: d.onDeviceOK ? "支持" : "不支持")
                LabeledContent("待命剩余", value: remainText)
            }

            if !d.logLines.isEmpty {
                Section("日志") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(d.logLines.suffix(60), id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 160)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("诊断")
    }

    private var remainText: String {
        guard d.engineRunning else { return "未待命" }
        if d.remain < 0 { return "一直开" }
        let mins = d.remain / 60
        return mins < 3 ? "不到 3 分钟" : "约 \(mins) 分钟"
    }
}
