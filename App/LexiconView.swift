import SwiftUI

/// 我的词库：服务器上的词和纠错规则。加的词打字和语音都用；规则是「听错 → 正确」，大多是自动学来的，学错了左滑删掉
struct LexiconView: View {
    private struct Rule: Identifiable {
        let id: String, to: String, src: String, hard: Bool
    }

    @State private var words: [(w: String, src: String)] = []
    @State private var rules: [Rule] = []
    @State private var newWord = ""
    @State private var from = ""
    @State private var to = ""
    @State private var note = ""

    private static let srcName = ["me": "手动", "edit": "你改过", "polish": "润色", "mine": "说过的话", "rule": "学到", "trend": "新词"]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("加一个常用词", text: $newWord)
                    Button("添加") { go(["op": "add-word", "word": newWord]) { newWord = "" } }.disabled(newWord.isEmpty)
                }
                HStack {
                    TextField("听错成", text: $from)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("正确的词", text: $to)
                    Button("添加") { go(["op": "add-rule", "from": from, "to": to]) { from = ""; to = "" } }.disabled(from.isEmpty || to.isEmpty)
                }
            } header: {
                Text("添加")
            } footer: {
                if !note.isEmpty { Text(note).foregroundStyle(.red) }
            }

            Section("纠错规则 \(rules.count)") {
                ForEach(rules) { r in
                    HStack {
                        Text("\(r.id) → \(r.to)")
                        Spacer()
                        Text(r.hard ? (Self.srcName[r.src] ?? "") : "待确认").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { i in i.forEach { n in go(["op": "del-rule", "from": rules[n].id]) {} } }
            }

            Section("常用词 \(words.count)") {
                ForEach(words, id: \.w) { x in
                    HStack {
                        Text(x.w)
                        Spacer()
                        Text(Self.srcName[x.src] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { i in i.forEach { n in go(["op": "del-word", "word": words[n].w]) {} } }
            }
        }
        .navigationTitle("我的词库")
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await Server.call("GET", "/kb/v1/lexicon")
            words = (r["words"] as? [[String: Any]] ?? []).compactMap { x in (x["w"] as? String).map { ($0, x["src"] as? String ?? "") } }
            rules = (r["rules"] as? [[String: Any]] ?? []).compactMap { x in
                guard let a = x["from"] as? String, let b = x["to"] as? String else { return nil }
                return Rule(id: a, to: b, src: x["src"] as? String ?? "", hard: x["hard"] as? Bool ?? false)
            }
            note = ""
        } catch {
            note = "取不到词库：\(error.localizedDescription)"
        }
    }

    private func go(_ body: [String: Any], done: @escaping () -> Void) {
        Task {
            do {
                _ = try await Server.call("POST", "/kb/v1/lexicon", body: body)
                done()
                await load()
                Dictation.shared.refreshHot()
            } catch {
                note = "没改成：\(error.localizedDescription)"
            }
        }
    }
}
