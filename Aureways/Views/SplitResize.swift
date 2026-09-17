import Foundation
import SwiftUI

/// 分栏拖动期间的状态机：从"每帧都在变的宽度"里提炼出"开始拖动 / 停止拖动"
/// 这个边沿信号。
///
/// 为什么必须是引用类型：`@StateObject` 只会因 `@Published` 属性变化而让视图失效，
/// 而拖动期间每帧喂进来的宽度只写普通属性——于是**连续拖动过程中不产生任何
/// SwiftUI 更新**。这正是修复分栏拖动卡顿与崩溃的关键。
///
/// 旧实现用三个 `@State`（`isResizing` / `resizeGeneration` / `lastWidth`）承接
/// `onGeometryChange` 的回调，其中 `resizeGeneration` 每帧无条件自增，等于每拖一帧
/// 就让整个检查器面板失效一次（`ZStack` 内所有标签页一起重排）。这些失效在同一
/// 显示周期里把 `setNeedsUpdateConstraints` 反复顶上窗口，累积到 AppKit 的限额后
/// `-[NSWindow _postWindowNeedsUpdateConstraints]` 抛异常，进程被
/// `+[NSApplication _crashOnException:]` 终止——诊断报告里那条
/// `Marking window ... (limit: 277, count: 279)` 就是它。
@MainActor
final class SplitResizeEngine: ObservableObject {

    /// 是否正在拖动。只在拖动开始与结束这两个边沿翻转，一个拖动周期只让视图失效两次。
    @Published private(set) var isResizing = false

    /// 拖动开始那一刻的宽度。拖动期间内容按它布局，松手后一次性按最终宽度排。
    /// 刻意不做成 `@Published`：它始终与 `isResizing` 同时变化，单独变化没有意义。
    private(set) var frozenWidth: CGFloat?

    /// 最近一次观测到的面板宽度，只用于判断"是否真的变了"。
    private var lastWidth: CGFloat = 0

    /// 指针是否按着。**这是拖动的唯一判据。**
    ///
    /// 曾经用"宽度多久没变"当判据，它无法区分"用户中途停顿"和"用户松手"：按住鼠标
    /// 停顿超过阈值就会提前解冻、内容重排，看起来就是界面渲染跑在拖动前面。按下 /
    /// 抬起才是事实依据。
    private var isPointerDown = false

    private var eventMonitor: Any?

    /// 兜底：鼠标抬起事件丢失（模态抢走事件、进程被挂起等）时自我恢复。
    /// 可注入是为了让单测不必和真实时长抢时间。
    private let safetyDelay: Duration

    private var safetyTask: Task<Void, Never>?

    init(safetyDelay: Duration = .seconds(3)) {
        self.safetyDelay = safetyDelay
    }

    // MARK: - 指针事件

    /// 安装本地事件监视器。只在检查器存在期间安装，`reset()` 里移除。
    ///
    /// 用本地鼠标监视器而不是去上层找 `NSSplitView`：`.inspector` / `NavigationSplitView`
    /// 内部用什么容器实现属于 SwiftUI 的实现细节，顺着视图树找分隔条更脆。
    func beginMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            // 本地监视器的回调固定发生在主线程。
            MainActor.assumeIsolated {
                switch event.type {
                case .leftMouseDown: self?.setPointerDown(true)
                case .leftMouseUp: self?.setPointerDown(false)
                default: break
                }
            }
            return event
        }
    }

    /// 指针按下 / 抬起。生产路径由事件监视器驱动，单测直接调用。
    func setPointerDown(_ isDown: Bool) {
        guard isPointerDown != isDown else { return }
        isPointerDown = isDown
        // 抬起即解冻，不等任何计时器——这才是"停手后再渲染"。
        if !isDown { finishResize() }
    }

    // MARK: - 宽度输入

    /// 每次几何回调都调用它。连续拖动时这里**不写任何 observable 状态**。
    func note(width: CGFloat) {
        guard width > 0 else { return }

        let previous = lastWidth
        let delta = abs(width - previous)
        lastWidth = width

        // 首次上报只能记录基准：此时还不知道面板原本多宽。
        guard previous > 0, delta > 0.5 else { return }
        // 只有"指针按着 + 宽度真的在变"同时成立才冻结。宽度变化也可能来自窗口缩放、
        // 检查器展开动画或程序化设置，那些情况不该把内容钉在旧宽度上。
        guard isPointerDown else { return }

        if !isResizing {
            // 用"变化前"的宽度冻结，避免拖动第一帧先闪一下新宽度。
            frozenWidth = previous
            isResizing = true
        }
        armSafetyTimeout()
    }

    /// 面板收起 / 视图消失时收尾：移除监视器并清空拖动状态。
    func reset() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isPointerDown = false
        lastWidth = 0
        finishResize()
    }

    private func armSafetyTimeout() {
        safetyTask?.cancel()
        safetyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.safetyDelay ?? .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.finishResize()
        }
    }

    private func finishResize() {
        safetyTask?.cancel()
        safetyTask = nil
        frozenWidth = nil
        if isResizing { isResizing = false }
    }
}

/// 只改变"给子视图的提议宽度"，自己始终照单接受父级提议。
///
/// 这是分栏冻结的正确实现方式：**容器尺寸恒等于父级提议，冻结与否都不改变自己占的
/// 空间**，因此子视图的固定宽度不会泄漏给 `NavigationSplitView` 的分栏。
///
/// 反面教材是 `.frame(width: frozenWidth)`。它会把该宽度当成内容的*理想宽度*，并穿过
/// 外层的 `.frame(maxWidth: .infinity)` 继续往上传播；分栏读到这个理想宽度后就把列
/// 钉住——把分栏拉到最大宽度后就再也拉不回来，夹紧边界处反复夹紧 / 回弹又让拖动状态
/// 反复翻转、蒙层动画不停闪烁。这条是实测踩过的坑，别改回去。
struct FrozenWidthLayout: Layout {
    /// `nil` 表示不冻结：完全跟随父级提议，等价于不干预布局。
    var frozenWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 有明确提议时照单接受（等价于原来的 `.frame(maxWidth: .infinity, maxHeight: .infinity)`）；
        // 没有提议（理想尺寸查询）时退回子视图自己的理想尺寸，保证列宽的
        // min / ideal / max 仍由 `.inspectorColumnWidth` 决定。
        if let width = proposal.width, let height = proposal.height {
            return CGSize(width: width, height: height)
        }
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(
            width: proposal.width ?? ideal.width,
            height: proposal.height ?? ideal.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        // 冻结时子视图拿到拖动开始那一刻的宽度、按左上角放置；面板变窄后超出的部分
        // 由外层的 `.clipped()` 裁掉，而不是让内容重新换行。
        let childWidth = frozenWidth ?? bounds.width
        for subview in subviews {
            subview.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: childWidth, height: bounds.height)
            )
        }
    }
}
