import UIKit

/// 配色：嫩芽绿 #16985E、深叶绿 #0F7448、青柠 #B0E082
enum Brand {
    static let green = UIColor(red: 0x16 / 255, green: 0x98 / 255, blue: 0x5E / 255, alpha: 1)
    static let deep = UIColor(red: 0x0F / 255, green: 0x74 / 255, blue: 0x48 / 255, alpha: 1)
    static let lightGreen = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x9C / 255, green: 0xCF / 255, blue: 0x78 / 255, alpha: 1) : UIColor(red: 0xC9 / 255, green: 0xEB / 255, blue: 0xA8 / 255, alpha: 1) }
}

/// 按键：按住时变深色。字母区里的键不自己收触摸，由 KeyboardRoot 统一接线（见那边的说明）
final class KeyButton: UIButton {
    var normalColor = UIColor.white { didSet { backgroundColor = isHighlighted ? pressedColor : normalColor } }
    var pressedColor = UIColor.lightGray
    override var isHighlighted: Bool { didSet { backgroundColor = isHighlighted ? pressedColor : normalColor } }
    /// 能按的范围比看得见的按键大这么多（顶栏的圆形按钮用：圆外面一圈也算按到）
    var hitOutset: CGFloat = 0
    /// 由 KeyboardRoot 接线的键（字母区里的键）。🌐 键要系统给的真实触摸事件才能弹出输入法列表，不走这条
    var routed = true
    /// 字母 / 符号键：松手才打字，手指滑到哪个键就打哪个（跟系统键盘一样，按偏了可以滑过去改）；别的键（空格、删除、123…）一按下就响应
    var commitsOnRelease = false
    var onCommit: (() -> Void)?
    /// 上滑一小段再松手要打的东西（字母键上滑出数字 / 符号）
    var swipeUp: (text: String, action: () -> Void)?
    /// 按住不放时手指的位移（空格上左右滑移光标、删除键左滑清空）；返回 true = 这次触摸算滑动，松手不再当点按
    var onDrag: ((CGFloat, CGFloat) -> Bool)?
    /// 手指现在还按在它上面（接线后 UIControl 自己的 isTracking 不管用了）
    var touchHeld = false
    /// 这次触摸从按下到现在，手指横竖挪了多少（KeyboardRoot 每次更新）
    var dragDelta = CGPoint.zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 给阴影一条现成的路径：没有的话每个键每次重绘都要现算轮廓，打字时会拖慢
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
}

/// 比看得见的大一圈的按钮：手指偏一点、稍微滑一下也算按到（展开箭头、撤销、✕ 这些小按钮用）
final class PadButton: UIButton {
    var pad = UIEdgeInsets.zero      // 往外多算的范围（正数 = 往外）

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: -pad.top, left: -pad.left, bottom: -pad.bottom, right: -pad.right)).contains(point)
    }
}

/// 候选 / 音节这类「在滑动区里、松手才算点」的按钮：松手时手指稍微滑出了按钮边（但没在滑动列表）也算点到。
/// 以前只认 touchUpInside，手指一滑出边（手指带一点滑动是常态）这一下就丢了，用户感觉「滑的时候经常没反应」
func tapIsNear(_ b: UIView, _ event: UIEvent?, scroll: UIScrollView?) -> Bool {
    // isTracking 也要挡（仿豆包的 touchSlop 判定）：手指已经按进滑动区开始拖，只是系统还没判成拖动，这时松手不该算点选
    if let s = scroll, s.isTracking || s.isDragging || s.isDecelerating { return false }
    guard let p = event?.allTouches?.first?.location(in: b) else { return false }
    return b.bounds.insetBy(dx: -14, dy: -20).contains(p)
}

/// 一次键盘使用中手指的各种情况的计数，用来在服务器日志里看「按了没反应」到底是哪一种（键盘收起时补报）
struct TouchStats {
    var down = 0         // 手指按下的次数
    var miss = 0         // 按下去附近找不到键
    var slid = 0         // 按下后滑到了别的键才松手（按偏了滑过去改）
    var swiped = 0       // 上滑打了数字 / 符号
    var dragged = 0      // 在空格 / 删除上滑动
    var cancelled = 0    // 被系统取消（而且不是短促的点按）
    var saved = 0        // 系统取消了，但是一下短促的点按，照样打了
    var far = 0          // 手指拖出键盘很远松手，取消

    var summary: String {
        "按下\(down) 没按到键\(miss) 滑过去改\(slid) 上滑\(swiped) 空格删除滑动\(dragged) 系统取消\(cancelled) 取消后补打\(saved) 拖远取消\(far)"
    }
}

/// 整个键盘的根容器，也是字母区所有按键的「触摸接线员」。
/// 以前每个键自己收触摸（UIControl）：松手才算数的键（空格、候选）手指一滑出键边就整个丢掉；手指落在缝里、屏幕边缘、第一排上沿的空档要靠补丁；
/// 字母一按下就打、按偏了没法改。现在统一在这里收：
/// ① 手指落在哪个键按位置现算——没有死角，缝里 / 屏幕边缘 / 第一排上沿都归最近的键；
/// ② 每根手指单独跟踪（连打、两个拇指不互相顶掉）；
/// ③ 字母 / 符号键松手才打字，按住时气泡跟着手指走，滑到哪个键就打哪个，上滑打数字（二期）；
/// ④ 其它键照旧一按下就响应，并替它们发出原来的 touchDown / touchUpInside 事件（松手稍微滑出一点也算点到）；空格、删除键还能滑动（二期）。
final class KeyboardRoot: UIView {
    weak var keyArea: UIView?
    /// 手指按下一个字母 / 符号键（震动、声音、放大气泡）
    var onKeyDown: ((KeyButton) -> Void)?
    /// 手指滑到了另一个字母键 / 上滑状态变了（气泡跟着走；text = 上滑状态下松手要打的字）
    var onKeyMoved: ((KeyButton, String?) -> Void)?
    /// 手指抬起 / 取消（收起气泡）
    var onKeyUp: (() -> Void)?
    /// 动态热区：某个键现在「更可能是下一个要按的」，在两个键的交界处让它多占几个点（单位 pt，可正可负）
    var letterBias: ((KeyButton) -> CGFloat)?
    private(set) var stats = TouchStats()

    /// 上滑超过这么多、而且手指还在原来那个键上，才算「上滑打数字」
    static let swipeUpDistance: CGFloat = 16

    private struct Finger {
        var key: KeyButton
        var start: CGPoint
        let t0: TimeInterval
        var up = false
        var dragged = false
        var far = false
    }
    private var fingers: [AnyHashable: Finger] = [:]
    private var cached: [KeyButton]?

    func resetStats() { stats = TouchStats() }

    /// 重排以后按键换了一批
    func invalidateKeys() { cached = nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        cached = nil
    }

    /// 这块透明的「触摸接线板」盖在按键区上面（四周多盖一圈：左右屏幕边缘、第一排上沿到候选栏之间那条缝、最下面一排的下沿），
    /// 按键区里的触摸归它；🌐 键、九键左边可上下滑的音节列表这些自己收触摸的，让给下面的视图（返回 nil）
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        if let area = keyArea, let under = area.hitTest(convert(point, to: area), with: event), KeyboardRoot.ownsOwnTouches(under, upTo: area) { return nil }
        return self
    }

    /// 🌐 键、九键左边可上下滑的音节列表这些自己收触摸，不归接线员管
    private static func ownsOwnTouches(_ v: UIView, upTo area: UIView) -> Bool {
        var x: UIView? = v
        while let c = x, c !== area {
            if let k = c as? KeyButton, !k.routed { return true }
            if c is UIScrollView { return true }
            x = c.superview
        }
        return false
    }

    /// k 到 area 之间有没有被藏起来的（九键左边的标点 / 音节列表会轮流藏）
    private static func visible(_ k: UIView, upTo area: UIView) -> Bool {
        var x: UIView? = k
        while let c = x, c !== area {
            if c.isHidden { return false }
            x = c.superview
        }
        return true
    }

    private static func buttons(in v: UIView) -> [KeyButton] {
        v.subviews.flatMap { sub -> [KeyButton] in
            if let k = sub as? KeyButton { return [k] }
            if sub is UIScrollView { return [] }      // 滑动区里的按钮自己收触摸
            return buttons(in: sub)
        }
    }

    /// 现在能按的、归接线员管的所有键
    private func routedKeys() -> [KeyButton] {
        guard let area = keyArea else { return [] }
        if cached == nil { cached = KeyboardRoot.buttons(in: area).filter { $0.routed } }
        return (cached ?? []).filter { !$0.bounds.isEmpty && KeyboardRoot.visible($0, upTo: area) }
    }

    /// 手指在 p 的位置，该算哪个键。得分 = 手指在键里面时离最近一条边有多深（正），在键外面时离键有多远（负）；
    /// 只有在两个键交界处（里外 3pt 以内）才让「下一个字母更可能是谁」说话，刚按着的那个键再黏一点（滑动时不来回跳）
    func nearest(to p: CGPoint, sticky: KeyButton? = nil) -> (key: KeyButton, score: CGFloat)? {
        var best: (key: KeyButton, score: CGFloat)?
        for k in routedKeys() {
            let f = k.convert(k.bounds, to: self)
            let ox = max(f.minX - p.x, 0, p.x - f.maxX), oy = max(f.minY - p.y, 0, p.y - f.maxY)
            var s: CGFloat = (ox > 0 || oy > 0) ? -hypot(ox, oy) : min(p.x - f.minX, f.maxX - p.x, p.y - f.minY, f.maxY - p.y)
            if s < 3, let bias = letterBias { s += bias(k) }
            if k === sticky { s += 3 }
            s -= 0.001 * hypot(f.midX - p.x, f.midY - p.y)
            if best == nil || s > best!.score { best = (k, s) }
        }
        return best
    }

    /// 测试用：根视图坐标里 p 这个点会按到哪个键
    func key(at p: CGPoint) -> KeyButton? { nearest(to: p).flatMap { $0.score > -30 ? $0.key : nil } }

    // MARK: 触摸（UIKit 的触摸回调只是把手指的位置转给下面几个入口；测试直接调这几个入口，不用造真的 UITouch）

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerDown(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerMoved(ObjectIdentifier(t), to: t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerUp(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp, cancelled: false) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { fingerUp(ObjectIdentifier(t), at: t.location(in: self), time: t.timestamp, cancelled: true) }
    }

    func fingerDown(_ id: AnyHashable, at p: CGPoint, time: TimeInterval) {
        stats.down += 1
        guard let best = nearest(to: p), best.score > -30 else { stats.miss += 1; return }
        fingers[id] = Finger(key: best.key, start: p, t0: time)
        let k = best.key
        k.touchHeld = true
        k.dragDelta = .zero
        k.isHighlighted = true
        if k.commitsOnRelease { onKeyDown?(k) } else { k.sendActions(for: .touchDown) }
    }

    func fingerMoved(_ id: AnyHashable, to p: CGPoint) {
        guard var f = fingers[id] else { return }
        let dx = p.x - f.start.x, dy = p.y - f.start.y
        let k = f.key
        k.dragDelta = CGPoint(x: dx, y: dy)
        if k.commitsOnRelease {
            let near = nearest(to: p, sticky: k)
            f.far = (near?.score ?? -100) < -70
            // 上滑：手指还在这个键上、往上滑够远 → 松手打它的数字 / 符号；滑进了上一排的键就是「滑过去改」
            let up = k.swipeUp != nil && dy < -Self.swipeUpDistance && -dy > abs(dx) && near?.key === k
            if up != f.up {
                f.up = up
                onKeyMoved?(k, up ? k.swipeUp?.text : nil)
            }
            if !f.up, let n = near, n.key !== k, n.key.commitsOnRelease, n.score > -30 {
                k.touchHeld = false
                k.isHighlighted = false
                n.key.touchHeld = true
                n.key.isHighlighted = true
                f.key = n.key
                f.start = p
                stats.slid += 1
                onKeyMoved?(n.key, nil)
            }
        } else if let drag = k.onDrag, drag(dx, dy) {
            f.dragged = true
        }
        fingers[id] = f
    }

    func fingerUp(_ id: AnyHashable, at p: CGPoint, time: TimeInterval, cancelled: Bool) {
        guard let f = fingers.removeValue(forKey: id) else { return }
        let k = f.key
        k.touchHeld = false
        k.isHighlighted = false
        k.dragDelta = CGPoint(x: p.x - f.start.x, y: p.y - f.start.y)
        if k.commitsOnRelease {
            onKeyUp?()
            // 系统抢走了触摸（边缘手势之类）：短促的一下点按照样打出去，别丢字；拖了一阵的才真的取消
            let tap = time - f.t0 < 0.3 && hypot(k.dragDelta.x, k.dragDelta.y) < 14
            if cancelled, !tap { stats.cancelled += 1; return }
            if f.far { stats.far += 1; return }
            if cancelled { stats.saved += 1 }
            if f.up, let s = k.swipeUp {
                stats.swiped += 1
                s.action()
            } else {
                k.onCommit?()
            }
        } else if cancelled {
            stats.cancelled += 1
            k.sendActions(for: .touchCancel)
        } else if f.dragged {
            stats.dragged += 1
            k.sendActions(for: .touchCancel)      // 滑动过的不当点按
        } else {
            // 松手时手指离开键 40pt 以内都算点到（空格这类只认「松手」的键，手指一滑出边不再丢）
            let fr = k.convert(k.bounds, to: self).insetBy(dx: -40, dy: -40)
            k.sendActions(for: fr.contains(p) ? .touchUpInside : .touchUpOutside)
        }
    }

    /// 键盘收起 / 换了界面时手指还按着：当取消处理，别留着按下的状态（比如按住空格的录音）
    func cancelAll() {
        for (_, f) in fingers {
            f.key.touchHeld = false
            f.key.isHighlighted = false
            if !f.key.commitsOnRelease { f.key.sendActions(for: .touchCancel) }
        }
        fingers = [:]
        onKeyUp?()
    }
}

