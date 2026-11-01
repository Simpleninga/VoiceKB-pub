import SwiftUI

/// 使用说明页：上手四步 + 试一句。机制说明的文案（跳回、横条右滑）都收在这，不占首页。
struct HelpView: View {
    @ObservedObject var d: Dictation

    var body: some View {
        List {
            Section {
                StepRow(index: 1, text: "设置 → 通用 → 键盘 → 添加「芽音」，点进去打开「允许完全访问」")
                StepRow(index: 2, text: "任意输入框里长按 🌐 切到芽音")
                StepRow(index: 3, text: "点键盘左上角麦克风说话，再点一下结束；或者按住空格说、松手结束。字会实时上屏，润色好了自动替换")
                StepRow(index: 4, text: "打字：「中英」切中英文，「123」切符号，「，。」点逗号、上滑句号；键盘顶栏齿轮里可换九键、开关震动")
            } header: {
                Text("上手四步")
            } footer: {
                Text("第一次用会先跳回本 App 录音，录完自动跳回；跳不回就从屏幕底部横条向右滑。")
            }

            Section("试一句") {
                TrySentenceView(d: d)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }
        }
        .navigationTitle("使用说明")
        .scrollDismissesKeyboard(.interactively)
    }
}

/// 序号步骤行：使用说明页和新手引导共用。
struct StepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.deep)
                .frame(width: 18, height: 18)
                .background(Brand.soft)
                .clipShape(Circle())
                .padding(.top, 1)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
