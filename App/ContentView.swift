import SwiftUI

struct ContentView: View {
    @ObservedObject var d: Dictation
    @AppStorage("keepMin") private var keepMin = 30
    @AppStorage("onDevice") private var onDevice = false
    @AppStorage("polish") private var polish = true
    @AppStorage("style") private var style = "light"
    @State private var serviceMsg = "检查中…"
    @State private var testText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("状态") {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in row("键盘通道（本机）", Bridge.shared.statusText) }
                    row("麦克风权限", d.micOK ? "已授权" : "未授权")
                    row("语音识别权限", d.speechOK ? "已授权" : "未授权")
                    row("本机中文识别", d.onDeviceOK ? "支持" : "不支持（走苹果云端）")
                    row("后台待命", d.engineRunning ? remainText : "未待命（点键盘麦克风会先跳到本 App）")
                    if !d.speechOK || !d.micOK {
                        Button("授权麦克风和语音识别") { Task { _ = await d.ensurePermissions() } }
                    }
                }

                Section("怎么用") {
                    Text("1. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 芽音，点进去打开「允许完全访问」\n2. 到任意输入框，长按 🌐 切到「芽音」\n3. 打字：键盘上的「中英」键切中文和英文，「123」切数字符号，「，。」点一下是逗号、上滑是句号；键盘顶栏的齿轮里可以换成拼音九键、开关按键震动\n4. 说话：点键盘左上角的绿色麦克风说，再点一下结束；或者直接按住空格说、松手结束。说的时候有声波，字会实时打进去，润色好了自动替换；说到一半动手改了输入框也没关系，后面说的会接着打在光标处\n5. 第一次要先跳到本 App 录音，会自动跳回；跳不回就按提示从屏幕底部向右划")
                        .font(.footnote)
                }

                Section("设置") {
                    Picker("后台待命时长", selection: $keepMin) {
                        Text("不待命（每次都跳转）").tag(0)
                        Text("5 分钟").tag(5)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                        Text("一直开").tag(-1)
                    }
                    Toggle("只用本机识别（离线）", isOn: $onDevice)
                    Toggle("说完后让 Claude 润色（约 1~2 秒）", isOn: $polish)
                    if polish {
                        Picker("润色风格", selection: $style) {
                            Text("轻润色：去口癖、补标点").tag("light")
                            Text("书面语：更通顺").tag("formal")
                        }
                        row("润色服务", serviceMsg)
                    }
                }

                Section("试一试（不用键盘也能测）") {
                    TextField("这里可以试键盘，也可以看识别结果", text: $testText, axis: .vertical)
                        .lineLimit(3...6)
                    Button(d.state == "recording" ? "停止" : "在本 App 里说一句") {
                        if d.state == "recording" {
                            d.stopRecording()
                        } else {
                            d.startRecording()
                        }
                    }
                    .disabled(d.state == "processing")
                    if d.state != "idle" {
                        Text((d.state == "recording" ? "录音中… " : "处理中… ") + d.partial).font(.footnote)
                    }
                    if !d.lastRaw.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原文：\(d.lastRaw)")
                            if !d.lastPolished.isEmpty { Text("润色：\(d.lastPolished)") }
                            Text(d.lastInfo).foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                }

                Section("日志") {
                    ForEach(d.logLines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                }
            }
            .navigationTitle("芽音")
            .onAppear { d.refreshPerms() }
            .task { serviceMsg = await Server.check() ?? "正常" }
            .safeAreaInset(edge: .top) {
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
    }

    private var remainText: String {
        d.remain < 0 ? "待命中（一直开）" : "待命中，还剩 \(d.remain / 60) 分 \(d.remain % 60) 秒"
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
