import UIKit
import ObjectiveC

/// 认出键盘正在给哪个 App 打字（宿主 App 的 bundle id），主 App 录上音后靠它自动跳回去。
/// 全是 UIKit 私有接口，按名字在运行时取，读不到就返回 nil（调用方退回「请手动划回去」）。
/// 思路来自开源项目 Dictus（MIT）的 HostAppResolver：
///   1. iOS 26.4 以前，宿主的 bundle id 直接挂在输入法控制器上（_hostBundleID）；
///   2. 之后只能从 _UIKeyboardArbiterClient 的 sourceBundleIdentifier 里读，但它偶尔会指着上一个 App，
///      所以只信「进程号 → bundle id」的对应表：宿主进程号（_hostProcessIdentifier，控制器上读，不会过期）
///      必须在本次键盘出现之后被 arbiter 报过，才算数；宁可没答案，也不能答错（答错会打开错的 App）。
enum HostApp {
    private struct Seen { let bundle: String; let gen: Int }
    private static var table: [Int: Seen] = [:]
    private static var gen = 0

    /// 键盘每次出现调一次：上一次出现时记下的对应都作废（进程号会被系统回收复用）
    static func keyboardWillAppear() {
        gen &+= 1
        lastEnsure = ensureConnection()
        harvest(force: true)
    }

    /// 最近一次登记 arbiter 的结果（connected / started / no-client / no-selector），给日志看
    private(set) static var lastEnsure = "-"
    private static var lastHarvest = Date.distantPast

    /// 向系统的 arbiter 守护进程登记本键盘。arbiter 的记录是「推」来的：宿主一弹出键盘，守护进程只把记录发给登记过的键盘，
    /// 键盘每次离开屏幕登记就作废；不重新登记，读到的就是上一个宿主的旧记录（Dictus #543：登记后 8/8 命中，不登记 3/10）。
    /// startConnection 就是发 startArbitration 的那个调用；已经有连接就不重复登记。
    @discardableResult
    static func ensureConnection() -> String {
        guard let client = arbiterClient() else { return "no-client" }
        guard read("connection", from: client) == nil else { return "connected" }
        let sel = NSSelectorFromString("startConnection")
        guard client.responds(to: sel) else { return "no-selector" }
        _ = client.perform(sel)
        return "started"
    }

    /// 读私有属性：KVC 碰到不存在的 key 会抛 ObjC 异常、Swift 接不住，所以先确认有 getter 或实例变量
    private static func read(_ key: String, from o: NSObject) -> Any? {
        let hasIvar = class_getInstanceVariable(object_getClass(o), key) != nil
        guard o.responds(to: NSSelectorFromString(key)) || hasIvar else { return nil }
        return o.value(forKey: key)
    }

