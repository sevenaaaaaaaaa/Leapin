/// T-02：状态栏图标的字形与无障碍文案。
///
/// 为什么放在 LeapinRuntime 而不是 App 里：状态栏是模板渲染，颜色会被系统抹掉，
/// 四个 tone 只剩字形可用；字形一旦写进 SwiftUI 视图就没法单测。这里只有纯映射，
/// 不 import SwiftUI，测试可以直接断言。
///
/// 四态四个字形：关着（斜线盾）/ 正常（空盾）/ 降级（感叹号盾）/ 失败（叉盾）。
/// 关着和跑着必须长得不一样——“App 没在跑”本身是要看见的信息，不能被并进正常态；
/// 报警只由 degraded（还在跑，但有一件事不对）和 failed（引擎自己失败）承担。
public extension ResidentTone {

    /// SF Symbol 名。idle → 斜线盾；normal → 空盾；degraded → 感叹号盾；failed → 叉盾。
    var iconName: String {
        switch self {
        case .idle:
            return "shield.slash"
        case .normal:
            return "shield.lefthalf.filled"
        case .degraded:
            return "exclamationmark.shield.fill"
        case .failed:
            return "xmark.shield.fill"
        }
    }

    /// VoiceOver 读到的文案。四句互不相同，否则读起来还是同一个图标。
    var accessibilityText: String {
        switch self {
        case .idle:
            return "Leapin 未运行"
        case .normal:
            return "Leapin 运行中"
        case .degraded:
            return "Leapin 运行中，但有一项降级"
        case .failed:
            return "Leapin 代理出错"
        }
    }
}
