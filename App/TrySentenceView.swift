import SwiftUI

/// 「试一句」：验证整条链路（录音 → 识别 → 润色）。
/// 不放首页（那是 demo 感的来源），放在使用说明页和新手引导里。
struct TrySentenceView: View {
    @ObservedObject var d: Dictation
    @State private var testText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("在这里打字，或者直接说一句", text: $testText, axis: .vertical)
                .lineLimit(3...6)
                .font(.body)
                .padding(12)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(action: toggleRecord) {
                HStack(spacing: 8) {
                    Image(systemName: d.state == "recording" ? "stop.fill" : "mic.fill")
                    Text(recordTitle).font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(d.state == "recording" ? Color.red : Brand.green)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(d.state == "processing")
            .opacity(d.state == "processing" ? 0.5 : 1)

            if d.state != "idle" {
                HStack(spacing: 8) {
                    ProgressView()
                    Text((d.state == "recording" ? "录音中… " : "处理中… ") + d.partial)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !d.lastRaw.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("原文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(d.lastRaw)
                        .font(.callout)
                    if !d.lastPolished.isEmpty {
                        Text("润色")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        Text(d.lastPolished)
                            .font(.callout)
                            .foregroundStyle(Brand.deep)
                    }
                    Text(d.lastInfo)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Brand.soft)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var recordTitle: String {
        switch d.state {
        case "recording": return "结束并识别"
        case "processing": return "处理中…"
        default: return "说一句试试"
        }
    }

    private func toggleRecord() {
        if d.state == "recording" {
            d.stopRecording()
        } else {
            d.startRecording()
        }
    }
}