    private static func arbiterClient() -> NSObject? {
        var cls: NSObject.Type?
        for n in ["_UIKeyboardArbiterClient", "UIKeyboardArbiterClient"] {
            if let c = NSClassFromString(n) as? NSObject.Type { cls = c; break }
        }
        guard let cls else { return nil }
        let sel = NSSelectorFromString("automaticSharedArbiterClient")
        let obj = cls as AnyObject
        guard obj.responds(to: sel) else { return nil }
        return obj.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private static func arbiterState() -> NSObject? {
        guard let client = arbiterClient() else { return nil }
        return read("currentClientState", from: client) as? NSObject
    }

    /// arbiter 此刻说的宿主和进程号（只给日志看）
    private static func arbiterClaim() -> String {
        guard let st = arbiterState() else { return "none" }
        let b = read("sourceBundleIdentifier", from: st) as? String
        let pid = (read("processIdentifier", from: st) as? NSNumber)?.intValue
        return "\(b ?? "nil")/\(pid.map(String.init) ?? "nil")"
    }

    /// 记下 arbiter 现在说的「谁是宿主」，连同它的进程号
    static func harvest(force: Bool = false) {
        if !force, Date().timeIntervalSince(lastHarvest) < 0.25 { return }      // 文字变化、光标移动都会来，别每次都读私有状态
        lastHarvest = Date()
        guard let st = arbiterState(),
              let b = read("sourceBundleIdentifier", from: st) as? String, !b.isEmpty,
              let pid = (read("processIdentifier", from: st) as? NSNumber)?.intValue, pid > 0
        else { return }
        table[pid] = Seen(bundle: b, gen: gen)
        if table.count > 64, let k = table.keys.first(where: { $0 != pid }) { table.removeValue(forKey: k) }
    }

    /// 返回（宿主 bundle id 或 nil，怎么认出来的/为什么没认出来——给主 App 日志看）
    static func resolve(_ vc: UIInputViewController) -> (id: String?, how: String) {
        let holders: [(String, NSObject?)] = [
            ("vc", vc), ("parent", vc.parent), ("parent2", vc.parent?.parent),
            ("ctx", vc.extensionContext), ("scene", vc.view.window?.windowScene),
        ]
        var seen: [String] = []
        for (name, obj) in holders {
            guard let obj else { continue }
            seen.append("\(name)=\(type(of: obj))")
            for key in ["_hostBundleID", "hostBundleID"] {
                guard let s = read(key, from: obj) as? String, !s.isEmpty else { continue }
                if looksLikeBundleID(s) { return (s, "\(name).\(key)") }
                seen.append("\(name).\(key)=\(s.prefix(30))")      // iOS 18.7 上读出来是字面的「<null>」：不能当真，记下来接着试别的办法
            }
        }
        // 已知的名字都没有：把名字带 host / bundle 的取值方法和实例变量全读一遍，读到像 bundle id 的就用
        let p = probe(holders)
        if let id = p.id { return (id, "probe \(p.report)") }
        harvest()
        guard let pid = (read("_hostProcessIdentifier", from: vc) as? NSNumber)?.intValue, pid > 0 else {
            return (nil, "no-host-id [\(seen.joined(separator: " "))] arb=\(arbiterClaim()) probe \(p.report)")     // 把能看到的对象类名带回去，下次好对症
        }
        guard let s = table[pid], s.gen == gen else { return (nil, "table-miss pid=\(pid) known=\(table.count) arb=\(arbiterClaim()) probe \(p.report)") }
        return (s.bundle, "arbiter pid=\(pid)")
    }

    /// 键盘出现时的一行诊断：宿主进程号、arbiter 登记结果和它此刻说的宿主、输入框的类型（微信里调不起键盘时用来对比）
    static func diag(_ vc: UIInputViewController) -> String {
        let t = vc.textDocumentProxy
        return "宿主pid=\(hostPID(vc).map(String.init) ?? "nil") arb=\(lastEnsure)/\(arbiterClaim()) 键盘类型=\(t.keyboardType?.rawValue ?? -1) 回车=\(t.returnKeyType?.rawValue ?? -1) 密码框=\(t.isSecureTextEntry ?? false) 完全访问=\(vc.hasFullAccess)"
    }

    /// 宿主进程号（控制器上读，不会过期）。认不出 bundle id 时让主 App 拿它去查宿主的可执行文件路径
    static func hostPID(_ vc: UIInputViewController) -> Int? {
        guard let n = (read("_hostProcessIdentifier", from: vc) as? NSNumber)?.intValue, n > 0 else { return nil }
        return n
    }

    /// 像不像 bundle id（com.apple.mobilenotes 这种）。系统会塞进来「<null>」「(null)」之类的占位字符串
    static func looksLikeBundleID(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }

    /// 宿主挂在 iOS 18.7 的哪个对象上，只有真机能回答：读到的字符串原样记进报告（随主 App 日志传到服务器）。
    /// 只碰名字带 host / bundle 的零参数取值方法和对象类型的实例变量；ivar 用 object_getIvar 读，不走 KVC（KVC 碰到没有的 key 会抛 Swift 接不住的异常）。
    private static func probe(_ holders: [(String, NSObject?)]) -> (id: String?, report: String) {
        var out: [String] = []
        var pick: String?
        func relevant(_ n: String) -> Bool { n.range(of: "host|bundle", options: [.regularExpression, .caseInsensitive]) != nil }
        func note(_ key: String, _ v: Any) {
            guard out.count < 16 else { return }
            if let s = v as? String {
                out.append("\(key)=\(s.prefix(60))")
                let low = key.lowercased()
                if pick == nil, low.contains("host"), low.contains("bundle") || low.contains("identifier"),
                   looksLikeBundleID(s),
                   !s.hasPrefix("com.simpleninga."), !s.hasPrefix("com.apple.UIKit") { pick = s }
            } else {
                out.append("\(key):\(type(of: v))")
            }
        }
        for (hname, holder) in holders {
            guard let obj = holder else { continue }
            var cls: AnyClass? = object_getClass(obj)
            var depth = 0
            while let c = cls, c != NSObject.self, depth < 10 {
                depth += 1
                var n: UInt32 = 0
                if let ivars = class_copyIvarList(c, &n) {
                    for i in 0..<Int(n) {
                        let np: UnsafePointer<CChar>? = ivar_getName(ivars[i])
                        let tp: UnsafePointer<CChar>? = ivar_getTypeEncoding(ivars[i])
                        guard let np, let tp else { continue }
                        let name = String(cString: np)
                        guard String(cString: tp).hasPrefix("@"), relevant(name) else { continue }
                        let v: Any? = object_getIvar(obj, ivars[i])
                        guard let v else { continue }
                        note("\(hname).\(name)", v)
                    }
                    free(ivars)
                }
                var m: UInt32 = 0
                if let methods = class_copyMethodList(c, &m) {
                    for i in 0..<Int(m) {
                        let meth = methods[i]
                        let sel = method_getName(meth)
                        let name = NSStringFromSelector(sel)
                        guard relevant(name), !name.contains(":"), method_getNumberOfArguments(meth) == 2, obj.responds(to: sel) else { continue }
                        let rt: UnsafeMutablePointer<CChar>? = method_copyReturnType(meth)
                        guard let rt else { continue }
                        let isObject = String(cString: rt) == "@"
                        free(rt)
                        guard isObject else { continue }
                        let v: AnyObject? = obj.perform(sel)?.takeUnretainedValue()
                        guard let v else { continue }
                        note("\(hname).\(name)", v)
                    }
                    free(methods)
                }
                cls = class_getSuperclass(c)
            }
        }
        return (pick, out.isEmpty ? "(nothing)" : out.joined(separator: " "))
    }
}
