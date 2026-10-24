import XCTest
import UIKit

/// 键盘冒烟测试（CI 在 iOS 模拟器里跑）：把键盘真的加载一遍、排版、点几个键。
/// 起因：2026-10-23 的 1.8 版有一处约束在按键还没放进界面时就激活，UIKit 抛异常，键盘一加载就崩、系统自动切回自带键盘；
/// 这种错编译器查不出来，只有真的加载一次才暴露。
@MainActor
final class KeyboardSmokeTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        for k in ["zh", "nine", "haptic", "voiceOwner", "leftSID", "claimTicket", "learn"] { UserDefaults.standard.removeObject(forKey: k) }
        // 个人学习存到临时文件，每个测试从空的开始（不然前面测试选过的词会改变后面测试的候选顺序）
        KeyboardViewController.userFile = FileManager.default.temporaryDirectory.appendingPathComponent("kbtest-user.txt")
        try? FileManager.default.removeItem(at: KeyboardViewController.userFile)
    }

    override func tearDown() {
        for k in ["zh", "nine", "haptic", "outbox", "voiceOwner", "leftSID", "claimTicket", "learn"] { UserDefaults.standard.removeObject(forKey: k) }
        try? FileManager.default.removeItem(at: KeyboardViewController.userFile)
        super.tearDown()
    }

    private static let docA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private static let docB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func tapID(_ vc: KeyboardViewController, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let k = keys(vc).first(where: { $0.accessibilityIdentifier == id }) else {
            XCTFail("找不到按键 \(id)", file: file, line: line)
            return
        }
        k.sendActions(for: .touchDown)
        vc.view.layoutIfNeeded()
    }

    private func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { all($0) } }

    /// pid = 假宿主 App 的进程号（不同 App 的键盘进程号不同）；initiator = 这个键盘发起过录音（留了认领票）
    private func makeKeyboard(pid: Int? = nil, initiator: Bool = true) -> KeyboardViewController {
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let vc = KeyboardViewController()
        w.rootViewController = vc
        w.makeKeyAndVisible()
        vc.view.frame = CGRect(x: 0, y: 844 - KeyboardViewController.keyboardHeight, width: 390, height: KeyboardViewController.keyboardHeight)
        vc.contextProbe = { [unowned vc] in vc.live.isEmpty ? nil : vc.live }     // 假宿主：输入框里就是刚打进去的那段听写
        vc.docProbe = { Self.docA }                                                // 假宿主：始终是同一个输入框
        vc.syncEngine = true                                                       // 按完键马上看候选（真机上候选在后台算，几毫秒后到）
        vc.suppressRealOpen = true                                                 // 测试宿主就是主 App 自己，别真的去打开它
        vc.dismissAction = {}                                                      // 没有宿主可收起
        vc.pidProbe = { pid }
        vc.viewWillAppear(false)
        if initiator { vc.expectOwnRecording() }
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        window = w
        return vc
    }

    private func keys(_ vc: KeyboardViewController) -> [KeyButton] { all(vc.view).compactMap { $0 as? KeyButton } }

    private func modeKey(_ vc: KeyboardViewController) -> KeyButton? { keys(vc).first(where: { $0.accessibilityIdentifier == "mode" }) }

    private func button(_ vc: KeyboardViewController, _ id: String) -> UIButton? {
        all(vc.view).compactMap { $0 as? UIButton }.first(where: { $0.accessibilityIdentifier == id })
    }

    private func tap(_ vc: KeyboardViewController, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let k = keys(vc).first(where: { $0.currentTitle == title }) else {
            XCTFail("找不到按键「\(title)」", file: file, line: line)
            return
        }
        k.sendActions(for: .touchDown)
        vc.view.layoutIfNeeded()
    }

    func testLayoutHasKeysWithSaneSize() {
        let vc = makeKeyboard()
        let ks = keys(vc)
        XCTAssertGreaterThanOrEqual(ks.count, 30, "字母 26 + 功能键")
        for k in ks {
            let f = k.convert(k.bounds, to: vc.view)
            XCTAssertGreaterThan(f.width, 10, "\(k.currentTitle ?? "?") 太窄")
            XCTAssertGreaterThan(f.height, 20, "\(k.currentTitle ?? "?") 太矮")
            XCTAssertLessThanOrEqual(f.maxX, 390.5)
            XCTAssertLessThanOrEqual(f.maxY, KeyboardViewController.keyboardHeight + 0.5)
        }
    }

    /// 仿豆包：字母键又高又大（按错的概率小），最下面一排（123 / 中英 / 空格）矮一点
    func testLetterKeysBigBottomRowShort() {
        let vc = makeKeyboard()
        guard let q = keys(vc).first(where: { $0.currentTitle == "q" }), let a = keys(vc).first(where: { $0.currentTitle == "a" }),
              let m = keys(vc).first(where: { $0.currentTitle == "m" }), let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }) else {
            return XCTFail("找不到 q / a / m / 空格")
        }
        for k in [q, a, m] { XCTAssertGreaterThanOrEqual(k.bounds.height, 47, "字母键要够高：\(k.bounds)") }
        XCTAssertLessThanOrEqual(q.bounds.height, 52, "太高显得窄、更不好按（用户 10-23 反馈）：\(q.bounds)")
        XCTAssertLessThanOrEqual(space.bounds.height, 44, "底排要矮：\(space.bounds)")
        XCTAssertGreaterThan(q.bounds.height, space.bounds.height + 5)
        XCTAssertGreaterThanOrEqual(q.bounds.width, 35.5, "字母键要宽：\(q.bounds)")
        XCTAssertGreaterThan(q.bounds.width / q.bounds.height, 0.7, "不能又高又窄：\(q.bounds)")
        let qf = q.convert(q.bounds, to: vc.view), af = a.convert(a.bounds, to: vc.view)
        XCTAssertLessThanOrEqual(af.minY - qf.maxY, 8, "排与排之间的缝要小")
    }

    /// 拼音打错了也要联想到：zhidoa（o a 写反）→ 知道；nihoa → 你好；womne → 我们
    func testTypoCorrection() {
        for (typed, want) in [("zhidoa", "知道"), ("nihoa", "你好"), ("womne", "我们")] {
            let vc = makeKeyboard()
            for c in typed.map({ String($0) }) { tap(vc, c) }
            let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
            XCTAssertTrue(titles.contains(want), "\(typed) 应该纠错联想出「\(want)」，实际：\(titles.prefix(20))")
        }
    }

    /// 网络用语 / 专有名词要打得出来：tianhu → 天胡，qiagefan → 恰个饭，yihuantong → 医患通
    func testSlangWordsTypeable() {
        for (typed, want) in [("tianhu", "天胡"), ("qiagefan", "恰个饭"), ("yihuantong", "医患通")] {
            let vc = makeKeyboard()
            for c in typed.map({ String($0) }) { tap(vc, c) }
            let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
            XCTAssertTrue(titles.contains(want), "\(typed) 应该打得出「\(want)」，实际：\(titles.prefix(20))")
        }
    }

    /// 整句里打错一个键（mashang 漏了 s）：后台纠成「我马上就到」，但拼音行只显示用户打的字母，不改字母、不标记
    func testSentenceTypoKeepsTypedPinyin() {
        let vc = makeKeyboard()
        for c in "womahangjiudao".map({ String($0) }) { tap(vc, c) }
        let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
        XCTAssertTrue(titles.contains("我马上就到"), "womahangjiudao 应该纠成「我马上就到」，实际：\(titles.prefix(20))")
        let comp = all(vc.view).compactMap { $0 as? UILabel }.first(where: { $0.accessibilityIdentifier == "comp" && !$0.isHidden })
        XCTAssertEqual(comp?.text, "wo ma hang jiu dao", "拼音行显示用户打的字母")
    }

    private func candButtons(_ vc: KeyboardViewController) -> [UIButton] {
        all(vc.view).compactMap { $0 as? UIButton }.filter { !($0 is KeyButton) && $0.superview is UIStackView && !$0.isHidden && $0.currentTitle != nil }
    }

    private func pickTitle(_ vc: KeyboardViewController, _ t: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let b = candButtons(vc).first(where: { $0.currentTitle == t }) else {
            XCTFail("候选里没有「\(t)」：\(candButtons(vc).compactMap { $0.currentTitle }.prefix(12))", file: file, line: line)
            return
        }
        b.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
    }

    /// 个人学习：分两次选出「云朵」+「糕」→ 记成自造词，再打 yunduogao 第一个就是「云朵糕」；存到文件、新键盘实例也认；清空后就没了
    func testLearnsPhraseFromTwoPicks() {
        let vc = makeKeyboard()
        for c in "yunduogao".map({ String($0) }) { tap(vc, c) }
        XCTAssertNotEqual(candButtons(vc).first?.currentTitle, "云朵糕")
        pickTitle(vc, "云朵")
        pickTitle(vc, "糕")
        XCTAssertTrue(vc.buffer.isEmpty)
        for c in "yunduogao".map({ String($0) }) { tap(vc, c) }
        XCTAssertEqual(candButtons(vc).first?.currentTitle, "云朵糕", "选过一次的词组下次排第一")
        vc.viewDidDisappear(false)                 // 收起键盘时存盘
        let vc2 = makeKeyboard()
        for c in "yunduogao".map({ String($0) }) { tap(vc2, c) }
        XCTAssertEqual(candButtons(vc2).first?.currentTitle, "云朵糕", "学到的存下来了，新起的键盘也认")
        tapID(vc2, "gear")
        guard let clear = button(vc2, "learn-clear") else { return XCTFail("设置里没有「清空」") }
        XCTAssertFalse(clear.isHidden)
        clear.sendActions(for: .touchUpInside)
        button(vc2, "settings-done")?.sendActions(for: .touchUpInside)
        let vc3 = makeKeyboard()
        for c in "yunduogao".map({ String($0) }) { tap(vc3, c) }
        XCTAssertNotEqual(candButtons(vc3).first?.currentTitle, "云朵糕", "清空以后就不记得了")
    }

    /// 真机的样子：候选在后台算，按键当下拼音行先出来，候选随后就到；按空格时还没算好也落对（当场算）
    func testCandidatesComeFromBackground() {
        let vc = makeKeyboard()
        vc.syncEngine = false
        for c in "nihao".map({ String($0) }) { tap(vc, c) }
        let until = Date().addingTimeInterval(3)
        while !candButtons(vc).contains(where: { $0.currentTitle == "你好" }), Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(candButtons(vc).contains(where: { $0.currentTitle == "你好" }), "后台算好的候选要显示出来")
        for c in "women".map({ String($0) }) { tap(vc, c) }
        guard let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }) else { return XCTFail("没有空格键") }
        space.sendActions(for: .touchDown)
        space.sendActions(for: .touchUpInside)
        XCTAssertTrue(vc.buffer.isEmpty, "按空格把整串落下（候选还没从后台回来也当场算）")
    }

    func testPinyinShowsCandidates() {
        let vc = makeKeyboard()
        for c in ["n", "i", "h", "a", "o"] { tap(vc, c) }
        let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
        XCTAssertTrue(titles.contains("你好"), "输入 nihao 应该有候选「你好」，实际：\(titles.prefix(20))")
    }

    func testSwitchLayerAndLanguage() {
        let vc = makeKeyboard()
        tap(vc, "123")
        XCTAssertNotNil(keys(vc).first(where: { $0.currentTitle == "1" }), "数字页应该有 1")
        tap(vc, "ABC")
        XCTAssertNotNil(keys(vc).first(where: { $0.currentTitle == "q" }), "回到字母页应该有 q")
        XCTAssertEqual(modeKey(vc)?.accessibilityValue, "中")
        modeKey(vc)?.sendActions(for: .touchDown)
        XCTAssertEqual(modeKey(vc)?.accessibilityValue, "英", "切到英文")
        tap(vc, "123")
        XCTAssertNotNil(keys(vc).first(where: { $0.currentTitle == "1" }))
    }

    /// 拼音在上一行，候选字在下一行（2026-10-23 用户要求）
    func testPinyinAboveCandidates() {
        let vc = makeKeyboard()
        for c in ["n", "i", "h", "a", "o"] { tap(vc, c) }
        let all = self.all(vc.view)
        guard let comp = all.compactMap({ $0 as? UILabel }).first(where: { $0.text == "ni hao" && !$0.isHidden }),
              let cand = all.compactMap({ $0 as? UIButton }).first(where: { $0.currentTitle == "你好" }) else {
            return XCTFail("找不到拼音行或候选「你好」")
        }
        let cf = comp.convert(comp.bounds, to: vc.view)
        let bf = cand.convert(cand.bounds, to: vc.view)
        XCTAssertLessThanOrEqual(cf.maxY, bf.minY + 1, "拼音（\(cf)）应该在候选字（\(bf)）上面一行")
    }

    /// Z 左边的键在中文下也是 shift：按了以后再打字母直接打大写字母，不进拼音
    func testShiftInChineseTypesRawLetter() {
        let vc = makeKeyboard()
        guard let shift = keys(vc).first(where: { $0.accessibilityIdentifier == "shift" }) else { return XCTFail("没有 shift 键") }
        shift.sendActions(for: .touchDown)
        tap(vc, "N")
        XCTAssertEqual(vc.buffer, "", "shift 之后的字母直接打，不该进拼音串")
    }

    /// 候选栏右上的「分词 '」：xian → xian'
    func testApostropheChip() {
        let vc = makeKeyboard()
        for c in ["x", "i", "a", "n"] { tap(vc, c) }
        guard let chip = all(vc.view).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "apostrophe" }) else { return XCTFail("没有分词按钮") }
        chip.sendActions(for: .touchUpInside)
        XCTAssertEqual(vc.buffer, "xian'")
    }

    /// 识别器停顿后从头重来：前面的话不能被覆盖
    func testSpeechSegmentsKeepEarlierText() {
        var s = SpeechSegments()
        XCTAssertFalse(s.update("我现在"))
        XCTAssertFalse(s.update("我现在要说一段话"))
        XCTAssertFalse(s.update("我现在要说一段话，你看"))
        XCTAssertTrue(s.update("能不能"), "新的一条和上一条对不上又变短了，应该判为从头重来")
        XCTAssertFalse(s.update("能不能识别出来"))
        XCTAssertEqual(s.text, "我现在要说一段话，你看能不能识别出来")
        XCTAssertFalse(SpeechSegments.looksLikeRestart(prev: "是", new: "我是"), "一句话刚开口时前几个字反复改，不算重来")
        XCTAssertFalse(SpeechSegments.looksLikeRestart(prev: "我现在要说一段话，你看", new: "我现在要说一段话"), "开头对得上只是后面改短了，不算重来")
    }

    /// 没打字时顶栏：麦克风在左边，右边一个向下的小箭头（点一下收起键盘）；打字时两个都让位
    func testMicLeftAndHideArrowRight() {
        let vc = makeKeyboard()
        guard let mic = keys(vc).first(where: { $0.accessibilityIdentifier == "mic" }),
              let q = keys(vc).first(where: { $0.currentTitle == "q" }),
              let hide = button(vc, "hide") else { return XCTFail("找不到麦克风 / 收起箭头 / q 键") }
        let mf = mic.convert(mic.bounds, to: vc.view)
        let hf = hide.convert(hide.bounds, to: vc.view)
        let qf = q.convert(q.bounds, to: vc.view)
        XCTAssertLessThan(mf.maxY, qf.minY, "麦克风（\(mf)）应该在第一排字母键（\(qf)）上面的顶栏里")
        XCTAssertLessThan(mf.midX, 90, "麦克风在顶栏左边")
        XCTAssertGreaterThan(hf.midX, 300, "收起箭头在顶栏右边")
        XCTAssertLessThan(hf.maxY, qf.minY)
        XCTAssertFalse(hide.isHidden)
        XCTAssertGreaterThanOrEqual(hf.width, 38, "收起按钮是个够大的圆：宽度够")
        XCTAssertGreaterThanOrEqual(hf.height, 38, "收起按钮是个够大的圆：高度够")
        XCTAssertEqual(keys(vc).filter { $0.accessibilityIdentifier == "mic" }.count, 1)
        for c in ["n", "i"] { tap(vc, c) }
        XCTAssertTrue(hide.isHidden, "打字时收起箭头让位给候选栏的展开箭头")
        XCTAssertTrue(mic.isHidden)
        XCTAssertFalse(button(vc, "expand")?.isHidden ?? true)
    }

    /// 输入框被清空（消息发出去了、换了新输入框）以后，晚到的润色结果不能再整段打进去
    func testLateResultNotTypedIntoClearedBox() {
        let vc = makeKeyboard()
        vc.handle(recording(1, "你好吗"))                          // 亲眼看着这次录音
        var s = result(1, "你好吗", rseq: 5)
        vc.handle(s)
        XCTAssertEqual(vc.live, "你好吗")
        vc.contextProbe = { nil }                                  // 用户把话发出去了，输入框空了
        s.app["result"] = "你好吗？"
        s.app["rseq"] = 6
        vc.handle(s)
        XCTAssertEqual(vc.live, "", "输入框已经空了，不能把润色后的整段又打进去")
    }

    private func recording(_ sid: Int, _ partial: String) -> Link.Snap {
        var s = Link.Snap()
        s.ok = true
        s.app = ["state": "recording", "sid": sid, "partial": partial, "cuts": 0, "base": 0]
        return s
    }

    private func result(_ sid: Int, _ text: String, rseq: Int) -> Link.Snap {
        var s = Link.Snap()
        s.ok = true
        s.app = ["state": "idle", "sid": sid, "rsid": sid, "result": text, "rseq": rseq, "rtime": Date().timeIntervalSince1970, "rcuts": 0]
        return s
    }

    /// 新弹出的键盘没见过上一段录音，不能把 App 里还留着的结果打进现在的输入框（发完消息再开新窗口，上一段话又被整段打进来的那个毛病）
    func testKeyboardNeverTypesResultItDidNotWitness() {
        let vc = makeKeyboard()
        vc.handle(result(7, "上一段话", rseq: 100))
        XCTAssertEqual(vc.live, "", "没亲眼看着这次录音的键盘，不能把结果打进输入框")
    }

    /// 说完话、没等润色完就发送并换到了别的输入框：晚到的润色结果不能打进新输入框
    func testResultNotTypedWhenInputBoxChanged() {
        let vc = makeKeyboard()
        vc.handle(recording(1, "你好"))
        XCTAssertEqual(vc.live, "你好")
        let other = UUID()
        vc.docProbe = { other }                  // 换到了别的窗口
        vc.contextProbe = { "别的窗口里已有的字" }   // 就算新框里碰巧有字、光标前的内容对不上也不行
        vc.handle(result(1, "你好。", rseq: 5))
        XCTAssertEqual(vc.live, "", "已经换了输入框，结果不能再往里打")
    }

    /// 键盘收起 / 切走的时候不收结果，回到屏幕上再收（同一个输入框、光标还在原处就照常替换成润色后的）
    func testResultWaitsUntilKeyboardIsVisibleAgain() {
        let vc = makeKeyboard()
        vc.handle(recording(1, "你好"))
        vc.viewDidDisappear(false)
        vc.handle(result(1, "你好。", rseq: 5))
        XCTAssertEqual(vc.live, "你好", "键盘不在屏幕上，结果先留着")
        vc.viewWillAppear(false)
        vc.handle(result(1, "你好。", rseq: 5))
        XCTAssertEqual(vc.live, "你好。", "回到屏幕上就替换成润色后的")
    }

    /// 键盘实例读到 App 里记的数之前不写回去
    func testNoWriteBackBeforeSynced() {
        let vc = makeKeyboard()
        XCTAssertFalse(vc.synced)
        vc.handle(Link.Snap())                                     // 没连上 App
        XCTAssertFalse(vc.synced, "没读到 App 的记录，不算同步过")
        var s = Link.Snap()
        s.ok = true
        vc.handle(s)
        XCTAssertTrue(vc.synced)
    }

    /// 顶栏右边的收起、齿轮：两个看得见的白色圆，整个圆（再往外一圈）都是按的范围；按一下就收起（仿豆包，用户 10-23 说「区域还是很小、试了几次收不起来」）
    func testHideAndGearAreBigWhiteCircles() {
        let vc = makeKeyboard()
        guard let hide = button(vc, "hide") as? KeyButton, let gear = button(vc, "gear") as? KeyButton else { return XCTFail("找不到收起 / 齿轮按钮") }
        let hf = hide.convert(hide.bounds, to: vc.view), gf = gear.convert(gear.bounds, to: vc.view)
        XCTAssertLessThan(gf.maxX, hf.minX, "齿轮在收起的左边，两个圆不重叠")
        XCTAssertLessThanOrEqual(hf.maxX, 390, "不能伸出屏幕")
        for (b, outer) in [(hide, CGFloat(26)), (gear, CGFloat(-26))] {
            let f = b.convert(b.bounds, to: vc.view)
            XCTAssertEqual(f.width, CandidateBar.circle, accuracy: 0.5)
            XCTAssertEqual(f.height, CandidateBar.circle, accuracy: 0.5)
            XCTAssertEqual(b.layer.cornerRadius, f.width / 2, accuracy: 0.5, "圆形")
            XCTAssertNotNil(b.backgroundColor, "要有圆底")
            // 圆里面各处、圆外一圈（上下 26、靠外侧 26）按下去，落到的都是它自己
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (-18, 0), (18, 0), (0, -18), (0, 18), (-13, -13), (13, 13), (13, -13), (-13, 13), (0, -26), (0, 26), (outer, 0)]
            for (dx, dy) in pts {
                let hit = vc.view.hitTest(CGPoint(x: f.midX + dx, y: f.midY + dy), with: nil)
                XCTAssertTrue(hit === b, "\(b.accessibilityIdentifier ?? "?") 圆心偏 (\(dx), \(dy)) 的地方应该按到它自己，实际 \(String(describing: hit))")
            }
        }
        XCTAssertEqual(vc.collapseCount, 0)
        tapID(vc, "hide")
        XCTAssertEqual(vc.collapseCount, 1, "按一下就要收起键盘")
    }

    /// 待命过期、主 App 够不着时点麦克风：要么跳进去，要么留一行说得明白的红字，而且不能被下一次刷新盖掉（以前什么反应都没有）
    func testMicWithoutAppLeavesStickyReason() {
        let vc = makeKeyboard()
        vc.fullAccessProbe = { true }
        tapID(vc, "mic")
        XCTAssertTrue(vc.shownStatus.contains("没能打开"), "点了麦克风、主 App 打不开：要写明白，实际：\(vc.shownStatus)")
        vc.handle(Link.Snap())                   // 下一次刷新（主 App 仍然连不上）
        XCTAssertTrue(vc.shownStatus.contains("没能打开"), "红字不能被下一次刷新盖掉：\(vc.shownStatus)")
    }

    /// 把键盘真的画成图存到 /tmp/kbshots（CI 当成品传上来），改界面后拿来肉眼看；不是断言，只要能画出来、文件写得进去
    func testRenderScreenshots() throws {
        let dir = "/tmp/kbshots"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func shot(_ vc: KeyboardViewController, _ name: String, dark: Bool = false) throws {
            vc.view.overrideUserInterfaceStyle = dark ? .dark : .light
            vc.view.layoutIfNeeded()
            let size = vc.view.bounds.size
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 3
            let img = UIGraphicsImageRenderer(size: size, format: fmt).image { c in
                (dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.82, alpha: 1)).setFill()     // 真机上键盘底是灰的，白圆才看得出来
                c.fill(CGRect(origin: .zero, size: size))
                vc.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            try XCTUnwrap(img.pngData()).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        let a = makeKeyboard()
        try shot(a, "1-idle")
        try shot(a, "2-idle-dark", dark: true)
        a.fullAccessProbe = { true }
        tapID(a, "mic")                                  // 主 App 打不开：红字
        try shot(a, "3-open-failed")
        a.handle(recording(1, "你好吗"))
        try shot(a, "4-recording")
        let b = makeKeyboard()
        for c in ["n", "i", "h", "a", "o"] { tap(b, c) }
        try shot(b, "5-typing")
    }

    /// 按下字母键冒出放大气泡，松手收起；靠边的键气泡不能伸出键盘
    func testKeyPreviewBubble() {
        let vc = makeKeyboard()
        guard let h = keys(vc).first(where: { $0.currentTitle == "h" }), let q = keys(vc).first(where: { $0.currentTitle == "q" }),
              let bubble = all(vc.view).first(where: { $0 is KeyPreview }) else { return XCTFail("找不到 h / q 键或气泡") }
        tap(vc, "h")
        XCTAssertEqual(vc.previewText, "h")
        XCTAssertLessThan(bubble.frame.minY, h.convert(h.bounds, to: vc.view).minY, "气泡在按键上方")
        h.sendActions(for: .touchUpInside)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertNil(vc.previewText, "松手后气泡要收起")
        tap(vc, "q")
        XCTAssertEqual(vc.previewText, "q")
        XCTAssertGreaterThanOrEqual(bubble.frame.minX, 0, "最左边的键，气泡不能伸出屏幕")
        XCTAssertGreaterThanOrEqual(bubble.frame.minY, 0, "第一排的气泡不能伸出键盘上沿")
        q.sendActions(for: .touchUpInside)
    }

    /// 手指落在按键之间的缝里 / 屏幕最边上，也算按到最近的键
    func testTapInGapHitsNearestKey() {
        let vc = makeKeyboard()
        guard let q = keys(vc).first(where: { $0.currentTitle == "q" }), let w = keys(vc).first(where: { $0.currentTitle == "w" }) else { return XCTFail("找不到 q / w") }
        let qf = q.convert(q.bounds, to: vc.view), wf = w.convert(w.bounds, to: vc.view)
        let gap = CGPoint(x: (qf.maxX + wf.minX) / 2, y: qf.midY)
        let hit = vc.view.hitTest(gap, with: nil)
        XCTAssertTrue(hit === q || hit === w, "缝里应该落到 q 或 w，实际 \(String(describing: hit))")
        XCTAssertTrue(vc.view.hitTest(CGPoint(x: 1, y: qf.midY), with: nil) === q, "屏幕最左边应该算 q")
    }

    /// 空格键里「空格」下面有一行小字提示，且装得下
    func testSpaceHintLabel() {
        let vc = makeKeyboard()
        guard let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }),
              let hint = all(space).compactMap({ $0 as? UILabel }).first(where: { $0.accessibilityIdentifier == "spaceHint" }) else { return XCTFail("空格键里没有小字提示") }
        XCTAssertEqual(hint.text, "长按可以直接语音输入")
        let hf = hint.convert(hint.bounds, to: space)
        XCTAssertTrue(space.bounds.insetBy(dx: -0.5, dy: -0.5).contains(hf), "小字（\(hf)）要在空格键（\(space.bounds)）里面")
        if let t = space.titleLabel {
            let tf = t.convert(t.bounds, to: space)
            XCTAssertLessThanOrEqual(tf.maxY, hf.minY + 2, "「空格」（\(tf)）和小字（\(hf)）不能叠在一起")
        }
    }

    /// 按住空格说话时，顶栏也画声波（和点麦克风一样）
    func testHoldSpaceShowsWaveInTopBarToo() {
        let vc = makeKeyboard()
        var s = Link.Snap()
        s.ok = true
        s.app = ["state": "recording", "sid": 1, "partial": ""]
        vc.handle(s)
        XCTAssertTrue(vc.barWaveVisible)
        vc.pttActive = true
        vc.refreshBar()
        XCTAssertTrue(vc.barWaveVisible, "按住空格时顶栏也要有声波")
    }

    /// 轻点空格 / 按住空格：不崩（没有 App 配合，这里只验证这套手势能走完）
    func testSpaceTapAndHold() {
        let vc = makeKeyboard()
        guard let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }) else { return XCTFail("没有空格键") }
        space.sendActions(for: .touchDown)
        space.sendActions(for: .touchUpInside)
        space.sendActions(for: .touchDown)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        space.sendActions(for: .touchUpInside)
    }

    func testWaveViewDraws() {
        let w = WaveView(frame: CGRect(x: 0, y: 0, width: 200, height: 36))
        for lv in [[], [0.3], (0..<41).map { Double($0 % 10) / 10 }] as [[Double]] {
            w.levels = lv
            _ = UIGraphicsImageRenderer(size: w.bounds.size).image { c in w.layer.render(in: c.cgContext) }
        }
    }

    /// 说话中途动了输入框：已经打进去的那段冻结，App 回报冻结次数对上之后，新说的话接着往后写
    func testEditWhileRecordingFreezesAndContinues() {
        let vc = makeKeyboard()
        func snap(_ partial: String, cuts: Int, base: Int) -> Link.Snap {
            var s = Link.Snap()
            s.ok = true
            s.app = ["state": "recording", "partial": partial, "sid": 1, "cuts": cuts, "base": base]
            return s
        }
        vc.handle(snap("你好", cuts: 0, base: 0))
        XCTAssertEqual(vc.live, "你好")
        tap(vc, "n")                                   // 用户动手打字
        XCTAssertEqual(vc.live, "", "动了输入框，已经打进去的这段要冻结")
        XCTAssertEqual(vc.lastCmd, "cut")
        vc.handle(snap("你好今天", cuts: 0, base: 0))     // App 还没跟上：这条是冻结之前的内容，不能再打
        XCTAssertEqual(vc.live, "")
        vc.handle(snap("今天", cuts: 1, base: 2))          // App 跟上了：从冻结的位置往后
        XCTAssertEqual(vc.live, "今天")
        vc.handle(snap("今天天气", cuts: 1, base: 2))
        XCTAssertEqual(vc.live, "今天天气")
    }

    func testRemainderSkipsSolidCharacters() {
        XCTAssertEqual(SpeechSegments.solid("你好，今天 天气。"), 6)
        XCTAssertEqual(SpeechSegments.remainder("你好，今天天气", skipping: 2), "，今天天气")
        XCTAssertEqual(SpeechSegments.remainder("你好今天天气", skipping: 2), "今天天气")
        XCTAssertEqual(SpeechSegments.remainder("你好，今天天气不错", skipping: 4), "天气不错", "冻结之后识别器补了标点，位置按实字数对")
        XCTAssertEqual(SpeechSegments.remainder("你好", skipping: 5), "")
        XCTAssertEqual(SpeechSegments.remainder("你好", skipping: 0), "你好")
    }

    /// 「中」「英」两个字都显示（斜着摆），当前的那个标亮（绿色）；键不能太宽
    func testModeKeyShowsBothAndHighlightsCurrent() {
        let vc = makeKeyboard()
        func glyph(_ k: KeyButton?) -> ModeGlyph? { k.flatMap { all($0).compactMap { $0 as? ModeGlyph }.first } }
        guard let g = glyph(modeKey(vc)) else { return XCTFail("中英键上没有图案") }
        XCTAssertEqual(g.zh.text, "中")
        XCTAssertEqual(g.en.text, "英")
        XCTAssertEqual(g.zh.textColor, Brand.green, "现在是中文，「中」标亮")
        XCTAssertNotEqual(g.en.textColor, Brand.green)
        XCTAssertLessThan(g.zh.frame.minY, g.en.frame.minY, "中在上、英在下")
        XCTAssertLessThan(g.zh.frame.minX, g.en.frame.minX, "中在左、英在右")
        let w = modeKey(vc)?.bounds.width ?? 999
        let unit = keys(vc).first(where: { $0.currentTitle == "q" })?.bounds.width ?? 0
        XCTAssertLessThan(w, unit * 1.4, "中英键不能比字母键宽出太多：\(w) vs \(unit)")
        modeKey(vc)?.sendActions(for: .touchDown)
        vc.view.layoutIfNeeded()
        guard let g2 = glyph(modeKey(vc)) else { return XCTFail("切换后中英键上没有图案") }
        XCTAssertEqual(g2.en.textColor, Brand.green, "切到英文，「英」标亮")
        XCTAssertNotEqual(g2.zh.textColor, Brand.green)
    }

    /// 联想：打 daihui 第一个是「待会」；选了它以后候选栏列出后面可能接的词（儿、再、再说…），再点一个继续往后接
    func testPredictionsAfterCommit() {
        let vc = makeKeyboard()
        var snap = Link.Snap()
        snap.ok = true
        snap.app = ["state": "idle"]
        snap.hb = Date().timeIntervalSince1970
        vc.handle(snap)       // 没有主 App：造一份「待命」快照，免得「请开启完全访问」的红字占着候选栏
        for c in ["d", "a", "i", "h", "u", "i"] { tap(vc, c) }
        func cands() -> [UIButton] { all(vc.view).compactMap { $0 as? UIButton }.filter { !($0 is KeyButton) && $0.superview is UIStackView && !$0.isHidden } }
        XCTAssertEqual(cands().first?.currentTitle, "待会", "daihui 第一个应该是待会（不是带回）")
        cands().first?.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        let after = cands().compactMap { $0.currentTitle }
        XCTAssertTrue(after.contains("再") && after.contains("儿"), "选了待会以后应该列出后面可能接的词：\(after.prefix(12))")
        XCTAssertTrue(button(vc, "hide")?.isHidden ?? false, "有联想文字显示时收起圆钮让位，不压在候选字上")
        XCTAssertTrue(button(vc, "gear")?.isHidden ?? false, "有联想文字显示时齿轮让位，不压在候选字上")
        cands().first(where: { $0.currentTitle == "再" })?.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        let next = cands().compactMap { $0.currentTitle }
        XCTAssertFalse(next.isEmpty, "点了「再」以后应该接着给下一批联想")
        XCTAssertNotEqual(next, after, "联想要跟着上文走")
    }

    /// 联想行的 ✕：点一下整行关掉，回到最开始的样子（麦克风、齿轮、收起箭头都在），不再显示这批联想（用户 10-24）
    func testPredictionRowDismissable() {
        let vc = makeKeyboard()
        var snap = Link.Snap()
        snap.ok = true
        snap.app = ["state": "idle"]
        snap.hb = Date().timeIntervalSince1970
        vc.handle(snap)       // 造一份「待命」快照，免得「请开启完全访问」的提示占着候选栏
        for c in ["d", "a", "i", "h", "u", "i"] { tap(vc, c) }
        func cands() -> [UIButton] { all(vc.view).compactMap { $0 as? UIButton }.filter { !($0 is KeyButton) && $0.superview is UIStackView && !$0.isHidden } }
        cands().first?.sendActions(for: .touchUpInside)      // 选「待会」→ 联想预测显示
        vc.view.layoutIfNeeded()
        XCTAssertFalse(button(vc, "xmark")?.isHidden ?? true, "联想态要有 ✕")
        button(vc, "xmark")?.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(button(vc, "hide")?.isHidden ?? true, "关掉以后收起箭头要露出来")
        XCTAssertFalse(button(vc, "gear")?.isHidden ?? true, "关掉以后齿轮要露出来")
        XCTAssertFalse(button(vc, "mic")?.isHidden ?? true, "关掉以后麦克风要在")
        XCTAssertTrue(button(vc, "xmark")?.isHidden ?? false, "✕ 只在联想态出现")
        func shown(_ v: UIView) -> Bool { var x: UIView? = v; while let y = x { if y.isHidden { return false }; x = y.superview }; return true }
        XCTAssertTrue(cands().filter(shown).compactMap { $0.currentTitle }.isEmpty, "关掉以后不能再显示这批联想")
    }

    /// 打字、选词出了联想以后：按回车（发送）顶栏回到最开始的样子——麦克风、齿轮、收起都在，联想词不留（用户 10-24）
    func testReturnResetsTopBar() {
        let vc = makeKeyboard()
        var snap = Link.Snap()
        snap.ok = true
        snap.app = ["state": "idle"]
        snap.hb = Date().timeIntervalSince1970
        vc.handle(snap)
        for c in ["d", "a", "i", "h", "u", "i"] { tap(vc, c) }
        func cands() -> [UIButton] { all(vc.view).compactMap { $0 as? UIButton }.filter { !($0 is KeyButton) && $0.superview is UIStackView && !$0.isHidden } }
        cands().first?.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        XCTAssertTrue(button(vc, "hide")?.isHidden ?? false, "前提：选了词以后在显示联想")
        tapID(vc, "return")
        XCTAssertFalse(button(vc, "hide")?.isHidden ?? true, "发送以后收起箭头要露出来")
        XCTAssertFalse(button(vc, "gear")?.isHidden ?? true, "发送以后齿轮要露出来")
        XCTAssertFalse(button(vc, "mic")?.isHidden ?? true, "发送以后麦克风要在")
        func shown(_ v: UIView) -> Bool { var x: UIView? = v; while let y = x { if y.isHidden { return false }; x = y.superview }; return true }
        XCTAssertTrue(cands().filter(shown).compactMap { $0.currentTitle }.isEmpty, "发送以后不能再显示上一句的联想词")
    }

    /// App 自己的发送按钮把输入框清空了（键盘没按回车）：顶栏也回到最开始的样子
    func testClearedBoxResetsTopBar() {
        let vc = makeKeyboard()
        var snap = Link.Snap()
        snap.ok = true
        snap.app = ["state": "idle"]
        snap.hb = Date().timeIntervalSince1970
        vc.handle(snap)
        vc.contextProbe = { "待会" }
        for c in ["d", "a", "i", "h", "u", "i"] { tap(vc, c) }
        all(vc.view).compactMap { $0 as? UIButton }.first(where: { !($0 is KeyButton) && $0.superview is UIStackView && !$0.isHidden })?.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        vc.textDidChange(nil)
        XCTAssertTrue(button(vc, "hide")?.isHidden ?? false, "输入框里还有字：联想照常显示")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        vc.contextProbe = { nil }              // 宿主把输入框清空了
        vc.textDidChange(nil)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(button(vc, "hide")?.isHidden ?? true, "输入框被清空：收起箭头要露出来")
    }

    /// A 输入框的录音没关，键盘没收起、直接换到 B 输入框：B 里不能是录音状态，A 的话不能打进 B，并让主 App 作废那次录音
    func testRecordingFromOtherBoxIsDroppedInPlace() {
        let vc = makeKeyboard()
        vc.handle(recording(41, "在甲里说的话"))
        XCTAssertEqual(vc.live, "在甲里说的话")
        let b = UUID()
        vc.docProbe = { b }
        vc.textDidChange(nil)
        XCTAssertEqual(vc.lastCmd, "cancel", "换了输入框要让主 App 作废这次录音")
        vc.handle(recording(41, "在甲里说的话还没说完"))       // 主 App 还没跟上，还在录
        XCTAssertEqual(vc.live, "", "甲的话不能打进乙")
        XCTAssertFalse(vc.barWaveVisible, "乙里不能显示录音中的声波")
        XCTAssertFalse(vc.shownStatus.contains("录音中"), "乙里不能写录音中：\(vc.shownStatus)")
    }

    /// 同上，但乙是另一个键盘实例（换了窗口 / 换了 App，键盘重新弹出）：一出来就是待命，不接管甲的录音
    func testRecordingFromOtherBoxIsDroppedByNewKeyboard() {
        let a = makeKeyboard(pid: 100)
        a.handle(recording(42, "在甲里说的话"))                 // 甲认领了这次录音
        let b = makeKeyboard(pid: 200, initiator: false)       // 乙是另一个 App 里新弹出的键盘
        let other = UUID()
        b.docProbe = { other }
        b.handle(recording(42, "在甲里说的话还没说完"))
        XCTAssertEqual(b.live, "", "新弹出的键盘不能接管别的输入框的录音")
        XCTAssertEqual(b.lastCmd, "cancel")
        XCTAssertFalse(b.barWaveVisible)
        let back = makeKeyboard(pid: 100)                         // 回到甲（同一个输入框）也不会再接上已经作废的那次
        back.handle(recording(42, "在甲里说的话还没说完"))
        XCTAssertEqual(back.live, "")
        back.handle(recording(43, "新的一段"))                    // 之后新开始的录音照常
        XCTAssertEqual(back.live, "新的一段")
    }

    private func idleSnap() -> Link.Snap {
        var s = Link.Snap()
        s.ok = true
        s.app = ["state": "idle"]
        return s
    }

    /// 开着两个 App 的输入框（用户 10-24：无论点麦克风还是按住空格都立刻被作废，要关掉另一个输入框才行）：
    /// 另一个 App 里还活着的键盘实例（已收起，或者收起通知没来、仍当自己在屏幕上）被通知叫醒时，
    /// 既不能作废我的录音、也不能往它自己的输入框里打字
    func testOtherAppKeyboardInstanceNeverCancelsOrTypes() {
        let a = makeKeyboard(pid: 100)               // 甲 App 的键盘
        let stale = makeKeyboard(pid: 100)           // 甲里另一个实例：收起通知没来，仍当自己在屏幕上
        a.handle(idleSnap())
        stale.handle(idleSnap())
        a.viewDidDisappear(false)                    // 用户切走了
        let b = makeKeyboard(pid: 200)               // 乙 App 的键盘，用户在这里点麦克风
        b.docProbe = { Self.docB }                   // 不同 App 的输入框编号当然不同
        b.handle(idleSnap())
        b.handle(recording(60, "你好"))
        XCTAssertEqual(b.live, "你好", "发起录音的键盘照常打字")
        for k in [a, stale] {
            k.handle(recording(60, "你好吗"))
            XCTAssertNotEqual(k.lastCmd, "cancel", "别的 App 的键盘实例不能作废我的录音")
            XCTAssertEqual(k.live, "", "别的 App 的键盘实例不能往它自己的输入框里打字")
        }
        b.handle(recording(60, "你好吗"))
        XCTAssertEqual(b.live, "你好吗")
        XCTAssertNotEqual(b.lastCmd, "cancel")
        XCTAssertTrue(b.barWaveVisible)
    }

    /// 不待命的冷启动（用户 10-24：每次长按空格都跳来跳去）：宿主里的键盘拉起主 App → 主 App 自己输入框里的键盘先看到录音
    /// （不能认领、也不能作废）→ 跳回宿主，键盘进程重建、输入框编号换号 → 新实例凭认领票接着录，不能被当成别的输入框作废
    func testColdStartJumpBackKeepsRecording() {
        let host = makeKeyboard(pid: 100)            // 宿主里按住空格，openApp 留了认领票
        host.handle(idleSnap())
        let inApp = makeKeyboard(pid: 300, initiator: false)       // 主 App 自己输入框里的键盘
        inApp.docProbe = { Self.docB }
        inApp.handle(recording(70, "你"))
        XCTAssertEqual(inApp.live, "", "主 App 里的键盘没发起过录音，不能认领")
        XCTAssertNotEqual(inApp.lastCmd, "cancel")
        let back = makeKeyboard(pid: 100, initiator: false)        // 跳回来，新实例
        let newDoc = UUID()
        back.docProbe = { newDoc }                                 // 输入框编号换了
        back.handle(idleSnap())                                    // 刚跳回来主 App 还没开始录
        back.handle(recording(70, "你好"))
        XCTAssertNotEqual(back.lastCmd, "cancel", "跳回来的键盘不能把自己发起的录音当成别的输入框作废")
        XCTAssertEqual(back.live, "你好")
        XCTAssertTrue(back.barWaveVisible)
    }

    /// 同一个输入框里录音：键盘重新弹出（收起再点开）照常接着显示和打字
    func testRecordingContinuesInSameBox() {
        let a = makeKeyboard(pid: 100)
        a.handle(recording(44, "你好"))
        let again = makeKeyboard(pid: 100, initiator: false)
        again.handle(recording(44, "你好今天"))
        XCTAssertNotEqual(again.lastCmd, "cancel", "同一个输入框不能作废")
        XCTAssertTrue(again.barWaveVisible)
    }

    /// 英文也先进上面的框、带联想：打 tak 出 take，按空格才落进输入框
    func testEnglishComposesWithCompletions() {
        let vc = makeKeyboard()
        modeKey(vc)?.sendActions(for: .touchDown)
        for c in ["t", "a", "k"] { tap(vc, c) }
        XCTAssertEqual(vc.buffer, "tak", "英文字母先放进上面的框，不直接进输入框")
        let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
        XCTAssertTrue(titles.contains("take"), "tak 应该联想出 take：\(titles.prefix(20))")
        let label = all(vc.view).compactMap { $0 as? UILabel }.first(where: { $0.accessibilityIdentifier == "comp" && !$0.isHidden })
        XCTAssertEqual(label?.text, "tak")
        guard let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }) else { return XCTFail("没有空格键") }
        space.sendActions(for: .touchDown)
        space.sendActions(for: .touchUpInside)       // 轻点空格
        XCTAssertEqual(vc.buffer, "", "空格之后落下")
    }

    /// 第一个候选绿色；打字时麦克风让位，没字了又回来
    func testFirstCandidateGreenAndMicYieldsWhileTyping() {
        let vc = makeKeyboard()
        guard let mic = keys(vc).first(where: { $0.accessibilityIdentifier == "mic" }) else { return XCTFail("没有麦克风") }
        XCTAssertFalse(mic.isHidden)
        for c in ["n", "i", "h", "a", "o"] { tap(vc, c) }
        XCTAssertTrue(mic.isHidden, "打字时麦克风让位")
        let cands = all(vc.view).compactMap { $0 as? UIButton }.filter { !$0.isHidden && $0.currentTitle != nil && $0.tag < 40 && $0.superview is UIStackView && !($0 is KeyButton) }
        XCTAssertEqual(cands.first?.titleColor(for: .normal), Brand.green, "第一个候选用绿色")
        XCTAssertNotEqual(cands.dropFirst().first?.titleColor(for: .normal), Brand.green)
        for _ in 0..<5 {
            button(vc, "delete")?.sendActions(for: .touchDown)
            button(vc, "delete")?.sendActions(for: .touchUpInside)
        }
        XCTAssertFalse(mic.isHidden, "拼音删光了，麦克风回来")
    }


    /// 拼音九键：打 64426 出「你好」；左边列出下一个音节（ni / mi…），点 ni 就选定；右边第二个键拼字时变「重输」
    func testNineKeyInputAndSyllableColumn() {
        UserDefaults.standard.set(true, forKey: "nine")
        let vc = makeKeyboard()
        XCTAssertTrue(vc.nine)
        for d in ["6", "4", "4", "2", "6"] { tapID(vc, "t9-" + d) }
        XCTAssertEqual(vc.buffer, "64426")
        let titles = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
        XCTAssertTrue(titles.contains("你好"), "九键 64426 应该有候选「你好」，实际：\(titles.prefix(30))")
        guard let syll = all(vc.view).first(where: { $0.accessibilityIdentifier == "syllables" }) else { return XCTFail("没有音节列表") }
        XCTAssertFalse(syll.isHidden, "拼字时左边是音节列表")
        guard let ni = keys(vc).first(where: { $0.currentTitle == "ni" && !$0.isHidden }) else { return XCTFail("音节列表里没有 ni：\(titles.prefix(30))") }
        ni.sendActions(for: .touchUpInside)
        XCTAssertEqual(vc.buffer, "ni426", "点 ni 以后前两位数字换成字母")
        XCTAssertEqual(keys(vc).first(where: { $0.accessibilityIdentifier == "t9-clear" })?.currentTitle, "重输")
        let after = all(vc.view).compactMap { ($0 as? UIButton)?.currentTitle }
        XCTAssertTrue(after.contains("你好"), "选定 ni 以后还是有「你好」：\(after.prefix(30))")
        tapID(vc, "t9-clear")
        XCTAssertEqual(vc.buffer, "", "重输清掉拼音串")
        XCTAssertEqual(keys(vc).first(where: { $0.accessibilityIdentifier == "t9-clear" })?.currentTitle, "！")
        XCTAssertTrue(syll.isHidden, "没拼字时音节列表收起、左边是标点")
    }

    /// 九键打一长串（womenqukandianyingba，20 个数字）：顶栏显示的是拼音字母不是数字，第一个候选是整句，不是只出前面一个词
    func testNineKeyLongInputShowsPinyinAndWholeSentence() {
        UserDefaults.standard.set(true, forKey: "nine")
        let vc = makeKeyboard()
        for d in "96636785263426946422".map({ String($0) }) { tapID(vc, "t9-" + d) }
        let comp = all(vc.view).compactMap { $0 as? UILabel }.first(where: { $0.accessibilityIdentifier == "comp" && !$0.isHidden })
        XCTAssertNotNil(comp)
        XCTAssertFalse(comp?.text?.contains(where: { $0.isNumber }) ?? true, "九键输入长了顶栏也要是拼音字母，不是数字：\(comp?.text ?? "nil")")
        XCTAssertEqual(comp?.text, "wo men qu kan dian ying ba", "顶栏是整句的拼音")
        let titles = candButtons(vc).compactMap { $0.currentTitle }
        XCTAssertEqual(titles.first, "我们去看电影吧", "第一个候选是整句，实际：\(titles.prefix(12))")
        pickTitle(vc, "我们去看电影吧")
        XCTAssertEqual(vc.buffer, "", "整句选下去，数字串全吃掉")
    }

    /// 九键打到一半（还没盖住整串的词）：顶栏照样是拼音，盖不住的尾巴才留数字
    func testNineKeyPartialCoverageStillLetters() {
        UserDefaults.standard.set(true, forKey: "nine")
        let vc = makeKeyboard()
        for d in "6444".map({ String($0) }) { tapID(vc, "t9-" + d) }
        let comp = all(vc.view).compactMap { $0 as? UILabel }.first(where: { $0.accessibilityIdentifier == "comp" && !$0.isHidden })
        XCTAssertNotNil(comp?.text)
        XCTAssertTrue(comp?.text?.contains(where: { $0.isLetter }) ?? false, "至少前面几位是拼音字母：\(comp?.text ?? "nil")")
    }

    /// 九键键盘的尺寸：键又宽又好按，底排矮；回车占两排高
    func testNineKeyLayoutSize() {
        UserDefaults.standard.set(true, forKey: "nine")
        let vc = makeKeyboard()
        guard let k2 = keys(vc).first(where: { $0.accessibilityIdentifier == "t9-2" }), let space = keys(vc).first(where: { $0.accessibilityIdentifier == "space" }),
              let del = keys(vc).first(where: { $0.accessibilityIdentifier == "delete" }),
              let ret = keys(vc).first(where: { $0.accessibilityIdentifier == "return" }) else { return XCTFail("找不到九键的 2 / 空格 / 删除 / 回车") }
        XCTAssertGreaterThan(k2.bounds.width, 70, "九键中间的键很宽：\(k2.bounds)")
        XCTAssertGreaterThanOrEqual(k2.bounds.height, 47)
        XCTAssertLessThanOrEqual(space.bounds.height, 44)
        XCTAssertGreaterThan(ret.bounds.height, k2.bounds.height + 40, "回车占两排高：\(ret.bounds)")
        let kf = k2.convert(k2.bounds, to: vc.view), df = del.convert(del.bounds, to: vc.view)
        XCTAssertLessThan(kf.maxX, df.minX, "删除在九宫格右边")
        for k in keys(vc) where !k.isHidden {
            let f = k.convert(k.bounds, to: vc.view)
            XCTAssertLessThanOrEqual(f.maxX, 390.5)
            XCTAssertLessThanOrEqual(f.maxY, KeyboardViewController.keyboardHeight + 0.5)
        }
    }

    /// 顶栏齿轮 → 设置面板：按键震动开关（存下来）、26键 / 九键切换（立刻换键盘）
    func testSettingsPanelHapticAndLayout() {
        let vc = makeKeyboard()
        XCTAssertTrue(vc.hapticOn, "按键震动默认开")
        XCTAssertFalse(vc.nine)
        guard let gear = button(vc, "gear"), let panel = all(vc.view).first(where: { $0.accessibilityIdentifier == "settings" }),
              let sw = all(panel).compactMap({ $0 as? UISwitch }).first, let seg = all(panel).compactMap({ $0 as? UISegmentedControl }).first else { return XCTFail("没有齿轮 / 设置面板 / 开关") }
        XCTAssertTrue(panel.isHidden)
        gear.sendActions(for: .touchDown)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(panel.isHidden, "点齿轮打开设置")
        XCTAssertTrue(sw.isOn)
        sw.isOn = false
        sw.sendActions(for: .valueChanged)
        XCTAssertFalse(vc.hapticOn, "关掉震动")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "haptic") as? Bool, false, "要存下来，下次打开键盘还是关的")
        seg.selectedSegmentIndex = 1
        seg.sendActions(for: .valueChanged)
        vc.view.layoutIfNeeded()
        XCTAssertTrue(vc.nine)
        XCTAssertTrue(panel.isHidden, "换了键盘就收起设置")
        XCTAssertNotNil(keys(vc).first(where: { $0.accessibilityIdentifier == "t9-2" }), "换成了九键")
        XCTAssertNil(keys(vc).first(where: { $0.currentTitle == "q" }))
        for _ in 0..<2 {      // 关了震动以后点键不能崩
            tapID(vc, "t9-6")
        }
    }


    /// 123 旁边的「，。」合并键（仿豆包）：逗号大字 + 右上角句号小字；点 = 逗号、上滑 = 句号；英文下是 , .
    func testPunctKeyNextTo123() {
        let vc = makeKeyboard()
        guard let k123 = keys(vc).first(where: { $0.currentTitle == "123" }), let pk = keys(vc).first(where: { $0.accessibilityIdentifier == "punct" }),
              let mode = modeKey(vc) else { return XCTFail("找不到 123 / 「，。」键 / 中英键") }
        let a = k123.convert(k123.bounds, to: vc.view), b = pk.convert(pk.bounds, to: vc.view), m = mode.convert(mode.bounds, to: vc.view)
        XCTAssertGreaterThanOrEqual(b.minX, a.maxX, "「，。」紧挨在 123 右边")
        XCTAssertLessThan(b.maxX, m.minX, "在中英键左边")
        XCTAssertEqual(abs(a.minY - b.minY) < 1, true, "和 123 同一排")
        XCTAssertEqual(pk.currentTitle, "，")
        XCTAssertNotNil(all(pk).compactMap { $0 as? UILabel }.first(where: { $0.text == "。" }), "右上角有小字「。」")
        XCTAssertTrue(KeyboardViewController.punctPicksPeriod(dy: -20))
        XCTAssertFalse(KeyboardViewController.punctPicksPeriod(dy: -3))
        XCTAssertFalse(KeyboardViewController.punctPicksPeriod(dy: 10))
        modeKey(vc)?.sendActions(for: .touchDown)
        vc.view.layoutIfNeeded()
        XCTAssertEqual(keys(vc).first(where: { $0.accessibilityIdentifier == "punct" })?.currentTitle, ",", "英文下是逗号")
        tap(vc, "123")
        XCTAssertNotNil(keys(vc).first(where: { $0.accessibilityIdentifier == "punct" }), "数字页底排也有")
        XCTAssertEqual(vc.hapticOn, true)
    }

    /// 向下箭头：展开全部候选（盖住按键），再点收回；点展开里的一个就选它
    func testExpandPanelShowsAllCandidates() {
        let vc = makeKeyboard()
        for c in ["n", "i"] { tap(vc, c) }
        guard let arrow = button(vc, "expand") else { return XCTFail("没有展开箭头") }
        guard let panel = all(vc.view).first(where: { $0.accessibilityIdentifier == "panel" }) else { return XCTFail("没有展开面板") }
        XCTAssertTrue(panel.isHidden)
        arrow.sendActions(for: .touchUpInside)
        vc.view.layoutIfNeeded()
        XCTAssertFalse(panel.isHidden, "点箭头应该展开")
        let shown = all(panel).compactMap { ($0 as? UIButton) }.filter { !$0.isHidden && $0.currentTitle != nil }
        XCTAssertGreaterThan(shown.count, 14, "展开后候选比一行多得多：\(shown.count)")
        XCTAssertGreaterThan(panel.frame.height, 150, "面板盖住按键区")
        shown.first?.sendActions(for: .touchUpInside)
        XCTAssertTrue(panel.isHidden, "选完收回")
        XCTAssertEqual(vc.buffer.count < 2, true, "选了第一个候选，拼音被吃掉")
    }

    func testNoAnimationsAndHostIdValidation() {
        let vc = makeKeyboard()
        XCTAssertFalse(UIView.areAnimationsEnabled, "键盘里不要任何过渡动画")
        XCTAssertFalse(HostApp.looksLikeBundleID("<null>"))
        XCTAssertFalse(HostApp.looksLikeBundleID("(null)"))
        XCTAssertTrue(HostApp.looksLikeBundleID("com.apple.mobilenotes"))
        _ = HostApp.resolve(vc)       // 把运行时探测真的跑一遍：不能崩
        XCTAssertEqual(HostReturn.url(forPath: "/private/var/containers/Bundle/Application/ABC/WeChat.app/WeChat")?.absoluteString, "weixin://")
        XCTAssertNil(HostReturn.url(forPath: "/usr/libexec/foo"))
        XCTAssertEqual(HostReturn.url(for: "com.tencent.xin")?.absoluteString, "weixin://")
        XCTAssertEqual(HostReturn.url(for: "com.esplink.remote.ABCDE12345")?.absoluteString, "xiaoya://", "SideStore 签名的小芽带团队号，要能认出来")
        XCTAssertEqual(HostReturn.url(for: "com.esplink.remote")?.absoluteString, "xiaoya://")
        XCTAssertEqual(HostReturn.canonical("com.tencent.xin"), "com.tencent.xin", "没有团队号的原样")
        XCTAssertEqual(HostReturn.canonical("com.apple.mobilenotes"), "com.apple.mobilenotes")
        XCTAssertNil(HostReturn.url(for: "com.example.unknown.ABCDE12345"))
    }
}
