// 键盘扩展里识别「我正在给哪个 App 打字」要用到 UIKit 的私有类 _UIKeyboardArbiterClient，
// 它默认是关着的（+enabled 返回 NO）；这里在扩展一加载（main 之前）就把 +enabled 换成返回 YES。
// 做法和理由来自开源项目 Dictus（MIT，getdictus/dictus-ios，DictusKeyboard/HostArbiterActivation.m）：
// 晚了（比如等到 viewWillAppear）UIKit 已经决定不创建这个客户端，就读不到了。
// 这段代码在一切之前跑，所以每一步都判空、不打日志、不做 I/O。读不到时键盘照常用，只是不能自动跳回。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void VoiceKBActivateArbiterAtLoad(void) {
    // 原先只在 iOS 26.4 及以后动这一刀（以为更早的系统直接读 _hostBundleID 就行）；2026-10-23 真机日志证明 iOS 18.7 上
    // _hostBundleID 读出来是字面的「<null>」、arbiter 也是关着的（arb=none），所以所有版本都开。
    Class cls = NSClassFromString(@"_UIKeyboardArbiterClient");
    if (cls == Nil) cls = NSClassFromString(@"UIKeyboardArbiterClient");
    if (cls == Nil) return;
    Method method = class_getClassMethod(cls, NSSelectorFromString(@"enabled"));
    if (method == NULL) return;
    IMP replacement = imp_implementationWithBlock(^BOOL(id _self) { return YES; });
    method_setImplementation(method, replacement);
}