/// 按下字母键时冒出来的放大气泡（跟系统键盘一样）。贴在键盘视图最上层，第一排的气泡伸进上面的候选栏那一块
final class KeyPreview: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()
    private(set) var text: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(shape)
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.textColor = .label
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    func show(_ t: String, over key: UIView, in host: UIView, fill: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)      // 图层属性默认会渐变 0.25 秒：气泡要立刻出现，不要过渡
        defer { CATransaction.commit() }
        let k = key.convert(key.bounds, to: host)
        let ext: CGFloat = 12, bodyH: CGFloat = 46, neck: CGFloat = 10, r: CGFloat = 8
        var left = ext, right = ext
        if k.minX - ext < 2 { left = 0; right = ext * 2 }                       // 靠左边缘：气泡往右偏
        else if k.maxX + ext > host.bounds.width - 2 { left = ext * 2; right = 0 }   // 靠右边缘：往左偏
        let w = k.width + left + right
        let h = bodyH + neck + k.height
        frame = CGRect(x: k.minX - left, y: k.minY - bodyH - neck, width: w, height: h)
        let kx1 = left, kx2 = left + k.width, ny = bodyH + neck, kr: CGFloat = 6
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: w - r, y: 0))
        p.addArc(withCenter: CGPoint(x: w - r, y: r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: w, y: bodyH - r))
        p.addArc(withCenter: CGPoint(x: w - r, y: bodyH - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addCurve(to: CGPoint(x: kx2, y: ny), controlPoint1: CGPoint(x: w - r, y: bodyH + neck * 0.6), controlPoint2: CGPoint(x: kx2, y: bodyH + neck * 0.4))
        p.addLine(to: CGPoint(x: kx2, y: h - kr))
        p.addArc(withCenter: CGPoint(x: kx2 - kr, y: h - kr), radius: kr, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        p.addLine(to: CGPoint(x: kx1 + kr, y: h))
        p.addArc(withCenter: CGPoint(x: kx1 + kr, y: h - kr), radius: kr, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: kx1, y: ny))
        p.addCurve(to: CGPoint(x: r, y: bodyH), controlPoint1: CGPoint(x: kx1, y: bodyH + neck * 0.4), controlPoint2: CGPoint(x: r, y: bodyH + neck * 0.6))
        p.addArc(withCenter: CGPoint(x: r, y: bodyH - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        p.close()
        shape.frame = bounds
        shape.path = p.cgPath
        shape.shadowPath = p.cgPath
        shape.fillColor = fill.resolvedColor(with: host.traitCollection).cgColor
        label.text = t
        label.frame = CGRect(x: left + k.width / 2 - 30, y: 0, width: 60, height: bodyH)
        text = t
        host.addSubview(self)      // 每次都挪到最上面
        isHidden = false
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = true
        text = nil
        CATransaction.commit()
    }
}

/// 说话时的声波：一排竖条，最新的音量在最右边，往左滚
final class WaveView: UIView {
    var levels: [Double] = [] { didSet { setNeedsDisplay() } }
    var color = Brand.green

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    override func draw(_ rect: CGRect) {
        let barW: CGFloat = 4, gap: CGFloat = 3
        let n = max(1, Int((bounds.width + gap) / (barW + gap)))
        // 音量每 21 毫秒一个，两个并成一根竖条（取大的），一屏大约 1.5 秒
        let raw = Array(levels.suffix(n * 2))
        var vals: [Double] = []
        var i = raw.count
        while i > 0 { vals.insert(max(raw[i - 1], i >= 2 ? raw[i - 2] : 0), at: 0); i -= 2 }
        let pad = n - vals.count
        color.setFill()
        for j in 0..<n {
            let v = j < pad ? 0 : CGFloat(vals[j - pad])
            let h = max(4, v * (bounds.height - 2))
            let r = CGRect(x: CGFloat(j) * (barW + gap), y: (bounds.height - h) / 2, width: barW, height: h)
            UIBezierPath(roundedRect: r, cornerRadius: barW / 2).fill()
        }
    }
}

/// 候选横滑区（仿豆包 CandidateListView 那套触摸规则）：
/// ① 在候选字上按下也能直接拖：滑动一开始就取消按钮的点按，不用等、也不丢；
/// ② 点在两个候选之间 2pt 的缝里、还有行两头的留空里不会落空：算点到附近那个候选（感知交给 CandidateBar 的 tap 手势）。
final class CandidateScroll: UIScrollView {
    /// 从候选字上起手也照滑不误
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

extension CandidateBar {
    /// 豆包 areacontrol（InputViewRoot 的 IdleTouchForward / 合成事件转发）的等价做法：起手落在顶栏任何非按钮的位置
    /// （拼音行、状态字、候选行上下的空处）都原样交给候选横滑区 — 滑动从哪起手都行，不必瞄着那一行。
    /// 横向拖动由 UIScrollView 原生接管（带惯性）；静止的点按落点在候选行外面时，gapTapped 的 y 判定会自然不选词。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit is UIControl || hit == nil && !bounds.contains(point) || scroll.isHidden { return hit }
        return scroll
    }
}


/// 键盘上方的一条（高 58）：打字时 = 上一行拼音（右边有展开箭头）+ 下一行候选字（可横滑，第一个绿色）；
/// 不打字时 = 左边小圆形麦克风按钮、中间语音状态文字 / 声波、右边一个向下的小箭头（点一下收起键盘；刚听写完在它左边多一个「撤销」）。
/// 打字时麦克风和收起箭头让位，候选能用满整条。
final class CandidateBar: UIView {
    static let height: CGFloat = 58
    /// 顶栏三个圆形按钮（麦克风、齿轮、收起）的直径；能按的范围再往外多 8（hitOutset），整个圆连同圆外一圈都算按到（仿豆包）
    static let circle: CGFloat = 40
    private let statusLabel = UILabel()
    private let wave = WaveView()
    private let compLabel = UILabel()
    private let expand = PadButton(type: .custom)
    private let scroll = CandidateScroll()
    private let stack = UIStackView()
    private let undo = PadButton(type: .custom)
    private let hide = KeyButton(type: .custom)         // 不打字时最右边的白色圆形按钮（向下箭头）：收起键盘
    private let gear = KeyButton(type: .custom)         // 它左边的白色圆形按钮（齿轮）：键盘设置（按键震动、26键 / 九键）
    private var compLeading: NSLayoutConstraint!        // 拼音行的左边：平时 10，联想预测时让出左边的麦克风
    let mic = KeyButton(type: .custom)
    private var pool: [UIButton] = []          // 候选按钮：建一次反复用，打每个字母都重建几十个按钮会卡
    var onPick: ((Int) -> Void)?
    var onUndo: (() -> Void)?
    var onMic: (() -> Void)?
    var onExpand: (() -> Void)?
    var onHide: (() -> Void)?
    var onGear: (() -> Void)?
    var onXmark: (() -> Void)?
    private let xmark = PadButton(type: .custom)   // 联想预测行右边的 ✕：关掉这行联想，顶栏回最开始


    override init(frame: CGRect) {
        super.init(frame: frame)
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        compLabel.font = .systemFont(ofSize: 17)
        compLabel.textColor = .label
        compLabel.lineBreakMode = .byTruncatingHead
        compLabel.accessibilityIdentifier = "comp"
        expand.tintColor = .label
        expand.accessibilityIdentifier = "expand"
        expand.pad = UIEdgeInsets(top: 4, left: 14, bottom: 8, right: 8)      // 展开箭头原来只有 36×26，手指一偏就按不到
        expand.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        scroll.delaysContentTouches = false          // 候选字按下去立刻有反应，不等 0.15 秒
        scroll.contentInsetAdjustmentBehavior = .never   // 键盘里没有安全区可让，别给横滑起点掺水分
        let gapTap = UITapGestureRecognizer(target: self, action: #selector(gapTapped(_:)))
        gapTap.cancelsTouchesInView = false          // 只是补「缝里点按落空」的空档，别影响按钮和滑动
        gapTap.delegate = self
        scroll.addGestureRecognizer(gapTap)
        setExpanded(false)
        stack.axis = .horizontal
        stack.spacing = 2
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(stack)
        undo.setTitle("撤销", for: .normal)
        undo.titleLabel?.font = .systemFont(ofSize: 14)
        undo.setTitleColor(.label, for: .normal)
        undo.setTitleColor(.secondaryLabel, for: .highlighted)
        undo.pad = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        undo.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        undo.isHidden = true
        mic.layer.cornerRadius = Self.circle / 2
        mic.hitOutset = 8
        mic.accessibilityIdentifier = "mic"
        mic.addTarget(self, action: #selector(micTapped), for: .touchDown)
        circleStyle(hide, symbol: "chevron.down", size: 17, id: "hide", label: "收起键盘")
        hide.addTarget(self, action: #selector(hideTapped), for: .touchDown)
        circleStyle(gear, symbol: "gearshape", size: 18, id: "gear", label: "键盘设置")
        gear.addTarget(self, action: #selector(gearTapped), for: .touchDown)
        xmark.setTitle("✕", for: .normal)
        xmark.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        xmark.setTitleColor(.secondaryLabel, for: .normal)
        xmark.setTitleColor(.label, for: .highlighted)
        xmark.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : UIColor(white: 0.92, alpha: 1) }
        xmark.layer.cornerRadius = 13
        xmark.accessibilityIdentifier = "xmark"
        xmark.accessibilityLabel = "关掉联想"
        xmark.pad = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        xmark.addTarget(self, action: #selector(xmarkTapped), for: .touchUpInside)
        xmark.isHidden = true
        wave.isHidden = true
        for v in [statusLabel, wave, compLabel, expand, scroll, undo, mic, hide, gear, xmark] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        compLeading = compLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            mic.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mic.centerYAnchor.constraint(equalTo: centerYAnchor),
            mic.widthAnchor.constraint(equalToConstant: Self.circle),
            mic.heightAnchor.constraint(equalToConstant: Self.circle),
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: Self.circle),         // 以前是一个看不见边的小箭头，用户按好几下都按不到；现在是看得见的白圆，整个圆（再往外 8）都能按
            hide.heightAnchor.constraint(equalToConstant: Self.circle),
            gear.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -10),
            gear.centerYAnchor.constraint(equalTo: centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: Self.circle),
            gear.heightAnchor.constraint(equalToConstant: Self.circle),
            xmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            xmark.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            xmark.widthAnchor.constraint(equalToConstant: 26),
            xmark.heightAnchor.constraint(equalToConstant: 26),
            undo.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -4),
            undo.centerYAnchor.constraint(equalTo: centerYAnchor),
            undo.widthAnchor.constraint(equalToConstant: 44),
            statusLabel.leadingAnchor.constraint(equalTo: mic.trailingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: undo.leadingAnchor, constant: -4),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            wave.leadingAnchor.constraint(equalTo: mic.trailingAnchor, constant: 12),
            wave.trailingAnchor.constraint(equalTo: gear.leadingAnchor, constant: -8),
            wave.centerYAnchor.constraint(equalTo: centerYAnchor),
            wave.heightAnchor.constraint(equalToConstant: 36),
            // 上一行：拼音 + 展开箭头
            compLeading,
            compLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            compLabel.heightAnchor.constraint(equalToConstant: 22),
            compLabel.trailingAnchor.constraint(lessThanOrEqualTo: expand.leadingAnchor, constant: -6),
            expand.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            expand.centerYAnchor.constraint(equalTo: compLabel.centerYAnchor),
            expand.widthAnchor.constraint(equalToConstant: 36),
            expand.heightAnchor.constraint(equalToConstant: 26),
            // 下一行：候选字（麦克风让位，用满整条）
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: compLabel.bottomAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        showStatus("", .label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    /// 白色圆形按钮（仿豆包顶栏的收起、设置）：圆底 + 一点点阴影，深色模式下是灰的；整个圆都是按的范围
    private func circleStyle(_ b: KeyButton, symbol: String, size: CGFloat, id: String, label: String) {
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)), for: .normal)
        b.tintColor = .label
        b.normalColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.40, alpha: 1) : .white }
        b.pressedColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.78, alpha: 1) }
        b.backgroundColor = b.normalColor
        b.layer.cornerRadius = Self.circle / 2
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.2
        b.layer.shadowRadius = 0
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.hitOutset = 8
        b.accessibilityIdentifier = id
        b.accessibilityLabel = label
    }

    private func idleLayout(_ on: Bool) {      // on = 不打字：麦克风和收起箭头露出来，打字时候选栏的东西露出来
        mic.isHidden = !on
        hide.isHidden = !on
        gear.isHidden = !on
        compLabel.isHidden = on
        expand.isHidden = on
        scroll.isHidden = on
        xmark.isHidden = true      // ✕ 只在联想预测那一行出现
    }

    func showStatus(_ text: String, _ color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
        statusLabel.isHidden = false
        wave.isHidden = true
        idleLayout(true)
    }

    /// 说话时：声波代替状态文字
    func showWave() {
        statusLabel.isHidden = true
        wave.isHidden = false
        idleLayout(true)
    }

    func setLevels(_ v: [Double]) { wave.levels = v }

    /// 声波现在是不是显示着（测试用）
    var waveShown: Bool { !wave.isHidden }

    func setMic(symbol: String, fill: UIColor, tint: UIColor) {
        mic.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        mic.tintColor = tint
        mic.normalColor = fill
        mic.pressedColor = fill.withAlphaComponent(0.6)
    }

    func setExpanded(_ on: Bool) {
        expand.setImage(UIImage(systemName: on ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
    }

    private var shownComp = ""
    private var shownItems: [String] = []
    private var shownFirst = true

    func showCandidates(comp: String, items: [String]) {
        statusLabel.isHidden = true
        wave.isHidden = true
        idleLayout(false)
        undo.isHidden = true
        compLeading.constant = 10
        setInsets(left: 0, right: 0)
        fill(comp: comp, items: items, first: true)
    }

    /// 不在拼字时的联想预测：上一行写上文最后一个词，下一行是它后面可能接的词（左边留给麦克风；收起、齿轮跟打字时一样让位；右上一颗 ✕ 可以关掉这整行）
    func showPredictions(ctx: String, items: [String]) {
        statusLabel.isHidden = true
        wave.isHidden = true
        undo.isHidden = true
        mic.isHidden = false
        hide.isHidden = true
        gear.isHidden = true
        xmark.isHidden = false      // 联想行右边的 ✕：关掉联想，回到最开始的顶栏
        compLabel.isHidden = false
        scroll.isHidden = false
        expand.isHidden = true
        compLeading.constant = 58
        setInsets(left: 56, right: 52)      // 右边留 ✕ 的位置
        fill(comp: ctx + " …", items: items, first: false)
    }

    /// 候选横滑区两头留空（避开麦克风和收起箭头），并让第一个候选从左边留空之后开始排
    private func setInsets(left: CGFloat, right: CGFloat) {
        scroll.contentInset.left = left
        scroll.contentInset.right = right
    }

    private func fill(comp: String, items: [String], first: Bool) {
        if comp == shownComp, items == shownItems, first == shownFirst, !pool.isEmpty { return }   // 没变就不重画（重画会把横滑位置和正在按的候选搞丢）
        let keepPlace = comp == shownComp && first == shownFirst && !pool.isEmpty   // 同一串拼音的候选只是补全（后台引擎 / 个人学习又算出来新词）：横滑位置不动
        shownComp = comp
        shownItems = items
        shownFirst = first
        compLabel.text = comp
        while pool.count < items.count {
            let b = UIButton(type: .custom)
            b.titleLabel?.font = .systemFont(ofSize: 21)
            b.setTitleColor(.label, for: .normal)
            b.setTitleColor(.secondaryLabel, for: .highlighted)
            b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
            b.tag = pool.count
            b.addTarget(self, action: #selector(pick(_:)), for: .touchUpInside)
            b.addTarget(self, action: #selector(pickNear(_:event:)), for: .touchUpOutside)      // 手指稍微滑出按钮边松手也算选中
            stack.addArrangedSubview(b)
            pool.append(b)
        }
        for (i, b) in pool.enumerated() {
            b.setTitle(i < items.count ? items[i] : nil, for: .normal)
            b.setTitleColor(first && i == 0 ? Brand.green : .label, for: .normal)     // 第一个（按空格会选的）用绿色
            b.isHidden = i >= items.count
        }
        if keepPlace {
            // 仿豆包 updatePinyinOnly：正滑着的时候列表更新不拉回最前面，只把位置夹在新的合法范围里
            stack.setNeedsLayout()
            scroll.layoutIfNeeded()
            let minO = -scroll.contentInset.left
            let maxO = max(minO, scroll.contentSize.width - scroll.bounds.width)
            let x = min(max(scroll.contentOffset.x, minO), maxO)
            scroll.setContentOffset(CGPoint(x: x, y: 0), animated: false)
        } else {
            scroll.setContentOffset(CGPoint(x: -scroll.contentInset.left, y: 0), animated: false)
        }
    }
    func showUndo(_ on: Bool) { undo.isHidden = !on }

    @objc private func pick(_ b: UIButton) { onPick?(b.tag) }
    @objc private func pickNear(_ b: UIButton, event: UIEvent?) { if tapIsNear(b, event, scroll: scroll) { onPick?(b.tag) } }
    /// 点按落在候选之间的缝里 / 行两头的留空里：算到旁边最近那个候选（仿豆包 CandidateListView 对「点在 gap 里」的处理）
    @objc private func gapTapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let b = nearestCandidate(at: g.location(in: scroll)) else { return }
        pick(b)
    }
    /// scroll 坐标系里离 x 最近、又离得不算远的候选（候选按钮框往两边各让 3pt，把 2pt 的缝隙盖掉）
    private func nearestCandidate(at p: CGPoint) -> UIButton? {
        var best: (UIButton, CGFloat)?
        for b in pool where !b.isHidden {
            let f = stack.convert(b.frame, to: scroll)
            if p.y < f.minY - 2 || p.y > f.maxY + 2 { continue }
            let d = max(f.minX - p.x, p.x - f.maxX, 0)
            if d <= 3, best == nil || d < best!.1 { best = (b, d) }
            if best != nil, best!.1 == 0 { break }
        }
        return best?.0
    }
    @objc private func undoTapped() { onUndo?() }
    @objc private func micTapped() { onMic?() }
    @objc private func expandTapped() { onExpand?() }
    @objc private func hideTapped() { onHide?() }
    @objc private func gearTapped() { onGear?() }
    @objc private func xmarkTapped() { onXmark?() }
}

extension CandidateBar: UIGestureRecognizerDelegate {
    /// 手指摸在候选字上交给按钮自己；只有点在缝里 / 留空区才来这里
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

/// 九键左边的音节列表：打字时列出「下一个音节」可能是哪几个（ni / mi / o…），点一个就选定；可上下滑
final class SyllableColumn: UIScrollView, UIScrollViewDelegate {
    var onPick: ((Int) -> Void)?
    private var pool: [KeyButton] = []
    private var count = 0
    private let maker: () -> KeyButton
    private let rowH: CGFloat, gap: CGFloat

    init(rowH: CGFloat, gap: CGFloat, maker: @escaping () -> KeyButton) {
        self.rowH = rowH
        self.gap = gap
        self.maker = maker
        super.init(frame: .zero)
        showsVerticalScrollIndicator = false
        delaysContentTouches = false          // 按下去立刻有反应，不等 0.15 秒
        accessibilityIdentifier = "syllables"
        isHidden = true
        delegate = self      // 自己给自己的 delegate：滚动结束好把记着的「归零」补上
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    func setItems(_ new: [String]) {
        count = new.count
        while pool.count < new.count {
            let b = maker()
            b.tag = pool.count
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)      // 要能上下滑，所以松手才算点
            b.addTarget(self, action: #selector(tappedNear(_:event:)), for: .touchUpOutside)
            addSubview(b)
            pool.append(b)
        }
        for (i, b) in pool.enumerated() {
            b.setTitle(i < new.count ? new[i] : nil, for: .normal)
            b.isHidden = i >= new.count
        }
        if isTracking || isDragging || isDecelerating {     // 手指还按在列表上：别把路线从脚下抽走（等回到 idle 再归零）
            pendingZero = true
        } else {
            pendingZero = false
            setContentOffset(.zero, animated: false)
        }
        setNeedsLayout()
    }

    /// 列表正被手指跟踪时的「归零」先记着，等滚动停下来再补
    private var pendingZero = false

    override func touchesShouldCancel(in view: UIView) -> Bool { true }      // 在音节字上按下也能直接滑

    func scrollViewDidEndDecelerating(_ sv: UIScrollView) { settleIfIdle() }
    func scrollViewDidEndDragging(_ sv: UIScrollView, willDecelerate: Bool) { if !willDecelerate { settleIfIdle() } }

    private func settleIfIdle() {
        guard pendingZero, !(isTracking || isDragging || isDecelerating) else { return }
        pendingZero = false
        setContentOffset(.zero, animated: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for i in 0..<count { pool[i].frame = CGRect(x: 0, y: CGFloat(i) * (rowH + gap), width: bounds.width, height: rowH) }
        contentSize = CGSize(width: bounds.width, height: max(bounds.height, CGFloat(count) * (rowH + gap) - gap))
    }

    @objc private func tapped(_ b: UIButton) { onPick?(b.tag) }
    @objc private func tappedNear(_ b: UIButton, event: UIEvent?) { if tapIsNear(b, event, scroll: self) { onPick?(b.tag) } }
}

/// 键盘设置面板（顶栏的齿轮打开，盖住按键区；内容多了可以上下滑）：按键震动开关、拼音键盘 26键 / 九键、记住我的用词、模糊音
final class SettingsPanel: UIView {
    let haptic = UISwitch()
    private(set) var fuzzyChips: [UIButton] = []
    var onFuzzy: ((Int) -> Void)?       // 打开的模糊音位掩码（1 z/zh c/ch s/sh，2 n/l，4 an/ang en/eng in/ing，8 f/h）
    let layoutSeg = UISegmentedControl(items: ["26键", "九键"])
    let learn = UISwitch()
    let clearLearn = UIButton(type: .custom)
    private let note = UILabel()
    var onHaptic: ((Bool) -> Void)?
    var onLayout: ((Bool) -> Void)?       // true = 九键
    var onLearn: ((Bool) -> Void)?
    var onClearLearn: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.93, alpha: 1) }
        accessibilityIdentifier = "settings"
        isHidden = true
        func label(_ t: String, _ size: CGFloat, _ color: UIColor) -> UILabel {
            let l = UILabel()
            l.text = t
            l.font = .systemFont(ofSize: size)
            l.textColor = color
            return l
        }
        let title = label("键盘设置", 15, .secondaryLabel)
        let done = UIButton(type: .custom)
        done.setTitle("完成", for: .normal)
        done.setTitleColor(Brand.green, for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.accessibilityIdentifier = "settings-done"
        done.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        let head = UIStackView(arrangedSubviews: [title, UIView(), done])
        head.alignment = .center
        haptic.onTintColor = Brand.green
        haptic.accessibilityIdentifier = "haptic-switch"
        haptic.addTarget(self, action: #selector(hapticChanged), for: .valueChanged)
        layoutSeg.selectedSegmentTintColor = Brand.green
        layoutSeg.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        layoutSeg.accessibilityIdentifier = "layout-seg"
        layoutSeg.addTarget(self, action: #selector(layoutChanged), for: .valueChanged)
        learn.onTintColor = Brand.green
        learn.accessibilityIdentifier = "learn-switch"
        learn.addTarget(self, action: #selector(learnChanged), for: .valueChanged)
        clearLearn.setTitle("清空", for: .normal)
        clearLearn.setTitleColor(.systemRed, for: .normal)
        clearLearn.setTitleColor(.secondaryLabel, for: .highlighted)
        clearLearn.titleLabel?.font = .systemFont(ofSize: 15)
        clearLearn.accessibilityIdentifier = "learn-clear"
        clearLearn.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        let learnBox = UIStackView(arrangedSubviews: [clearLearn, learn])
        learnBox.spacing = 14
        learnBox.alignment = .center
        func row(_ t: String, _ c: UIView) -> UIStackView {
            let r = UIStackView(arrangedSubviews: [label(t, 17, .label), UIView(), c])
            r.alignment = .center
            r.heightAnchor.constraint(equalToConstant: 38).isActive = true
            return r
        }
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        // 模糊音（二期）：说话带口音、z/zh n/l an/ang f/h 分不清的人打开；四个小开关一排
        func chip(_ t: String, _ bit: Int) -> UIButton {
            let b = UIButton(type: .custom)
            b.setTitle(t, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            b.setTitleColor(.label, for: .normal)
            b.setTitleColor(.white, for: .selected)
            b.layer.cornerRadius = 8
            b.tag = bit
            b.accessibilityIdentifier = "fuzzy-\(bit)"
            b.addTarget(self, action: #selector(fuzzyTapped(_:)), for: .touchUpInside)
            fuzzyChips.append(b)
            return b
        }
        let chips = UIStackView(arrangedSubviews: [chip("z/zh", 1), chip("n/l", 2), chip("an/ang", 4), chip("f/h", 8)])
        chips.distribution = .fillEqually
        chips.spacing = 8
        chips.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let fuzzyNote = label("模糊音（口音重时打开）：z/zh 含 c/ch、s/sh；an/ang 含 en/eng、in/ing。打开后打 si 也会出「是、时」。", 12, .secondaryLabel)
        fuzzyNote.numberOfLines = 0
        let v = UIStackView(arrangedSubviews: [head, row("按键震动", haptic), row("拼音键盘", layoutSeg), row("记住我的用词", learnBox), label("模糊音", 17, .label), chips, fuzzyNote, note])
        v.axis = .vertical
        v.spacing = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.accessibilityIdentifier = "settings-scroll"
        addSubview(scroll)
        scroll.addSubview(v)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            v.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            v.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            v.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -10),
            v.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    /// 打开面板时把开关摆成当前的值
    /// learned = 已经记住了几条；cleared = 刚点过清空（说明文字里写一声，不弹窗）
    func sync(haptic on: Bool, nine: Bool, fullAccess: Bool, learn learnOn: Bool = true, learned: Int = 0, cleared: Bool = false, fuzzy: Int = 0) {
        haptic.isOn = on
        for c in fuzzyChips { paint(c, on: fuzzy & c.tag != 0) }
        layoutSeg.selectedSegmentIndex = nine ? 1 : 0
        learn.isOn = learnOn
        clearLearn.isHidden = !learnOn || learned == 0
        let tip = fullAccess ? "九键：中间是 ABC / DEF…，左边点音节可以选定拼哪个。" : "按键震动要在 设置 → 通用 → 键盘 → 键盘 → 芽音 里打开「允许完全访问」才有。"
        let mem = cleared ? "学习记录已清空。" : (learnOn ? "选过的词、说过的话只存在这台手机上，常用的会排到前面（已记住 \(learned) 条）。" : "")
        note.text = mem.isEmpty ? tip : mem + "\n" + tip
    }

    private func paint(_ c: UIButton, on: Bool) {
        c.isSelected = on
        c.backgroundColor = on ? Brand.green : UIColor.systemFill
    }

    @objc private func fuzzyTapped(_ c: UIButton) {
        paint(c, on: !c.isSelected)
        onFuzzy?(fuzzyChips.filter { $0.isSelected }.reduce(0) { $0 | $1.tag })
    }

    @objc private func learnChanged() { onLearn?(learn.isOn) }
    @objc private func clearTapped() { onClearLearn?() }
    @objc private func hapticChanged() { onHaptic?(haptic.isOn) }
    @objc private func layoutChanged() { onLayout?(layoutSeg.selectedSegmentIndex == 1) }
    @objc private func closeTapped() { onClose?() }
}

/// 点候选栏的向下箭头展开：所有候选铺满键盘区（盖住按键），可上下滑，点一个就选它
final class CandidatePanel: UIScrollView {
    var onPick: ((Int) -> Void)?
    private var pool: [KeyButton] = []
    private var items: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.93, alpha: 1) }
        showsVerticalScrollIndicator = false
        accessibilityIdentifier = "panel"
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    func setItems(_ new: [String]) {
        items = new
        while pool.count < new.count {
            let b = KeyButton(type: .custom)
            b.titleLabel?.font = .systemFont(ofSize: 21)
            b.setTitleColor(.label, for: .normal)
            b.normalColor = .clear
            b.pressedColor = UIColor.systemFill
            b.layer.cornerRadius = 6
            b.tag = pool.count
            b.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            b.addTarget(self, action: #selector(tappedNear(_:event:)), for: .touchUpOutside)
            addSubview(b)
            pool.append(b)
        }
        for (i, b) in pool.enumerated() {
            b.setTitle(i < new.count ? new[i] : nil, for: .normal)
            b.setTitleColor(i == 0 ? Brand.green : .label, for: .normal)
            b.isHidden = i >= new.count
        }
        setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowH: CGFloat = 46, pad: CGFloat = 4
        var x = pad, y: CGFloat = 0
        for (i, t) in items.enumerated() {
            let w = max(46, ceil((t as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 21)]).width) + 24)
            if x + w > bounds.width - pad, x > pad { x = pad; y += rowH }
            pool[i].frame = CGRect(x: x, y: y, width: w, height: rowH)
            x += w
        }
        contentSize = CGSize(width: bounds.width, height: y + rowH)
    }

    @objc private func tapped(_ b: UIButton) { onPick?(b.tag) }
    @objc private func tappedNear(_ b: UIButton, event: UIEvent?) { if tapIsNear(b, event, scroll: self) { onPick?(b.tag) } }
}

/// 语音键盘：语音听写（主 App 录音，这里收字）+ 中文拼音 / 英文 / 数字符号三套打字键盘。
/// 键盘扩展不能用麦克风、内存也小，所以录音在主 App 里做，这里只发指令、收文字。
/// 键盘的根视图：声明「我这里可以放按键点击声」，UIDevice.playInputClick() 才会响（跟随系统设置里的「键盘反馈 → 声音」）
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// 中 / 英 切换键上的图案（仿豆包输入法）：「中」在左上、「英」在右下，各带一个弯箭头；当前的那个绿色加粗放大，另一个灰色缩小
final class ModeGlyph: UIView {
    let zh = UILabel()
    let en = UILabel()
    private let hooks = CAShapeLayer()
    var chinese = true { didSet { apply(); setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(zh)
        addSubview(en)
        zh.text = "中"
        en.text = "英"
        hooks.fillColor = nil
        hooks.lineWidth = 1.2
        hooks.lineCap = .round
        hooks.lineJoin = .round
        layer.addSublayer(hooks)
        apply()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: ModeGlyph, _) in v.apply() }      // 深浅色切换时箭头颜色跟着换
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不用") }

    private func apply() {
        let on: (UILabel) -> Void = { $0.font = .boldSystemFont(ofSize: 17); $0.textColor = Brand.green }
        let off: (UILabel) -> Void = { $0.font = .systemFont(ofSize: 12); $0.textColor = .secondaryLabel }
        if chinese { on(zh); off(en) } else { off(zh); on(en) }
        hooks.strokeColor = UIColor.secondaryLabel.cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        zh.sizeToFit()
        en.sizeToFit()
        zh.frame.origin = CGPoint(x: 6, y: 4)
        en.frame.origin = CGPoint(x: bounds.width - en.bounds.width - 6, y: bounds.height - en.bounds.height - 4)
        // 「中」右上一个往下拐的箭头，「英」左下一个往上拐的箭头
        let p = UIBezierPath()
        let a = CGPoint(x: zh.frame.maxX + 2, y: zh.frame.minY + 3)
        p.move(to: a)
        p.addLine(to: CGPoint(x: a.x + 5, y: a.y))
        p.addQuadCurve(to: CGPoint(x: a.x + 8, y: a.y + 5), controlPoint: CGPoint(x: a.x + 8, y: a.y))
        p.move(to: CGPoint(x: a.x + 5.5, y: a.y + 3))
        p.addLine(to: CGPoint(x: a.x + 8, y: a.y + 5.5))
        p.addLine(to: CGPoint(x: a.x + 10.5, y: a.y + 3))
        let c = CGPoint(x: en.frame.minX - 2, y: en.frame.maxY - 3)
        p.move(to: c)
        p.addLine(to: CGPoint(x: c.x - 5, y: c.y))
        p.addQuadCurve(to: CGPoint(x: c.x - 8, y: c.y - 5), controlPoint: CGPoint(x: c.x - 8, y: c.y))
        p.move(to: CGPoint(x: c.x - 10.5, y: c.y - 3))
        p.addLine(to: CGPoint(x: c.x - 8, y: c.y - 5.5))
        p.addLine(to: CGPoint(x: c.x - 5.5, y: c.y - 3))
        hooks.path = p.cgPath
        hooks.frame = bounds
    }
}

final class KeyboardViewController: UIInputViewController {
    private let haptic = UIImpactFeedbackGenerator(style: .light)   // 按键轻震（要「允许完全访问」）
    private(set) var hapticOn = UserDefaults.standard.object(forKey: "haptic") as? Bool ?? true     // 设置面板里的「按键震动」开关
    private(set) var nine = UserDefaults.standard.object(forKey: "nine") as? Bool ?? false           // 中文用九键（false = 26 键）
    private(set) var fuzzMask = UserDefaults.standard.integer(forKey: "fuzzy")                      // 打开的模糊音（位掩码，0 = 全关）
    private let settingsPanel = SettingsPanel()
    private var nineSyll: SyllableColumn?        // 九键左边的音节列表
    private var ninePunct: UIStackView?          // 九键左边平时的 ，。？
    private var nineClear: KeyButton?            // 九键右边第二个键：拼字时「重输」，平时「！」
    private var nineOpts: [String] = []
    private var nineStart = 0                    // 音节列表选的是输入串里从第几个字符开始的数字
    private var prevLoad = ""
    private var lseq = Int(Date().timeIntervalSince1970)      // 键盘日志序号：用时间起头，键盘进程重启后仍比主 App 记着的大
    private var lastLog = ""
    private var lastDiag = (pid: -1, at: Date.distantPast)
    // MARK: 语音
    private let candBar = CandidateBar()
    private var statusText = ""
    private var statusHint = false      // 状态文字只是闲时的提示（语音待命中…）：有联想预测时让位给预测，出错 / 录音中 / 整理中的不让
    private var statusColor = UIColor.label
    private enum MicStyle { case idle, recording, busy, off }
    private var micStyle = MicStyle.idle
    private var listeners: [DarwinListener] = []
    private var refreshTimer: Timer?
    private var pollEvery: TimeInterval = 0.5     // 说话时 0.1 秒问一次（画声波、让字跟得上），平时 0.5 秒
    private var visible = false
    private var deleteTimer: Timer?
    private var clearing = false           // 这次在删除键上左滑清空了（松手不再当点按）
    private var pressDeleted: String?      // 这次按下去就删掉的那个字（左滑清空时算进「撤销」）
    private var clearedText = ""           // 删除键左滑清空时清掉的字，顶栏「撤销」放回去用
    private(set) var live = ""     // 这次听写里「当前这一段」已经打进输入框的文字：说话时跟着识别结果变，润色好了被替换
    private var liveSID = -1       // live 是第几次录音的
    private var liveFinal = false  // 已经收到过结果（再替换前要先确认光标还在这段文字后面）
    private var liveDoc: UUID?     // live 这段字是打进哪个输入框的：结果回来时已经换了输入框（新窗口）就不再往里塞
    private var liveBase = 0       // live 是从 App 那边第几个实字之后开始的（前面的已经冻结）
    private var myCuts = 0         // 我这边冻结过几回；App 回报的次数对得上，它发来的文字才是新的
    private var dead = -1          // 用户撤销 / 说完后等润色时又动手改过的那次录音，后面的结果不再往里替换
    private var recordingNow = false
    private var lastCancel = Date.distantPast      // 上次让主 App 作废「别的输入框的录音」是什么时候（没回音就隔一秒再说一遍）
    private var needForeignCheck = false           // 刚弹出 / 刚换了输入框：拿到下一份快照时查一次「这次录音是不是别的输入框的」。平时（轮询、后台实例被通知叫醒）不查
    /// 测试用：宿主进程号（真机上读 _hostProcessIdentifier）
    var pidProbe: (() -> Int?)?
    private var lastAction = Date.distantPast      // 上次按键 / 选词的时间：刚打完字时宿主报的「输入框空了」可能还没跟上，不当真
    private var cseq = 0
    private var dseq = 0
    private(set) var lastCmd = ""
    private var lastExtra: [String: Any] = [:]
    private var lastResend = Date.distantPast
    private var snap = Link.Snap()
    private let preview = KeyPreview()
    private weak var rootView: KeyboardRoot?
    private weak var returnKey: KeyButton?
    private var shownReturn: String??
    private let panel = CandidatePanel()
    private var panelOpen = false
    private weak var spaceKey: KeyButton?
    private var spaceWave: WaveView?
    private var spaceHint: UILabel?
    private var failedPolls = 0
    private var previewHide: DispatchWorkItem?
    private var spaceTimer: Timer?
    private var spaceLong = false  // 空格已经按够久了，算「按住说话」
    private var spaceSwiping = false     // 这次在空格上横着滑了：移光标，松手不打空格
    private var spaceSteps = 0           // 这次滑动已经挪了几个字
    var pttActive = false  // 这次按住是我发的开始，松手要发结束（测试要改它，所以不是 private）

    // MARK: 点了没反应的防线
    private var flashText = ""
    private var flashColor = UIColor.label
    private var flashUntil = Date.distantPast       // 在这之前，状态字显示 flashText（比平时的状态多留几秒，免得原因被下一次刷新盖掉）
    private var opening = false                     // 正在打开主 App（别重复点）
    private var openToken = 0                       // 每次开始 / 键盘重新出现都换一个，旧的计时回来发现对不上就不再动作
    private var hideEpoch = 0                       // 键盘每离开屏幕一次 +1
    private var outboxPending = UserDefaults.standard.stringArray(forKey: "outbox")?.isEmpty == false
    /// 测试用：不真的去调 UIApplication 打开地址（测试宿主就是主 App 自己，会真的跳进去弹麦克风授权）
    var suppressRealOpen = false
    /// 测试用：宿主不存在，hasFullAccess 永远是 false
    var fullAccessProbe: (() -> Bool)?
    /// 测试用：没有宿主，收起键盘的调用换成这个
    var dismissAction: (() -> Void)?
    /// 测试用：当前输入框的编号（真机上读 textDocumentProxy.documentIdentifier）
    var docProbe: (() -> UUID)?
    private(set) var collapseCount = 0
    private var fullAccess: Bool { fullAccessProbe?() ?? hasFullAccess }
    /// 状态栏现在写的字（测试用）
    var shownStatus: String { statusText }
    /// 测试用：接线员（模拟手指按下 / 滑动 / 抬起）和「键盘视图坐标里这个点会按到哪个键」
    var router: KeyboardRoot? { rootView }
    var symbolSink: ((String) -> Void)?          // 测试用：打了哪个符号 / 数字
    var cursorProbe: ((Int) -> Void)?            // 测试用：光标挪了几个字
    var returnTypeProbe: (() -> UIReturnKeyType?)?      // 测试用：输入框要求的回车键类型
    func keyUnder(_ p: CGPoint) -> KeyButton? { rootView.flatMap { r in r.key(at: r.convert(p, from: view)) } }

    // MARK: 打字
    private enum Layer { case letters, numbers }
    private enum Shift { case off, once, caps }
    private var layer = Layer.letters
    private var chinese = UserDefaults.standard.object(forKey: "zh") as? Bool ?? true
    private var shift = Shift.off
    private var lastShiftTap = Date.distantPast
    private(set) var buffer = ""                 // 拼音输入串（含分词符 '）
    private var cands: [PinyinCandidate] = []
    private var panelList: [PinyinCandidate] = []
    private lazy var words: EnglishWords? = {
        guard let path = Bundle(for: KeyboardViewController.self).path(forResource: "enwords", ofType: "txt") else { return nil }
        return EnglishWords(path: path)
    }()
    private lazy var emoji: EmojiIndex? = {
        guard let path = Bundle(for: KeyboardViewController.self).path(forResource: "emoji", ofType: "txt") else { return nil }
        return EmojiIndex(path: path)
    }()
    private lazy var engine: PinyinEngine? = {
        let bundle = Bundle(for: KeyboardViewController.self)
        guard let path = bundle.path(forResource: "pinyin", ofType: "dat"),
              let d = PinyinDict(path: path) else { return nil }
        let lm = bundle.path(forResource: "lm", ofType: "dat").flatMap { LMDict(path: $0) }      // 二元语言模型：整句选词看上文 + 联想预测
        let e = PinyinEngine(dict: d, lm: lm)
        if self.learnOn { e.user = Self.loadUser() }
        e.fuzz = self.fuzzMask
        return e
    }()

    // MARK: 个人学习（说明见 UserModel / tools/bench/learn.py）
    /// 学到的东西存在这（键盘扩展自己的容器）；测试换成临时文件
    static var userFile: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("voicekb-user.txt")
    private(set) var learnOn = UserDefaults.standard.object(forKey: "learn") as? Bool ?? true      // 设置面板里的「记住我的用词」
    /// 这次拼字（输入串从有到空）选出来的几段：（文字, 吃掉的拼音字母, 切词）
    private var session: [(text: String, key: String, parts: [String])] = []
    private var sessionPrev: String?           // 这次拼字前面的上文最后一个词
    private var userSave: DispatchWorkItem?

    private static func loadUser() -> UserModel {
        UserModel(text: (try? String(contentsOf: userFile, encoding: .utf8)) ?? "")
    }

    /// 开始拼一个新词：记下上文（学词对用），上一回没拼完的作废
    private func startSession() {
        session = []
        sessionPrev = contextWord()
    }

    /// 选了一段：记下来；输入串选空了 = 这次拼字完了，按规矩学（每段的切词记词频、词对；分 ≥2 段选出来的 2~6 个字记成自造词）
    private func noteCommit(_ c: PinyinCandidate, letters: String) {
        guard engine?.user != nil else { return }
        session.append((c.text, !c.fix.isEmpty ? c.fix : (!c.key.isEmpty ? c.key : letters), c.parts.isEmpty ? [c.text] : c.parts))
        guard buffer.isEmpty else { return }
        defer { session = [] }
        guard let e = engine, let u = e.user else { return }
        let chunks = session, prev = sessionPrev
        onEngine {
            u.learn(chunks.flatMap { $0.parts }, prev: prev)
            if chunks.count >= 2 {
                let text = chunks.map { $0.text }.joined()
                let key = Array(chunks.map { $0.key }.joined().utf8)
                if (2...6).contains(text.unicodeScalars.count), !e.hasWord(key, text) { u.addPhrase(key: key, word: text) }
            }
        }
        scheduleUserSave()
    }

    private func scheduleUserSave() {
        userSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveUser() }
        userSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func saveUser() {
        userSave?.cancel()
        userSave = nil
        guard let u = engine?.user else { return }
        let url = Self.userFile
        onEngine {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? u.dump().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 已经记住了几条（设置面板上写）
    private var learnedCount: Int {
        guard let u = engine?.user else { return 0 }
        return engineQueue.sync { u.size }
    }

    private func setLearn(_ on: Bool) {
        if !on { saveUser() }
        learnOn = on
        UserDefaults.standard.set(on, forKey: "learn")
        let e = engine
        engineQueue.sync { e?.user = on ? Self.loadUser() : nil }
        session = []
        settingsPanel.sync(haptic: hapticOn, nine: nine, fullAccess: fullAccess, learn: learnOn, learned: learnedCount, fuzzy: fuzzMask)
    }

    private func clearLearned() {
        userSave?.cancel()
        userSave = nil
        let e = engine, on = learnOn, url = Self.userFile
        engineQueue.sync {
            try? FileManager.default.removeItem(at: url)
            if on { e?.user = UserModel() }
        }
        session = []
        settingsPanel.sync(haptic: hapticOn, nine: nine, fullAccess: fullAccess, learn: learnOn, learned: 0, cleared: true, fuzzy: fuzzMask)
    }
    private var ctxTail = ""                 // 光标前已经打进输入框的最后一小段字（联想预测、按上文选词用）
    private var predictions: [String] = []   // 不拼字时的联想预测（接在上文最后一个词后面最可能的词 / 标点）
    private let keyArea = UIStackView()
    private var letterKeys: [(KeyButton, String)] = []
    private var shiftKey: KeyButton?
    private var modeKey: KeyButton?

    override func loadView() {
        // 加载标记：到 viewDidAppear 才清掉。下次加载时它还在 = 上一次没加载完（崩了 / 被系统杀了），日志里会写一行
        let d = UserDefaults.standard
        if let t = d.object(forKey: "loading") as? Double { prevLoad = "上次加载没走完（\(Int(Date().timeIntervalSince1970 - t)) 秒前）" }
        d.set(Date().timeIntervalSince1970, forKey: "loading")
        view = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        HostApp.harvest()
        refreshReturn()
        if visible { needForeignCheck = true }
        if dropForeignVoice() { render() }        // 键盘没收起、直接换到了另一个输入框
        // 输入框被宿主清空了（App 自己的发送按钮发出去了、换了新对话）：顶栏回到最开始的样子
        if !composing, !recordingNow, Date().timeIntervalSince(lastAction) > 0.3, !textDocumentProxy.hasText,
           (contextBefore() ?? "").isEmpty, (textDocumentProxy.documentContextAfterInput ?? "").isEmpty,
           !predictions.isEmpty || !live.isEmpty || !ctxTail.isEmpty {
            resetAfterSend()
        }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        HostApp.harvest()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        UIView.setAnimationsEnabled(false)       // 键盘上一切立刻显示，不要任何过渡动画
        build()
        candBar.onPick = { [weak self] i in self?.pick(i) }
        candBar.onExpand = { [weak self] in self?.togglePanel() }
        panel.onPick = { [weak self] i in self?.pickFromPanel(i) }
        candBar.onUndo = { [weak self] in self?.undoVoice() }
        candBar.onMic = { [weak self] in self?.micTapped() }
        candBar.onGear = { [weak self] in self?.toggleSettings() }
        candBar.onXmark = { [weak self] in self?.closePredictions() }
        settingsPanel.onClose = { [weak self] in self?.closeSettings() }
        settingsPanel.onHaptic = { [weak self] on in self?.setHaptic(on) }
        settingsPanel.onLayout = { [weak self] on in self?.setNine(on) }
        settingsPanel.onLearn = { [weak self] on in self?.setLearn(on) }
        settingsPanel.onFuzzy = { [weak self] m in self?.setFuzzy(m) }
        settingsPanel.onClearLearn = { [weak self] in self?.clearLearned() }
        candBar.onHide = { [weak self] in self?.collapse() }
        applyMic()
        listeners = [
            DarwinListener(KB.nState) { [weak self] in DispatchQueue.main.async { self?.refresh() } },
            DarwinListener(KB.nResult) { [weak self] in DispatchQueue.main.async { self?.refresh() } },
        ]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        HostApp.keyboardWillAppear()
        haptic.prepare()
        visible = true
        openToken &+= 1          // 从主 App 回来（或重新弹出）了：还在路上的「打开主 App」计时作废
        if opening { flashUntil = .distantPast }      // 「正在打开…」的字不用再留；失败的红字还留着
        opening = false
        let pid = HostApp.hostPID(self) ?? -1
        if pid != lastDiag.pid || Date().timeIntervalSince(lastDiag.at) > 30 {       // 换了个 App 或隔了 30 秒才报一次
            lastDiag = (pid, Date())
            let ver = Bundle(for: KeyboardViewController.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            klog("键盘出现 v\(ver) " + HostApp.diag(self) + (prevLoad.isEmpty ? "" : "；" + prevLoad))
            prevLoad = ""
        }
        // 重新弹出（换了窗口 / 新对话）：上一处的联想不带过来；换了输入框的话撤销也不留；别的输入框的录音这里当没这回事
        if !composing {
            ctxTail = ""
            predictions = []
            if !recordingNow, !live.isEmpty, liveDoc != nil, currentDoc() != liveDoc { dead = liveSID; live = "" }
        }
        needForeignCheck = true
        dropForeignVoice()
        render()
        refreshBar()
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = nil
        setPoll(pollEvery)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UserDefaults.standard.removeObject(forKey: "loading")      // 加载走完了
        HostApp.harvest()
        // 屏幕边缘的键（q p a l 和最下面一排）会被系统的边缘手势拖慢、甚至吞掉：关掉系统窗口手势的「延迟送触摸」
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if userSave != nil { saveUser() }      // 键盘收起：没来得及存的学习记录马上存（扩展随时可能被系统结束）
        if let r = rootView {
            r.cancelAll()
            if r.stats.down >= 20 { qlog("触摸统计 " + r.stats.summary) }      // 看「按了没反应」是哪一种：没按到键 / 被系统取消 / 滑过去改
            r.resetStats()
        }
        visible = false
        hideEpoch &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func setPoll(_ t: TimeInterval) {
        guard visible, t != pollEvery || refreshTimer == nil else { return }
        pollEvery = t
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: 界面

    private var keyColor: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.40, alpha: 1) : .white } }
    private var keyPressed: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.78, alpha: 1) } }
    private var funcColor: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.68, alpha: 1) } }
    private var funcPressed: UIColor { UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white } }

    // 按键尺寸：10-23 用户嫌键「高了显得窄、更不好按」→ 高 49、列缝 3（键宽约 37）；10-25 又嫌「键之间的缝太窄、容易误触」（豆包是缝 6 × 12、键 34 × 43）→
    // 字母键高 47、列缝 5（键宽约 34，宽高比 0.72）、行缝 9。视觉上缝大了，但触摸不受影响：手指落在缝里归最近的键（KeyboardRoot），没有死角。
    // 键盘总高 = 上边 2 + 候选栏 58 + 4 + 三排字母 3×47 + 三道缝 3×9 + 底排 42 + 下边 4 = 278
    static let letterRowH: CGFloat = 47
    static let bottomRowH: CGFloat = 42
    static let rowGap: CGFloat = 9
    static let colGap: CGFloat = 5
    static let keyboardHeight: CGFloat = 2 + CandidateBar.height + 4 + 3 * letterRowH + 3 * rowGap + bottomRowH + 4

    private func build() {
        candBar.heightAnchor.constraint(equalToConstant: CandidateBar.height).isActive = true
        keyArea.axis = .vertical
        keyArea.spacing = Self.rowGap
        keyArea.distribution = .fill      // 每一排的高度单独定（sizeRows），不再平分
        let root = UIStackView(arrangedSubviews: [candBar, keyArea])
        root.axis = .vertical
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        // 按键区上面盖一块透明的触摸接线板（普通 UIView，不靠 UIStackView 收触摸）
        let pad = KeyboardRoot()
        pad.keyArea = keyArea
        pad.isMultipleTouchEnabled = true      // 每根手指单独跟踪：连打、两个拇指交替不互相顶掉
        pad.onKeyDown = { [weak self] k in self?.keyFeedback(); self?.showPreview(k) }
        pad.onKeyMoved = { [weak self] k, alt in self?.showPreview(k, text: alt) }      // 手指滑到别的键 / 上滑：气泡跟着走，不再响
        pad.onKeyUp = { [weak self] in self?.hidePreview() }
        pad.letterBias = { [weak self] k in self?.hotBias(k) ?? 0 }      // 动态热区
        pad.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pad)
        rootView = pad
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pad.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pad.topAnchor.constraint(equalTo: keyArea.topAnchor, constant: -4),
            pad.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let h = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        h.priority = .defaultHigh
        NSLayoutConstraint.activate([
            h,
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: keyArea.topAnchor),
            panel.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor),
        ])
        settingsPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsPanel)
        NSLayoutConstraint.activate([
            settingsPanel.topAnchor.constraint(equalTo: keyArea.topAnchor),
            settingsPanel.bottomAnchor.constraint(equalTo: keyArea.bottomAnchor),
            settingsPanel.leadingAnchor.constraint(equalTo: keyArea.leadingAnchor),
            settingsPanel.trailingAnchor.constraint(equalTo: keyArea.trailingAnchor),
        ])
        view.addSubview(preview)
        rebuildKeys()
    }

    /// 一个按键。真手指的触摸由 KeyboardRoot 接线：字母 / 符号键（preview）按下冒气泡、松手才打（手指滑到哪个键打哪个）；功能键一按下就响应。
    /// 下面的 touchDown 事件是没有真手指的路（测试、辅助功能）：一次 touchDown = 按下 + 松手。
    private func key(_ title: String? = nil, symbol: String? = nil, isFunction: Bool = false, font: CGFloat = 20, preview: Bool = false,
                     _ action: @escaping () -> Void) -> KeyButton {
        let b = styled(title, symbol: symbol, isFunction: isFunction, font: font)
        if preview {
            b.commitsOnRelease = true
            b.onCommit = action
            b.addAction(UIAction { [weak self, weak b] _ in
                self?.keyFeedback()
                if let b { self?.showPreview(b) }
                action()
            }, for: .touchDown)
            b.addAction(UIAction { [weak self] _ in self?.hidePreview() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        } else {
            b.addAction(UIAction { [weak self] _ in self?.keyFeedback() }, for: .touchDown)
            b.addAction(UIAction { _ in action() }, for: .touchDown)
        }
        return b
    }

    /// 按下去的反馈：轻震一下 + 系统的键盘点击声（声音跟着系统「键盘反馈」开关走）
    private func keyFeedback() {
        if hapticOn {
            haptic.impactOccurred()
            haptic.prepare()
        }
        UIDevice.current.playInputClick()
    }

    // MARK: 键盘设置面板

    private func toggleSettings() {
        if !settingsPanel.isHidden { closeSettings(); return }
        closePanel()
        settingsPanel.sync(haptic: hapticOn, nine: nine, fullAccess: hasFullAccess, learn: learnOn, learned: learnedCount, fuzzy: fuzzMask)
        settingsPanel.isHidden = false
    }

    private func closeSettings() { settingsPanel.isHidden = true }

    private func setHaptic(_ on: Bool) {
        hapticOn = on
        UserDefaults.standard.set(on, forKey: "haptic")
        if on { haptic.impactOccurred() }      // 打开时震一下，让人知道开了
    }

    /// 设置里改了模糊音：存下来、告诉引擎（引擎在后台线程算，改它也排在那个队列里）、正在拼的重新出候选
    func setFuzzy(_ m: Int) {
        fuzzMask = m
        UserDefaults.standard.set(m, forKey: "fuzzy")
        if let e = engine { onEngine { e.fuzz = m } }
        if composing { updateCandidates() }
    }

    private func setNine(_ on: Bool) {
        guard on != nine else { return }
        commitRaw()
        nine = on
        UserDefaults.standard.set(on, forKey: "nine")
        closeSettings()
        rebuildKeys()
    }

    private func showPreview(_ k: KeyButton, text: String? = nil) {
        guard let t = text ?? k.currentTitle, !t.isEmpty else { return }
        previewHide?.cancel()
        preview.show(t, over: k, in: view, fill: keyColor)
    }

    private func hidePreview() {
        previewHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.preview.hide() }
        previewHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: w)     // 轻点一下也让人看得见
    }

    /// 现在显示的放大气泡里的字（测试用）
    var previewText: String? { preview.text }

    /// 顶栏现在是不是在画声波（测试用）
    var barWaveVisible: Bool { candBar.waveShown }

    /// 只管样子、不接动作（🌐 和删除键自己接）
    private func styled(_ title: String? = nil, symbol: String? = nil, isFunction: Bool = false, font: CGFloat = 20) -> KeyButton {
        let b = KeyButton(type: .custom)
        if let title { b.setTitle(title, for: .normal) }
        if let symbol {
            b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            b.tintColor = .label
        }
        b.titleLabel?.font = .systemFont(ofSize: font)
        b.setTitleColor(.label, for: .normal)
        b.normalColor = isFunction ? funcColor : keyColor
        b.pressedColor = isFunction ? funcPressed : keyPressed
        b.backgroundColor = b.normalColor
        b.layer.cornerRadius = 6
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOpacity = 0.25
        b.layer.shadowRadius = 0
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        return b
    }

    private func hRow(_ views: [UIView], equal: Bool = false) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.axis = .horizontal
        s.spacing = Self.colGap
        s.distribution = equal ? .fillEqually : .fill
        return s
    }

    /// 比字母键窄 / 宽一点的功能键：宽度按第一排字母键的宽度乘个倍数
    private func width(_ v: UIView, _ unit: UIView, _ m: CGFloat) {
        guard v.superview != nil, unit.superview != nil else { return }   // 没放进界面就激活约束，UIKit 会抛异常、键盘直接崩
        let c = v.widthAnchor.constraint(equalTo: unit.widthAnchor, multiplier: m)
        c.priority = .required - 1
        c.isActive = true
    }

    private func rebuildKeys() {
        keyArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterKeys = []
        shiftKey = nil
        modeKey = nil
        nineSyll = nil
        ninePunct = nil
        nineClear = nil
        switch layer {
        case .letters: buildLetters()
        case .numbers: buildNumbers()
        }
        rootView?.invalidateKeys()
        sizeRows()
        refreshReturn(force: true)
        refreshLetterTitles()
        applyMic()
        applySpaceWave()
        refreshBar()
    }

    /// 前三排（字母 / 数字符号）一样高、尽量大；最下面一排矮一点。底排的高度优先，空间不够时三排字母一起让
    private func sizeRows() {
        let rows = keyArea.arrangedSubviews
        guard rows.count == 4 else { return }
        let first = rows[0].heightAnchor.constraint(equalToConstant: Self.letterRowH)
        first.priority = UILayoutPriority(700)
        first.isActive = true
        for r in rows[1...2] { r.heightAnchor.constraint(equalTo: rows[0].heightAnchor).isActive = true }
        let bottom = rows[3].heightAnchor.constraint(equalToConstant: Self.bottomRowH)
        bottom.priority = UILayoutPriority(999)
        bottom.isActive = true
    }

    private func buildLetters() {
        if chinese && nine { buildNine(); return }
        func letter(_ c: String) -> KeyButton {
            let k = key(c.uppercased(), font: 24, preview: true) { [weak self] in self?.typeLetter(c) }
            letterKeys.append((k, c))
            if let alt = swipeAlt(c) { addSwipeUp(k, alt) }
            return k
        }
        let r1 = "qwertyuiop".map { letter(String($0)) }
        let r2 = "asdfghjkl".map { letter(String($0)) }
        let r3 = "zxcvbnm".map { letter(String($0)) }
        keyArea.addArrangedSubview(hRow(r1, equal: true))

        let box2 = UIView()
        let s2 = hRow(r2, equal: true)
        s2.translatesAutoresizingMaskIntoConstraints = false
        box2.addSubview(s2)
        NSLayoutConstraint.activate([
            s2.widthAnchor.constraint(equalTo: box2.widthAnchor, multiplier: 0.9),
            s2.centerXAnchor.constraint(equalTo: box2.centerXAnchor),
            s2.topAnchor.constraint(equalTo: box2.topAnchor),
            s2.bottomAnchor.constraint(equalTo: box2.bottomAnchor),
        ])
        keyArea.addArrangedSubview(box2)

        // 第三排：左边 shift（中文下按了 shift 再打字母 = 直接打大写字母，不进拼音）；右边删除
        let left = key(symbol: "shift", isFunction: true) { [weak self] in self?.tapShift() }
        left.accessibilityIdentifier = "shift"
        shiftKey = left
        let del = deleteKey()
        keyArea.addArrangedSubview(hRow([left] + r3 + [del]))
        for k in r3.dropFirst() { k.widthAnchor.constraint(equalTo: r3[0].widthAnchor).isActive = true }
        width(left, r3[0], 1.4)
        width(del, r3[0], 1.4)

        addBottomRow(first: "123", unit: r1[0]) { [weak self] in self?.switchLayer(.numbers) }
    }

    /// 动态热区（三期）：拼音输入时，两个字母键交界处让「更可能是下一个字母」的那个多占几点（最多 ±3pt，键中间不受影响）
    private lazy var letterPrior: LetterPrior? = engine.map { e in LetterPrior(weight: { e.syllableWeight($0) }) }

    private func hotBias(_ k: KeyButton) -> CGFloat {
        guard chinese, layer == .letters, nineSyll == nil, shift == .off,
              let c = letterKeys.first(where: { $0.0 === k })?.1.utf8.first, let lp = letterPrior else { return 0 }
        return LetterPrior.bias(lp.prior(buffer: buffer)[c])
    }

    /// 字母键上滑能打的数字 / 符号（二期；手指要还在原来的键上、往上滑 16pt 以上，松手打出来，气泡里先显示）
    private func swipeAlt(_ c: String) -> String? {
        let digits: [String: String] = ["q": "1", "w": "2", "e": "3", "r": "4", "t": "5", "y": "6", "u": "7", "i": "8", "o": "9", "p": "0"]
        if let d = digits[c] { return d }
        let zh: [String: String] = ["a": "～", "s": "！", "d": "@", "f": "#", "g": "%", "h": "……", "j": "&", "k": "*", "l": "（",
                                    "z": "）", "x": "-", "c": "/", "v": "：", "b": "；", "n": "？", "m": "、"]
        let en: [String: String] = ["a": "~", "s": "!", "d": "@", "f": "#", "g": "$", "h": "%", "j": "&", "k": "*", "l": "(",
                                    "z": ")", "x": "-", "c": "/", "v": ":", "b": ";", "n": "?", "m": "'"]
        return (chinese ? zh : en)[c]
    }

    private func addSwipeUp(_ k: KeyButton, _ alt: String) {
        k.swipeUp = (alt, { [weak self] in self?.typeAlt(alt) })
        let hint = UILabel()
        hint.text = alt
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .secondaryLabel
        hint.alpha = 0.75
        hint.isUserInteractionEnabled = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        k.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: k.topAnchor, constant: 2),
            hint.trailingAnchor.constraint(equalTo: k.trailingAnchor, constant: -3),
        ])
    }

    /// 上滑打出来的数字 / 符号：正在拼的字母先原样落下，再打它
    private func typeAlt(_ s: String) {
        commitRaw()
        typeSymbol(s)
    }

    private func buildNumbers() {
        func sym(_ t: String, _ out: String? = nil) -> KeyButton {
            key(t, font: 20, preview: true) { [weak self] in self?.typeSymbol(out ?? t) }
        }
        let digits = "1234567890".map { sym(String($0)) }
        let r2 = chinese
            ? [sym("，"), sym("。"), sym("？"), sym("！"), sym("、"), sym("："), sym("；"), sym("“"), sym("”"), sym("……")]
            : "-/:;()$&@\"".map { sym(String($0)) }
        let r3 = chinese
            ? [sym("（"), sym("）"), sym("《"), sym("》"), sym("【"), sym("】"), sym("—"), sym("～")]
            : [".", ",", "?", "!", "'", "%", "_", "="].map { sym($0) }
        keyArea.addArrangedSubview(hRow(digits, equal: true))
        keyArea.addArrangedSubview(hRow(r2, equal: true))
        let del = deleteKey()
        keyArea.addArrangedSubview(hRow(r3 + [del]))
        for k in r3.dropFirst() { k.widthAnchor.constraint(equalTo: r3[0].widthAnchor).isActive = true }
        width(del, r3[0], 1.4)
        addBottomRow(first: "ABC", unit: digits[0]) { [weak self] in self?.switchLayer(.letters) }
    }

    /// 最下面一排：[123/ABC] [🌐] [中/英] [空格（按住说话）] [换行]，直接加进 keyArea
    private func addBottomRow(first: String, unit: UIView, _ firstAction: @escaping () -> Void) {
        var fixed: [(UIView, CGFloat)] = []       // （按键，宽度是字母键的几倍）
        var views: [UIView] = []
        let k1 = key(first, isFunction: true, font: 16, firstAction)
        views.append(k1)
        fixed.append((k1, 1.3))
        let pk = makePunctKey()      // 123 旁边的「，。」合并键（仿豆包）
        views.append(pk)
        fixed.append((pk, 1.0))
        if needsInputModeSwitchKey {
            let g = makeGlobeKey()
            views.append(g)
            fixed.append((g, 1.1))
        }
        let mode = makeModeKey()
        views.append(mode)
        fixed.append((mode, 1.2))
        let space = makeSpaceKey()
        views.append(space)
        let ret = key(symbol: "return", isFunction: true) { [weak self] in self?.typeReturn() }
        ret.accessibilityIdentifier = "return"
        returnKey = ret
        views.append(ret)
        fixed.append((ret, 1.8))
        for v in views where v !== space { v.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        keyArea.addArrangedSubview(hRow(views))      // 先放进界面，再接宽度约束
        for (v, m) in fixed { width(v, unit, m) }
    }

    // MARK: 「，。」合并键

    private var punctTimer: Timer?
    private var punctLong = false      // 已经按够久、句号打出去了，松手不再打逗号

    /// 上滑超过这么多就算要句号
    static let punctSwipe: CGFloat = 12

    /// 松手时手指比按下时往上挪了多少（dy < 0 = 往上）：够了就是句号，否则逗号
    static func punctPicksPeriod(dy: CGFloat) -> Bool { dy <= -punctSwipe }

    /// 「，。」合并键：点一下是逗号，上滑（或按住不放）是句号；大字是逗号、右上角的小字是句号。英文下是 , 和 .
    private func makePunctKey() -> KeyButton {
        let k = styled(chinese ? "，" : ",", font: 22)
        k.accessibilityIdentifier = "punct"
        let hint = UILabel()
        hint.text = chinese ? "。" : "."
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabel
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.isUserInteractionEnabled = false
        k.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: k.topAnchor, constant: 3),
            hint.trailingAnchor.constraint(equalTo: k.trailingAnchor, constant: -5),
        ])
        k.addTarget(self, action: #selector(punctDown(_:)), for: .touchDown)
        k.addTarget(self, action: #selector(punctUp(_:)), for: [.touchUpInside, .touchUpOutside])
        k.addTarget(self, action: #selector(punctCancel), for: .touchCancel)
        return k
    }

    @objc private func punctDown(_ b: UIControl) {
        keyFeedback()
        punctLong = false
        punctTimer?.invalidate()
        punctTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.punctLong = true
            self.typePunct(self.chinese ? "。" : ".")
        }
    }

    @objc private func punctUp(_ b: UIControl) {
        punctTimer?.invalidate()
        punctTimer = nil
        if punctLong { punctLong = false; return }
        let period = Self.punctPicksPeriod(dy: (b as? KeyButton)?.dragDelta.y ?? 0)
        typePunct(chinese ? (period ? "。" : "，") : (period ? "." : ","))
    }

    @objc private func punctCancel() {
        punctTimer?.invalidate()
        punctTimer = nil
        punctLong = false
    }

    /// 打标点：正在拼的先落下（中文：第一个候选刚好吃完整串就打候选，否则把字母原样打出去）
    private func typePunct(_ p: String) {
        typed()
        if composing {
            freshCands()
            if chinese, let c = cands.first, c.consume >= buffer.count { commit(c) } else { commitRaw() }
        }
        textDocumentProxy.insertText(p)
        addCtx(p)
        updatePredictions()
        refreshBar()
    }

    /// 🌐 切换输入法的键（系统要求：需要时必须有）
    private func makeGlobeKey() -> KeyButton {
        let g = styled(symbol: "globe", isFunction: true)
        g.routed = false      // 要系统给的真实触摸事件才能弹输入法列表
        g.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        return g
    }

    /// 中 / 英 切换键：「中」「英」两个字斜着摆、带弯箭头，当前的那个标亮（仿豆包输入法）
    private func makeModeKey() -> KeyButton {
        let mode = key(isFunction: true) { [weak self] in self?.toggleMode() }
        let glyph = ModeGlyph()
        glyph.chinese = chinese
        glyph.translatesAutoresizingMaskIntoConstraints = false
        mode.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: mode.leadingAnchor),
            glyph.trailingAnchor.constraint(equalTo: mode.trailingAnchor),
            glyph.topAnchor.constraint(equalTo: mode.topAnchor),
            glyph.bottomAnchor.constraint(equalTo: mode.bottomAnchor),
        ])
        mode.accessibilityIdentifier = "mode"
        mode.accessibilityValue = chinese ? "中" : "英"
        modeKey = mode
        return mode
    }

    /// 空格键：轻点打空格，按住 0.3 秒说话；按住说话时声波画在键上（点顶栏麦克风说话的声波在顶栏，两种方式分开）
    private func makeSpaceKey() -> KeyButton {
        let space = styled(chinese ? "空格" : "space", font: 15)
        space.accessibilityIdentifier = "space"
        spaceKey = space
        let sw = WaveView()
        sw.isHidden = true
        sw.translatesAutoresizingMaskIntoConstraints = false
        space.addSubview(sw)
        NSLayoutConstraint.activate([
            sw.leadingAnchor.constraint(equalTo: space.leadingAnchor, constant: 12),
            sw.trailingAnchor.constraint(equalTo: space.trailingAnchor, constant: -12),
            sw.topAnchor.constraint(equalTo: space.topAnchor, constant: 5),
            sw.bottomAnchor.constraint(equalTo: space.bottomAnchor, constant: -5),
        ])
        spaceWave = sw
        // 「空格」两个字上移一点，下面一行小字提示（仿豆包）；按住说话时声波盖住它们
        space.titleEdgeInsets = UIEdgeInsets(top: -7, left: 0, bottom: 7, right: 0)
        let hint = UILabel()
        hint.text = chinese ? "长按可以直接语音输入" : "Hold to dictate"
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .secondaryLabel
        hint.accessibilityIdentifier = "spaceHint"
        hint.isUserInteractionEnabled = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        space.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: space.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: space.bottomAnchor, constant: -3),
        ])
        spaceHint = hint
        space.onDrag = { [weak self] dx, dy in self?.spaceDrag(dx, dy) ?? false }
        space.addTarget(self, action: #selector(spaceDown), for: .touchDown)
        space.addTarget(self, action: #selector(spaceUp), for: .touchUpInside)
        space.addTarget(self, action: #selector(spaceAway), for: [.touchUpOutside, .touchCancel])
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    private func fixH(_ v: UIView, _ h: CGFloat, _ priority: Float) {
        let c = v.heightAnchor.constraint(equalToConstant: h)
        c.priority = UILayoutPriority(priority)
        c.isActive = true
    }

    /// 拼音九键（仿搜狗 / 豆包）：中间 3×3（分词 ABC DEF / GHI JKL MNO / PQRS TUV WXYZ）+ 底排（中英、空格）；
    /// 左边平时是 ，。？ 三个标点，打字时换成「下一个音节」的列表（点一个就选定它）；右边 删除 / 重输（没在拼时是 ！）/ 回车（两排高）
    private func buildNine() {
        let R = Self.letterRowH, B = Self.bottomRowH, g = Self.rowGap
        func t9(_ d: String, _ title: String) -> KeyButton {
            let k = key(title, font: 19) { [weak self] in self?.typeDigit(d) }
            k.accessibilityIdentifier = "t9-" + d
            return k
        }
        let apos = key("分词", isFunction: true, font: 16) { [weak self] in self?.typeApostrophe() }
        apos.accessibilityIdentifier = "t9-1"
        let grid = [apos, t9("2", "ABC"), t9("3", "DEF"), t9("4", "GHI"), t9("5", "JKL"), t9("6", "MNO"), t9("7", "PQRS"), t9("8", "TUV"), t9("9", "WXYZ")]
        let gridRows = (0..<3).map { hRow(Array(grid[($0 * 3)..<($0 * 3 + 3)]), equal: true) }
        let mode = makeModeKey()
        var bottom: [UIView] = [mode]
        var globe: KeyButton?
        if needsInputModeSwitchKey {
            let gk = makeGlobeKey()
            globe = gk
            bottom.append(gk)
        }
        let space = makeSpaceKey()
        bottom.append(space)
        for v in bottom where v !== space { v.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        let bottomRow = hRow(bottom)
        let centerCol = UIStackView(arrangedSubviews: gridRows + [bottomRow])
        centerCol.axis = .vertical
        centerCol.spacing = g

        // 左边：标点 / 音节列表（叠在一起，轮流显示）+ 123
        let punct = UIStackView(arrangedSubviews: ["，", "。", "？"].map { p in key(p, font: 22) { [weak self] in self?.typeSymbol(p) } })
        punct.axis = .vertical
        punct.spacing = g
        punct.distribution = .fillEqually
        let syll = SyllableColumn(rowH: R, gap: g) { [unowned self] in self.styled(font: 20) }
        syll.onPick = { [weak self] i in self?.pickSyllable(i) }
        let leftTop = UIView()
        for v in [punct, syll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            leftTop.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: leftTop.leadingAnchor), v.trailingAnchor.constraint(equalTo: leftTop.trailingAnchor),
                v.topAnchor.constraint(equalTo: leftTop.topAnchor), v.bottomAnchor.constraint(equalTo: leftTop.bottomAnchor),
            ])
        }
        let k123 = key("123", isFunction: true, font: 16) { [weak self] in self?.switchLayer(.numbers) }
        let leftCol = UIStackView(arrangedSubviews: [leftTop, k123])
        leftCol.axis = .vertical
        leftCol.spacing = g

        // 右边：删除 / 重输 / 回车（占两排高）
        let del = deleteKey()
        let clear = key("！", isFunction: true, font: 17) { [weak self] in self?.resetOrBang() }
        clear.accessibilityIdentifier = "t9-clear"
        let ret = key(symbol: "return", isFunction: true) { [weak self] in self?.typeReturn() }
        ret.accessibilityIdentifier = "return"
        returnKey = ret
        let rightCol = UIStackView(arrangedSubviews: [del, clear, ret])
        rightCol.axis = .vertical
        rightCol.spacing = g

        let cols = hRow([leftCol, centerCol, rightCol])
        keyArea.addArrangedSubview(cols)      // 先放进界面，再接宽度约束
        for c in [leftCol, rightCol] {
            let w = c.widthAnchor.constraint(equalTo: centerCol.widthAnchor, multiplier: 0.27)
            w.priority = .required - 1
            w.isActive = true
        }
        width(mode, grid[0], 0.6)
        if let globe { width(globe, grid[0], 0.6) }
        for r in gridRows { fixH(r, R, 700) }
        fixH(bottomRow, B, 999)
        fixH(leftTop, 3 * R + 2 * g, 700)
        fixH(k123, B, 999)
        fixH(del, R, 700)
        fixH(clear, R, 700)
        fixH(ret, R + g + B, 700)
        nineSyll = syll
        ninePunct = punct
        nineClear = clear
    }

    private func typeDigit(_ d: String) {
        typed()
        guard buffer.count < 48 else { return }
        if buffer.isEmpty { refreshCtx(); startSession() }
        buffer += d
        updateCandidates()
    }

    /// 左边点了一个音节：把输入串里那几个数字换成这个音节的字母，候选只留这个拼法的
    private func pickSyllable(_ i: Int) {
        guard i < nineOpts.count else { return }
        keyFeedback()
        typed()
        let syl = Array(nineOpts[i])
        var chars = Array(buffer)
        guard nineStart + syl.count <= chars.count else { return }
        chars.replaceSubrange(nineStart..<(nineStart + syl.count), with: syl)
        buffer = String(chars)
        updateCandidates()
    }

    /// 九键右边第二个键：拼字时清掉重来，平时就是「！」
    private func resetOrBang() {
        if composing {
            typed()
            buffer = ""
            cands = []
            updatePredictions()
            refreshBar()
        } else {
            typeSymbol("！")
        }
    }

    /// 九键左边：拼字时换成音节列表，平时是标点；右边第二个键的字跟着变
    private func refreshNine() {
        guard let syll = nineSyll, let punct = ninePunct else { return }
        if composing {
            let r = engine?.t9Syllables(buffer, limit: 12) ?? (opts: [], start: 0)
            nineOpts = r.opts
            nineStart = r.start
            syll.setItems(r.opts)
            syll.isHidden = r.opts.isEmpty
            punct.isHidden = true
        } else {
            nineOpts = []
            syll.isHidden = true
            punct.isHidden = false
        }
        nineClear?.setTitle(composing ? "重输" : "！", for: .normal)
    }

    /// 九键顶栏上显示的拼音：第一个候选的拼音（整句就是整句的拼音）；它没盖住整串时，后面接着还没对上的数字；一个候选都没有就显示数字
    private func nineComp() -> String {
        let rest = buffer.filter { $0 != "'" }
        guard let k = cands.first?.key, !k.isEmpty else { return buffer }
        if k.count >= rest.count { return engine?.display(String(k.prefix(rest.count))) ?? buffer }
        return engine?.display(k + String(rest.dropFirst(k.count))) ?? buffer
    }

    private func deleteKey() -> KeyButton {
        let del = styled(symbol: "delete.left", isFunction: true)
        del.accessibilityIdentifier = "delete"
        del.onDrag = { [weak self] dx, dy in self?.deleteDrag(dx, dy) ?? false }
        del.addTarget(self, action: #selector(delDown), for: .touchDown)
        del.addTarget(self, action: #selector(delUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return del
    }

    private func refreshLetterTitles() {
        let up = shift != .off
        for (k, c) in letterKeys { k.setTitle(up ? c.uppercased() : c, for: .normal) }
        shiftKey?.setImage(UIImage(systemName: shift == .caps ? "capslock.fill" : (shift == .once ? "shift.fill" : "shift"),
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
    }

    // MARK: 状态栏（语音状态 / 拼音候选）

    private func setStatus(_ s: String, _ color: UIColor = .label, hint: Bool = false) {
        statusHint = hint
        statusText = s
        statusColor = color
        if !composing { refreshBar() }
    }

    private func setMic(_ style: MicStyle) {
        if micStyle == style { return }
        micStyle = style
        applyMic()
    }

    private func applyMic() {
        switch micStyle {
        case .idle: candBar.setMic(symbol: "mic.fill", fill: Brand.lightGreen, tint: Brand.green)
        case .recording: candBar.setMic(symbol: "stop.fill", fill: Brand.green, tint: .white)
        case .busy: candBar.setMic(symbol: "ellipsis", fill: Brand.lightGreen, tint: Brand.green)
        case .off: candBar.setMic(symbol: "mic.slash.fill", fill: UIColor.systemGray4, tint: .systemGray)
        }
    }

    /// 正在拼的词（中文拼音、英文单词都先显示在上面的框里，选定 / 按空格才打进输入框）
    private var composing: Bool { layer == .letters && !buffer.isEmpty }

    func refreshBar() {
        if composing {
            // 拼音行只显示用户打的字母（纠错只在后台改候选，不改、不标记用户打的字）
            let comp = chinese ? (nineSyll != nil ? nineComp() : (engine?.display(buffer) ?? buffer)) : buffer
            candBar.showCandidates(comp: comp, items: cands.map { $0.text })
        } else if recordingNow {
            candBar.showWave()
        } else if statusText.isEmpty || statusHint, !predictions.isEmpty {
            candBar.showPredictions(ctx: contextWord() ?? "", items: predictions)
        } else {
            candBar.showStatus(statusText, statusColor)
        }
        if !composing, panelOpen { closePanel() }
        candBar.showUndo(!composing && (!clearedText.isEmpty || (!live.isEmpty && liveFinal && liveSID != dead)))
        refreshNine()
    }

    // MARK: 展开全部候选

    private func togglePanel() {
        if panelOpen { closePanel(); return }
        guard composing else { return }
        panelList = candidateList(limit: chinese ? 200 : 100, expanded: true)
        panel.setItems(panelList.map { $0.text })
        panel.isHidden = false
        panelOpen = true
        candBar.setExpanded(true)
    }

    private func closePanel() {
        panel.isHidden = true
        panelOpen = false
        candBar.setExpanded(false)
    }

    private func pickFromPanel(_ i: Int) {
        guard i < panelList.count else { return }
        keyFeedback()
        let c = panelList[i]
        closePanel()
        typed()
        commitCandidate(c)
    }

    // MARK: 打字动作

    private func typed() {
        lastAction = Date()
        clearedText = ""        // 接着打字了，左滑清空的「撤销」不再给
        userTyped()
    }

    private func typeLetter(_ c: String) {
        typed()
        if chinese && shift == .off {
            guard buffer.count < 48 else { return }
            if buffer.isEmpty { refreshCtx(); startSession() }      // 开始拼一个新词：从输入框取一次最新的上文
            buffer += c
            updateCandidates()
        } else if !chinese {
            guard buffer.count < 32 else { return }
            predictions = []
            buffer += shift == .off ? c : c.uppercased()      // 英文也先放进上面的框里，带联想
            if shift == .once { shift = .off; refreshLetterTitles() }
            updateCandidates()
        } else {
            commitRaw()    // 没选完的拼音先原样落下
            textDocumentProxy.insertText(c.uppercased())
            if shift == .once { shift = .off; refreshLetterTitles() }
        }
    }

    private func typeApostrophe() {
        guard chinese, !buffer.isEmpty, !buffer.hasSuffix("'") else { return }
        buffer += "'"
        updateCandidates()
    }

    /// 3。5 → 3.5（二期智能标点）：数字后面打了中文句号、紧接着又打数字，句号要改成小数点
    static func shouldFixDecimal(before ctx: String?, typing s: String) -> Bool {
        guard s.count == 1, let c = s.first, c.isASCII, c.isNumber, let ctx, ctx.hasSuffix("。"), let b = ctx.dropLast().last else { return false }
        return b.isASCII && b.isNumber
    }

    private func typeSymbol(_ s: String) {
        typed()
        if Self.shouldFixDecimal(before: textDocumentProxy.documentContextBeforeInput, typing: s) {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(".")
        }
        symbolSink?(s)
        textDocumentProxy.insertText(s)
        addCtx(s)
        updatePredictions()
        refreshBar()
    }

    private func typeSpace() {
        typed()
        if composing { freshCands() }        // 打得快时后台的候选可能还没跟上：按空格落的一定是现在这串拼音的第一个
        if composing, !chinese {
            textDocumentProxy.insertText(buffer + " ")      // 英文：按空格 = 照打的原样落下
            buffer = ""
            cands = []
            refreshBar()
        } else if composing, let first = cands.first {
            commit(first)
        } else {
            textDocumentProxy.insertText(" ")
            addCtx(" ")
            predictions = []
            refreshBar()
        }
    }

    /// 回车键按输入框的要求换字：发送 / 搜索 / 前往 / 完成 / 下一项…（二期；绿底白字，跟豆包的「确定」一样醒目）；平常的换行还是那个图标
    func refreshReturn(force: Bool = false) {
        guard let k = returnKey else { return }
        let title: String?
        switch returnTypeProbe?() ?? textDocumentProxy.returnKeyType ?? .default {
        case .send: title = "发送"
        case .search, .google, .yahoo: title = "搜索"
        case .go: title = "前往"
        case .done: title = "完成"
        case .next: title = "下一项"
        case .join: title = "加入"
        default: title = nil
        }
        if !force, let shown = shownReturn, shown == title { return }
        shownReturn = .some(title)
        if let t = title {
            k.setImage(nil, for: .normal)
            k.setTitle(t, for: .normal)
            k.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            k.setTitleColor(.white, for: .normal)
            k.normalColor = Brand.green
            k.pressedColor = Brand.deep
        } else {
            k.setTitle(nil, for: .normal)
            k.setImage(UIImage(systemName: "return", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            k.normalColor = funcColor
            k.pressedColor = funcPressed
        }
    }

    private func typeReturn() {
        typed()
        if composing {
            commitRaw()
            ctxTail = ""
            predictions = []
            refreshBar()
        } else {
            textDocumentProxy.insertText("\n")
            resetAfterSend()
        }
    }

    /// 发出去了 / 输入框被清空了：顶栏回到最开始的样子（麦克风 + 齿轮 + 收起），上一句的联想、撤销都不留（用户 10-24：
    /// 「点了发送以后输入法上面不要再显示任何词，直接显示最开始的按钮和收起箭头」）
    private func resetAfterSend() {
        ctxTail = ""
        predictions = []
        if !recordingNow, !live.isEmpty { dead = liveSID; live = "" }
        if panelOpen { closePanel() }
        refreshBar()
    }

    private func deleteOnce() {
        typed()
        if composing {
            buffer.removeLast()
            if buffer.hasSuffix("'") { buffer.removeLast() }
            updateCandidates()
        } else {
            textDocumentProxy.deleteBackward()
            ctxTail = String(ctxTail.dropLast())
            predictions = []
            refreshBar()
        }
    }

    private func tapShift() {
        let now = Date()
        switch shift {
        case .off: shift = .once
        case .once: shift = now.timeIntervalSince(lastShiftTap) < 0.4 ? .caps : .off
        case .caps: shift = .off
        }
        lastShiftTap = now
        refreshLetterTitles()
    }

    private func toggleMode() {
        commitRaw()
        chinese.toggle()
        UserDefaults.standard.set(chinese, forKey: "zh")
        shift = .off
        closePanel()
        rebuildKeys()
    }

    private func switchLayer(_ l: Layer) {
        commitRaw()
        closePanel()
        layer = l
        rebuildKeys()
    }

    /// ctxTail 末尾最长的、语言模型认识的词（待会、我们、，…）；认不出就是 nil
    private func contextWord() -> String? {
        guard let e = engine else { return nil }
        for n in stride(from: min(4, ctxTail.count), through: 1, by: -1) {
            let w = String(ctxTail.suffix(n))
            if e.knows(w) { return w }
        }
        return nil
    }

    private func refreshCtx() {
        ctxTail = String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(12))
    }

    private func addCtx(_ t: String) {
        ctxTail = String((ctxTail + t).suffix(12))
    }

    private func updatePredictions() {
        if chinese, let w = contextWord() {
            predictions = Array((emoji?.forWord(w) ?? []).prefix(3)) + (engine?.predict(after: w, limit: 12) ?? [])      // 这个词有对应的表情就排最前
        } else {
            predictions = []
        }
    }

    private func pickPrediction(_ i: Int) {
        guard i < predictions.count else { return }
        keyFeedback()
        typed()
        let t = predictions[i]
        if let u = engine?.user, let prev = contextWord(), t.unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) {
            onEngine { u.learn([t], prev: prev) }       // 点了联想：记一对（上文, 这个词）
            scheduleUserSave()
        }
        textDocumentProxy.insertText(t)
        addCtx(t)
        updatePredictions()
        refreshBar()
    }

    /// 出候选（只读引擎和词表，后台线程上跑也行）
    private static func makeList(_ e: PinyinEngine?, _ words: EnglishWords?, _ emoji: EmojiIndex?, _ buf: String, chinese: Bool, nine: Bool, ctx: String?,
                                 limit: Int, expanded: Bool) -> [PinyinCandidate] {
        if chinese {
            let r = nine
                ? (e?.t9Candidates(buf, limit: limit, expanded: expanded, ctx: ctx) ?? [])
                : (e?.candidates(buf, limit: limit, expanded: expanded, ctx: ctx) ?? [])
            var out = r.isEmpty ? [PinyinCandidate(text: buf.replacingOccurrences(of: "'", with: ""), consume: buf.count, kind: .raw)] : r
            // 中英混输（二期）：打的字母本身是个常见英文词 / 缩写（wifi、ok、ppt…）就加一条英文候选：拼音盖不住整串时排第一，盖得住就排第三
            if !nine, let en = words?.mixedWord(buf) {
                let cand = PinyinCandidate(text: en, consume: buf.count, kind: .raw)
                let covered = out.first.map { $0.consume >= buf.count } ?? false
                out.insert(cand, at: covered ? min(2, out.count) : 0)
            }
            // 表情联想（三期）：拼音正好是某个关键词（haha、aixin、zuqiu…）就在前三个候选后面补最多三个表情
            if !nine, let em = emoji {
                let es = em.forKey(buf.replacingOccurrences(of: "'", with: ""))
                if !es.isEmpty { out.insert(contentsOf: es.prefix(3).map { PinyinCandidate(text: $0, consume: buf.count, kind: .raw) }, at: min(3, out.count)) }
            }
            return out
        }
        // 英文：第一个是照打的原样（按空格落下的就是它），后面是按词频排的联想
        var out = [PinyinCandidate(text: buf, consume: buf.count, kind: .raw)]
        for w in words?.complete(buf, limit: limit) ?? [] {
            out.append(PinyinCandidate(text: w, consume: buf.count, kind: .raw))
        }
        return out
    }

    /// 当场算（排在后台正在算的后面），展开面板、按空格前候选还没跟上时用
    private func candidateList(limit: Int, expanded: Bool = false) -> [PinyinCandidate] {
        let e = engine, w = words, em = emoji, buf = buffer, zh = chinese, nine = nineSyll != nil, ctx = contextWord()
        return engineQueue.sync { Self.makeList(e, w, em, buf, chinese: zh, nine: nine, ctx: ctx, limit: limit, expanded: expanded) }
    }

    // MARK: 引擎在后台算（一期④）：按键时气泡和拼音行先出来，候选几毫秒后到；连着快打只算最新的输入串
    private let engineQueue = DispatchQueue(label: "voicekb.engine", qos: .userInteractive)
    private let genLock = NSLock()
    private var latestGen = 0                // 最新一次要算的编号（后台线程也读，加锁）
    private var candsFor = ""                // cands 是按哪个输入串算的（见 candKey）
    /// 测试用：同步算（测试按完键马上看候选）
    var syncEngine = false
    private var candKey: String { (chinese ? (nineSyll != nil ? "9" : "z") : "e") + buffer }

    /// 动个人学习的数据：和出候选排在同一个队列里，不会一边算一边改
    private func onEngine(_ block: @escaping () -> Void) {
        if syncEngine { engineQueue.sync(execute: block) } else { engineQueue.async(execute: block) }
    }

    private func updateCandidates() {
        if buffer.isEmpty {
            cands = []
            candsFor = ""
            updatePredictions()
            refreshBar()
            return
        }
        let key = candKey
        // 英文、九键算得快（查表 / 按前缀走），同步；26 键拼音的整句选词 + 纠错放后台
        if syncEngine || !chinese || nineSyll != nil {
            cands = candidateList(limit: chinese ? 40 : 14)
            candsFor = key
            refreshBar()
            return
        }
        genLock.lock()
        latestGen &+= 1
        let gen = latestGen
        genLock.unlock()
        let e = engine, w = words, em = emoji, buf = buffer, ctx = contextWord()
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.genLock.lock()
            let stale = gen != self.latestGen
            self.genLock.unlock()
            if stale { return }                  // 后面又按了键，这个不用算了
            let r = Self.makeList(e, w, em, buf, chinese: true, nine: false, ctx: ctx, limit: 40, expanded: false)
            DispatchQueue.main.async {
                guard self.candKey == key else { return }
                self.cands = r
                self.candsFor = key
                self.refreshBar()
            }
        }
        refreshBar()          // 拼音行先跟上，候选等后台算好再换
    }

    /// 要用第一个候选（按空格、打标点、换行落字母）之前：还没按现在的输入串算好就当场算
    private func freshCands() {
        if buffer.isEmpty || candsFor == candKey { return }
        cands = candidateList(limit: chinese ? 40 : 14)
        candsFor = candKey
    }

    private func pick(_ i: Int) {
        if !composing, !predictions.isEmpty { pickPrediction(i); return }
        guard i < cands.count else { return }
        keyFeedback()
        typed()
        commitCandidate(cands[i])
    }

    /// 中文：把候选打进去、剩下的拼音接着出候选；英文：把词连同一个空格打进去
    private func commitCandidate(_ c: PinyinCandidate) {
        if chinese {
            commit(c)
        } else {
            textDocumentProxy.insertText(c.text + " ")
            buffer = ""
            cands = []
            refreshBar()
        }
    }

    /// 把候选打进输入框，吃掉对应的拼音，剩下的接着出候选
    private func commit(_ c: PinyinCandidate) {
        let letters = String(buffer.prefix(c.consume)).replacingOccurrences(of: "'", with: "")
        textDocumentProxy.insertText(c.text)
        addCtx(c.text)
        buffer = c.consume >= buffer.count ? "" : String(buffer.dropFirst(c.consume))
        if c.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { noteCommit(c, letters: letters) }      // 混输的英文词、表情不进中文个人学习
        updateCandidates()
    }

    /// 拼音串还没选字就要走（换行、切语言、切层、点麦克风）：把字母原样打出去
    private func commitRaw() {
        guard !buffer.isEmpty else { return }
        var t = buffer.replacingOccurrences(of: "'", with: "")
        if t.contains(where: { $0.isNumber }) { freshCands() }
        if t.contains(where: { $0.isNumber }), let k = cands.first?.key, k.count >= t.count { t = String(k.prefix(t.count)) }     // 九键：数字串落成第一个候选的拼音
        textDocumentProxy.insertText(t)
        buffer = ""
        cands = []
        refreshBar()
    }

    // MARK: 语音状态

    /// 记下最新快照；cseq / dseq 只往大里取（键盘进程可能是新起的，App 那边记着上次的）
    private func apply(_ s: Link.Snap) {
        snap = s
        cseq = max(cseq, s.kbd["cseq"] as? Int ?? 0)
        dseq = max(dseq, s.kbd["dseq"] as? Int ?? 0)
        if s.ok, !synced {
            synced = true
            if saveWanted { saveWanted = false; saveK() }
        }
        flushOutbox()
    }

    /// 读过 App 里记着的我（dseq / cseq / lseq）了吗。新建的键盘实例这几个数都是 0，要是在读到之前就写回去，
    /// 会把 App 里的记录冲成 0——上一段听写的结果又被当成新结果、打进现在的输入框
    private(set) var synced = false
    private var saveWanted = false

    private func refresh() {
        guard fullAccess else {
            setStatus("请开启「允许完全访问」：设置 → 通用 → 键盘 → 键盘 → 芽音", .systemRed)
            setMic(.off)
            return
        }
        Link.fetch { [weak self] s in self?.handle(s) }
    }

    /// 每拿到一份快照：画状态；说话时让输入框跟着识别结果走；有新结果就替换进去
    func handle(_ s: Link.Snap) {
        // 偶尔一次没问到（超时）别当成「App 没了」：连着 4 次没问到才算
        if !s.ok, snap.ok {
            failedPolls += 1
            if failedPolls < 4 { return }
        } else if s.ok {
            failedPolls = 0
        }
        apply(s)
        // 录音归属只由「屏幕上这个键盘」处理：后台还活着的另一个 App 的键盘实例也会被通知叫醒走到这里，
        // 以前它们照样「认领」和「作废」，用户开着两个 App 的输入框时，刚按开始就被对方作废了
        if visible, s.ok {
            claimVoiceIfMine()
            let leftOver = (s.app["state"] as? String ?? "idle") != "idle" && (s.app["sid"] as? Int ?? -1) == leftSID
            if needForeignCheck || leftOver { needForeignCheck = false; dropForeignVoice() }
        }
        // 按住说话时手指已经不在空格上了（松手事件没收到）：结束录音
        if pttActive, !(spaceKey?.touchHeld ?? false) { pttEnd() }
        render()
        applySpaceWave()
        let a = s.app
        let sid = a["sid"] as? Int ?? -1
        if recordingNow {
            candBar.setLevels(s.levels)
            spaceWave?.levels = s.levels
            if ownsVoice(sid) {      // 不是我发起的录音（别的 App 的、没人认领的）不往我的输入框里打字
                liveUpdate(a["partial"] as? String ?? "", sid: sid, cuts: a["cuts"] as? Int ?? 0, base: a["base"] as? Int ?? 0)
            }
        }
        setPoll(recordingNow ? 0.1 : 0.5)
        if recordingNow, sid == liveSID, (a["cuts"] as? Int ?? 0) < myCuts, Date().timeIntervalSince(lastResend) > 0.4 {
            lastResend = Date()
            saveK()      // 冻结的指令没送到（App 那边的次数落后了）：把最后一条指令再发一遍
        }
        let rseq = a["rseq"] as? Int ?? 0
        // 键盘不在屏幕上时（收起了、切走了）不收：结果留着，回来再收；以前后台的键盘实例也照收不误，润色结果就这样打进了别的窗口
        guard visible, rseq > dseq, let t = a["result"] as? String, !t.isEmpty else { return }
        let age = Date().timeIntervalSince1970 - (a["rtime"] as? Double ?? 0)
        dseq = rseq
        saveK()
        guard age < 120 else { return }
        applyResult(t, sid: a["rsid"] as? Int ?? sid, cuts: a["rcuts"] as? Int ?? 0)
    }

    /// 主 App 的状态；别的输入框的录音（已作废、主 App 还没跟上）在这里当没这回事，算待命
    private var appState: String {
        let a = snap.app
        let state = a["state"] as? String ?? "idle"
        return state != "idle" && (a["sid"] as? Int ?? -1) == leftSID ? "idle" : state
    }

    private func render() {
        let a = snap.app
        let state = appState
        recordingNow = state == "recording"
        switch state {
        case "recording":
            flashUntil = .distantPast
            opening = false
            setStatus(pttActive ? "松开空格结束" : "录音中…再点一下麦克风结束", Brand.green)
            setMic(pttActive ? .idle : .recording)
        case "processing":
            setStatus("整理中…（文字稍后自动替换）")
            setMic(.busy)
        default:
            let now = Date().timeIntervalSince1970
            if Date() < flashUntil {
                setStatus(flashText, flashColor)
            } else if let err = a["err"] as? String, !err.isEmpty, now - (a["errtime"] as? Double ?? 0) < 8 {
                setStatus(err, .systemRed)
            } else if snap.beatAge < 3 {
                let left = Int(((a["keepUntil"] as? Double ?? 0) - now) / 60)
                setStatus(left > 600 ? "语音待命中（一直开）" : "语音待命中（约剩 \(max(left, 0)) 分钟）", hint: true)
            } else {
                setStatus("点麦克风，或按住空格说话", hint: true)
            }
            setMic(.idle)
        }
    }

    /// 按住空格说话时，空格键上显示声波（盖住「空格」两个字）；点麦克风说话不在这里显示
    private func applySpaceWave() {
        let on = recordingNow && pttActive
        spaceWave?.isHidden = !on
        spaceHint?.isHidden = on
        spaceKey?.setTitle(on ? nil : (chinese ? "空格" : "space"), for: .normal)
    }

    // MARK: 语音动作

    private func send(_ cmd: String, _ extra: [String: Any] = [:]) {
        cseq += 1
        lastCmd = cmd
        lastExtra = extra
        saveK()
    }

    /// 键盘上发生的事记进主 App 的日志（它会传到服务器）；主 App 没在跑时丢掉
    private func klog(_ s: String) {
        lseq += 1
        lastLog = s
        saveK()
    }

    /// 重要事件（打开主 App 的结果等）：主 App 够不着时 klog 会丢，所以先存在本地，等连上主 App 再一起补报
    private func qlog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let q = (UserDefaults.standard.stringArray(forKey: "outbox") ?? []) + ["\(f.string(from: Date())) \(s)"]
        UserDefaults.standard.set(Array(q.suffix(12)), forKey: "outbox")
        outboxPending = true
        flushOutbox()
    }

    private func flushOutbox() {
        guard outboxPending, synced, snap.ok else { return }
        outboxPending = false
        let q = UserDefaults.standard.stringArray(forKey: "outbox") ?? []
        UserDefaults.standard.removeObject(forKey: "outbox")
        if !q.isEmpty { klog("键盘补报：" + q.joined(separator: " ¦ ")) }
    }

    /// 比平时的状态字多留几秒：点了没反应的时候要让人看得见原因（以前写上去 0.5 秒就被下一次刷新盖掉了）
    private func flash(_ text: String, _ color: UIColor = .label, for secs: TimeInterval) {
        flashText = text
        flashColor = color
        flashUntil = Date().addingTimeInterval(secs)
        setStatus(text, color)
    }

    private func saveK() {
        guard synced else { saveWanted = true; return }
        var d: [String: Any] = ["cmd": lastCmd, "cseq": cseq, "dseq": dseq, "lseq": lseq, "klog": lastLog]
        for (k, v) in lastExtra { d[k] = v }
        Link.putKbd(d)
    }

    private func micTapped() {
        guard fullAccess else { refresh(); return }
        commitRaw()
        switch appState {
        case "recording":
            pttActive = false
            send("stop", ["src": "mic"])
        case "processing":
            break      // 上面已经写着「整理中…」，麦克风也是「…」
        default:
            if snap.beatAge < 3 {
                expectOwnRecording()
                send("start")
                watchStart(src: "mic")
            } else {
                openApp(src: "mic")
            }
        }
    }

    /// 发了开始指令却 1.5 秒都没动静（主 App 没收到 / 引擎不转了）：当成它没待命，走打开主 App 那条路，别让人干等、什么提示也没有
    private func watchStart(src: String) {
        let sid0 = snap.app["sid"] as? Int ?? -1
        let t0 = Date().timeIntervalSince1970
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.visible, src == "mic" || self.pttActive else { return }
            let a = self.snap.app
            let reacted = self.recordingNow || (a["sid"] as? Int ?? -1) != sid0 || (a["errtime"] as? Double ?? 0) > t0
            guard !reacted else { return }
            self.qlog("开始指令 1.5 秒没有回音（\(src)），改走打开主 App")
            self.openApp(src: src)
        }
    }

    // 按住空格说话：按够 0.4 秒开始录，松手结束；轻点还是打空格（原来 0.3 秒，慢一点点的点按会误触发语音、甚至跳去主 App，10-25 改 0.4）；
    // 按住后左右滑动 = 移光标（二期），一滑就不再算「按住说话」
    @objc private func spaceDown() {
        keyFeedback()
        spaceLong = false
        spaceSwiping = false
        spaceTimer?.invalidate()
        spaceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.spaceLong = true
            self?.pttStart()
        }
    }

    /// 在空格上横着滑：每滑 14pt 光标挪一个字。已经在说话（按住够久）就不挪
    private func spaceDrag(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        if spaceLong || pttActive { return false }
        if !spaceSwiping {
            guard abs(dx) >= 12, abs(dx) > abs(dy) else { return false }
            spaceSwiping = true
            spaceTimer?.invalidate()
            spaceTimer = nil
            commitRaw()
            spaceSteps = 0
        }
        let steps = Int((dx / 14).rounded(.towardZero))
        if steps != spaceSteps {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: steps - spaceSteps)
            cursorProbe?(steps - spaceSteps)
            spaceSteps = steps
            ctxTail = ""
            predictions = []
            refreshBar()
            if hapticOn { haptic.impactOccurred(intensity: 0.5) }
        }
        return true
    }

    @objc private func spaceUp() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        if spaceLong {
            spaceLong = false
            pttEnd()
        } else {
            typeSpace()
        }
    }

    @objc private func spaceAway() {
        spaceTimer?.invalidate()
        spaceTimer = nil
        spaceSwiping = false
        if spaceLong {
            spaceLong = false
            pttEnd()
        }
    }

    private func pttStart() {
        guard fullAccess else { refresh(); return }
        commitRaw()
        if snap.beatAge < 3 { pttBegin(); return }
        // 看着像 App 没待命：可能只是键盘刚出来、还没来得及问过它——先当场问一次再决定，免得白白跳出去
        Link.fetch { [weak self] s in
            guard let self else { return }
            self.apply(s)
            self.pttBegin()
        }
    }

    private func pttBegin() {
        switch appState {
        case "idle": break
        case "processing":
            setStatus("上一段还在整理，稍等一下再按住说话", Brand.green)      // 以前这里什么都不说，用户只觉得「按了没反应」
            return
        default: return      // 已经在录了：松手也不管它
        }
        if snap.beatAge < 3 {
            pttActive = true
            expectOwnRecording()
            send("start")
            watchStart(src: "space")
            refresh()
        } else {
            openApp(src: "space")      // 切走以后收不到松手，这次靠点麦克风结束
        }
    }

    private func pttEnd() {
        guard pttActive else { return }
        pttActive = false
        send("stop", ["src": "space"])
        applySpaceWave()
        refresh()
    }

    /// 联想行右边的 ✕：整行联想关掉，顶栏回到最开始的样子（麦克风 + 齿轮 + 收起箭头）；上个词的上下文也清掉，不再马上又冒出新的联想（用户 10-24）
    private func closePredictions() {
        keyFeedback()
        predictions = []
        ctxTail = ""
        render()
    }

    /// 打开主 App 录音；顺带告诉它我在给哪个 App 打字，录上音它好自动跳回来。
    /// 待命过期（或被系统收掉）以后点麦克风 / 按住空格都走这里。以前只试一种办法、失败了状态栏的红字 0.5 秒就被刷新盖掉，用户看到的是「什么反应都没有」；
    /// 现在逐个试三种办法，每一种调用出去 1.6 秒后看主 App 起来没有，没起来就换下一种，全不行就留一行红字说明白（并把过程记下来、之后补报到服务器日志）
    private func openApp(src: String) {
        guard !opening else { return }
        let host = HostApp.resolve(self)
        var c = URLComponents()
        c.scheme = "voicekb"
        c.host = "dictate"
        c.queryItems = [URLQueryItem(name: "how", value: host.how), URLQueryItem(name: "src", value: src)]
        if let id = host.id { c.queryItems?.append(URLQueryItem(name: "host", value: id)) }
        if let pid = HostApp.hostPID(self) { c.queryItems?.append(URLQueryItem(name: "pid", value: String(pid))) }
        guard let url = c.url else { return }
        expectOwnRecording()
        opening = true
        openToken &+= 1
        flash("正在打开「芽音」App…", Brand.green, for: 8)
        tryOpen(url, step: 0, trail: [], token: openToken)
    }

    private func tryOpen(_ url: URL, step: Int, trail: [String], token: Int) {
        guard token == openToken else { return }
        let names = ["扩展接口", "响应链(控制器)", "响应链(视图)"]
        guard step < names.count else { return openFailed(trail) }
        let name = names[step]
        func next(_ why: String) { tryOpen(url, step: step + 1, trail: trail + ["\(name)：\(why)"], token: token) }
        // 这一招调用出去了：1.6 秒后连得上主 App 就算成功（成功的话键盘早被切走，回来时计时才跑到，这时主 App 已经在线）；连不上就换下一招
        func check(_ how: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, token == self.openToken else { return }
                Link.fetch { s in
                    guard token == self.openToken else { return }
                    if s.ok {
                        self.opening = false
                        self.flashUntil = .distantPast
                        self.qlog("打开主 App 成功：" + (trail + ["\(name)：\(how)"]).joined(separator: "；"))
                    } else {
                        next("\(how)，但主 App 没起来")
                    }
                }
            }
        }
        switch step {
        case 0:
            guard let ctx = extensionContext else { return next("没有扩展上下文") }
            var settled = false
            ctx.open(url) { ok in
                DispatchQueue.main.async {
                    guard !settled else { return }
                    settled = true
                    if ok { check("返回成功") } else { next("返回失败") }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard !settled else { return }
                settled = true
                check("没有回音")
            }
        default:
            guard !suppressRealOpen else { return next("测试里不真打开") }
            var start: UIResponder = self
            if step == 2, let v = viewIfLoaded { start = v }
            if Self.openViaResponder(from: start, url) { check("已调用") } else { next("响应链里没有 UIApplication") }
        }
    }

    private func openFailed(_ trail: [String]) {
        opening = false
        qlog("打开主 App 失败：" + trail.joined(separator: "；"))
        flash("没能打开「芽音」，请手动点开它一次再回来", .systemRed, for: 12)
    }

    /// 顺着响应链找到 UIApplication，动态调 open(_:options:completionHandler:)（键盘里不能直接用 UIApplication.shared）
    private static func openViaResponder(from start: UIResponder, _ url: URL) -> Bool {
        typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, UnsafeRawPointer?) -> Void
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = start
        while let x = r {
            if x is UIApplication, x.responds(to: sel), let imp = class_getMethodImplementation(object_getClass(x), sel) {
                unsafeBitCast(imp, to: OpenFn.self)(x, sel, url as NSURL, NSDictionary(), nil)
                return true
            }
            r = x.next
        }
        return false
    }

    /// 收起键盘（顶栏右边的白圆）。第一次没收起来（宿主刚好在忙）0.4 秒后再来一次
    private func collapse() {
        collapseCount += 1
        keyFeedback()
        commitRaw()      // 没选完的拼音先原样落下，免得收起键盘时丢掉
        let dismiss = dismissAction ?? { [weak self] in self?.dismissKeyboard() }
        dismiss()
        let epoch = hideEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.visible, epoch == self.hideEpoch else { return }
            dismiss()
        }
    }

    // MARK: 每个输入框的语音互相隔离（用户 10-24：A 窗口的语音没关、切到 B 窗口，B 一点进去不能是录音状态）

    /// 这次录音是哪个输入框开始的：由发起它的键盘记下自己的输入框编号（见 claimVoiceIfMine）。
    /// 存 UserDefaults，换了键盘实例（换了 App）也认得
    private func voiceOwner(_ sid: Int) -> String? {
        guard let o = UserDefaults.standard.dictionary(forKey: "voiceOwner"), o["sid"] as? Int == sid else { return nil }
        return o["doc"] as? String
    }

    /// 已经作废的那次录音（在别的输入框开始的）：哪个键盘实例看到它都当没这回事
    private var leftSID: Int { UserDefaults.standard.object(forKey: "leftSID") as? Int ?? Int.min }

    private func myPID() -> Int? { pidProbe?() ?? HostApp.hostPID(self) }

    /// 我要发起一次录音了（发 start 指令，或者去拉起主 App）：留一张「认领票」，上面写着我宿主 App 的进程号。
    /// 以前是「第一个看到录音的键盘认领」，结果后台里还活着的另一个 App 的键盘、或者主 App 自己输入框里的键盘抢先认领，
    /// 真正发起的键盘反倒被当成"别的输入框"作废（用户 10-24：开着两个 App 的输入框就用不了；不待命每次冷启动都跳来跳去）
    func expectOwnRecording() {
        var t: [String: Any] = ["t": Date().timeIntervalSince1970]
        if let p = myPID() { t["pid"] = p }
        UserDefaults.standard.set(t, forKey: "claimTicket")
    }

    /// 屏幕上的键盘手里有一张还新的认领票（30 秒内、进程号对得上、没领过别的录音），主 App 又在录：这次录音就是我的。
    /// 冷启动跳回宿主后键盘进程会重建、输入框编号换号，所以按「宿主进程号 + 票」认，不按输入框编号认；换号后的新实例同一张票可以重新认
    private func claimVoiceIfMine() {
        let a = snap.app
        guard a["state"] as? String == "recording", let sid = a["sid"] as? Int, sid != leftSID else { return }
        let doc = currentDoc().uuidString
        if voiceOwner(sid) == doc { return }
        let d = UserDefaults.standard
        guard var t = d.dictionary(forKey: "claimTicket"), let at = t["t"] as? Double, Date().timeIntervalSince1970 - at < 30 else { return }
        if let p = t["pid"] as? Int, let me = myPID(), p != me { return }
        if let s = t["sid"] as? Int, s != sid { return }
        t["sid"] = sid
        d.set(t, forKey: "claimTicket")
        var o: [String: Any] = ["sid": sid, "doc": doc]
        if let me = myPID() { o["pid"] = me }
        d.set(o, forKey: "voiceOwner")
        qlog("认领录音 sid=\(sid)（宿主pid \(myPID().map(String.init) ?? "?")）")
    }

    /// 这次录音是我发起（认领）的、而且我现在就在屏幕上：只有这种才往输入框里打字
    private func ownsVoice(_ sid: Int) -> Bool {
        visible && voiceOwner(sid) == currentDoc().uuidString
    }

    /// 主 App 正在录（或在整理）的这次录音不是这个输入框开始的：作废它（不收尾、不润色），这里显示待命。返回 true = 是别人的。
    /// 只有屏幕上的键盘才有资格作废；没人认领的录音（不是任何键盘发起的）谁也不动
    @discardableResult
    private func dropForeignVoice() -> Bool {
        guard visible else { return false }
        let a = snap.app
        let state = a["state"] as? String ?? "idle"
        let sid = a["sid"] as? Int ?? -1
        guard snap.ok, state != "idle" else { return false }
        if sid == leftSID {
            if Date().timeIntervalSince(lastCancel) > 1 { lastCancel = Date(); send("cancel", ["src": "resend"]) }    // 主 App 还没收到作废：隔一秒再说一遍
            return true
        }
        let doc = currentDoc().uuidString
        guard let owner = voiceOwner(sid), owner != doc else { return false }
        let ownerPID = (UserDefaults.standard.dictionary(forKey: "voiceOwner")?["pid"] as? Int).map(String.init) ?? "?"
        UserDefaults.standard.set(sid, forKey: "leftSID")
        dead = sid
        if liveSID == sid { live = "" }
        pttActive = false
        lastCancel = Date()
        qlog("换了输入框，作废在别的输入框开始的录音（\(state)；录音属 pid \(ownerPID)，我是 \(myPID().map(String.init) ?? "?")）")
        send("cancel", ["src": "switch"])
        return true
    }

    /// 说话时输入框里的字跟着识别结果走
    private func liveUpdate(_ text: String, sid: Int, cuts: Int, base: Int) {
        guard sid != dead else { return }
        predictions = []
        if sid != liveSID { liveSID = sid; live = ""; liveFinal = false; myCuts = cuts; liveBase = base; liveDoc = currentDoc() }
        guard !liveFinal, cuts == myCuts else { return }          // 我刚冻结过、App 还没跟上：这条是冻结之前的旧内容
        if !live.isEmpty, !stillAtEnd() { freeze(); return }      // 光标被挪走 / 字被删改过：这一段冻结，后面的话从新位置接着写
        liveBase = base
        setLive(text)
    }

    /// 用户在说话中途动了输入框（删字、挪光标、打字）：已经打进去的那段就此冻结（不再被识别结果覆盖、也不被润色替换，
    /// 免得把用户亲手改好的又改回去），告诉 App 它前面多少个字冻结了，后面新说的话接着打在用户现在的光标处
    private func freeze() {
        guard recordingNow, !live.isEmpty, !liveFinal, liveSID != dead else { return }
        let n = liveBase + SpeechSegments.solid(live)
        myCuts += 1
        live = ""
        send("cut", ["n": n, "k": myCuts])
        refreshBar()
    }

    /// 主 App 给了一条结果（先是原文，润色好了再来一条）：把这次听写在输入框里的那段换成它；没见过这次录音就直接打进去
    private func applyResult(_ t: String, sid: Int, cuts: Int) {
        // 只收我亲眼看着录音的那一次（liveSID）的结果。新弹出的键盘实例没见过上一段录音，却会读到 App 里还留着的结果，
        // 以前它照单全收，发完消息再开新窗口，上一段话就被整段打了进去
        guard sid != dead, sid == liveSID else { return }
        guard cuts == myCuts else { return }                      // 这条是我冻结之前的完整内容，现在的输入框已经不是那样了
        if currentDoc() != liveDoc { dead = sid; live = ""; refreshBar(); return }    // 已经换了输入框（新窗口）：别往里塞
        if liveFinal, !stillAtEnd() { dead = sid; live = ""; refreshBar(); return }   // 光标挪走了 / 用户改过，别乱删
        setLive(t)
        liveFinal = true
        if let e = engine, let lm = e.lm, let u = e.user {      // 语音整理好的话也学（你常说的词、搭配）
            onEngine { u.learnText(lm, t) }
            scheduleUserSave()
        }
        refreshBar()
    }

    /// 光标是不是还在这段听写文字的后面（读不到上下文就信它）
    /// 光标前面的文字；测试时可以换成假的（没有宿主 App，textDocumentProxy 什么都读不到）
    var contextProbe: (() -> String?)?

    private func contextBefore() -> String? { contextProbe.map { $0() } ?? textDocumentProxy.documentContextBeforeInput }

    private func currentDoc() -> UUID { docProbe?() ?? textDocumentProxy.documentIdentifier }

    /// 这段听写还在光标前面吗。输入框空了（消息发出去了、换了新对话 / 新输入框）= 不在了：
    /// 以前空框读出来是 nil、空串，都被当成「还在」，晚到的润色结果就把整段话又打进了新的输入框
    private func stillAtEnd() -> Bool {
        if live.isEmpty { return true }
        guard let ctx = contextBefore(), !ctx.isEmpty else { return live.hasSuffix("\n") }
        return ctx.hasSuffix(live) || live.hasSuffix(ctx)
    }

    /// 把输入框里的这段文字改成 new：只删改动的尾巴、补新的尾巴，前面一致的部分不动
    private func setLive(_ new: String) {
        if live.isEmpty { liveDoc = currentDoc() }      // 这一段从这个输入框里开始
        let o = Array(live), n = Array(new)
        var i = 0
        while i < o.count, i < n.count, o[i] == n[i] { i += 1 }
        for _ in 0..<(o.count - i) { textDocumentProxy.deleteBackward() }
        if i < n.count { textDocumentProxy.insertText(String(n[i...])) }
        live = new
    }

    /// 用户自己打了字 / 点了标点 / 删除：说话中就冻结已经打进去的；说完在等结果时就不再替换了，免得删错
    private func userTyped() {
        if recordingNow { freeze() } else if !liveFinal { dead = liveSID }
    }

    private func undoVoice() {
        if !clearedText.isEmpty { undoClear(); return }
        if stillAtEnd() { for _ in 0..<live.count { textDocumentProxy.deleteBackward() } }
        dead = liveSID
        live = ""
        refreshBar()
    }

    // MARK: 删除键（按住连删）

    @objc private func delDown() {
        keyFeedback()
        clearing = false
        pressDeleted = composing ? nil : contextBefore()?.last.map { String($0) }
        deleteOnce()
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                self?.deleteOnce()
            }
        }
    }

    @objc private func delUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    /// 在删除键上往左滑（二期）：滑过 60pt 就清空——正在拼的拼音清掉重来；否则清掉光标前面的字，清掉的字暂存起来，顶栏出「撤销」能原样放回去
    private func deleteDrag(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard dx < -60, -dx > abs(dy) * 1.5 else { return clearing }
        if !clearing {
            clearing = true
            deleteTimer?.invalidate()
            deleteTimer = nil
            clearAll()
        }
        return true
    }

    private func clearAll() {
        typed()
        if composing {
            buffer = ""
            cands = []
            updatePredictions()
            refreshBar()
            return
        }
        var removed = ""
        var budget = 3000
        while budget > 0, let ctx = textDocumentProxy.documentContextBeforeInput, !ctx.isEmpty {
            removed = ctx + removed
            budget -= ctx.count
            for _ in 0..<ctx.count { textDocumentProxy.deleteBackward() }
        }
        ctxTail = ""
        predictions = []
        clearedText = removed + (pressDeleted ?? "")      // 按下去那一下已经删掉的那个字也算进去
        refreshBar()
    }

    /// 把刚才左滑清掉的字放回去
    private func undoClear() {
        guard !clearedText.isEmpty else { return }
        textDocumentProxy.insertText(clearedText)
        ctxTail = String(clearedText.suffix(12))
        clearedText = ""
        updatePredictions()
        refreshBar()
    }
}
