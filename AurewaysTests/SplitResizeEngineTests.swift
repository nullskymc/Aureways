import Combine
import XCTest
@testable import Aureways

/// `SplitResizeEngine` 的核心契约有两条：
///
/// 1. **连续拖动过程中不得产生 observable 状态翻转**，每个拖动周期只在开始 / 结束两个
///    边沿各翻一次。旧实现把 `isResizing` / `resizeGeneration` / `lastWidth` 放在三个
///    `@State` 上，其中 `resizeGeneration` 每帧无条件自增，于是每拖一帧就让整个检查器
///    面板失效一次；这些失效在同一显示周期内把 `setNeedsUpdateConstraints` 反复顶到窗口，
///    累积超过 AppKit 的限额后由 `-[NSWindow _postWindowNeedsUpdateConstraints]` 抛异常。
/// 2. **拖动起止只认指针按下 / 抬起**。曾经用"宽度多久没变"当判据，它无法区分"用户中途
///    停顿"和"用户松手"，会在用户仍按住鼠标时提前解冻、让内容重排。
@MainActor
final class SplitResizeEngineTests: XCTestCase {

    /// 单测用较长的兜底时长，避免和真实 3s 抢时间导致偶发失败。
    private let safetyDelay = Duration.seconds(30)

    /// 第一次上报只能建立基准：此时还不知道面板原本多宽，不应进入拖动状态。
    func testFirstSampleOnlyRecordsBaseline() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.setPointerDown(true)
        engine.note(width: 440)
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)
    }

    /// 指针没按着时的宽度变化（窗口缩放、检查器展开动画、程序化设置）不得触发冻结。
    func testWidthChangeWithoutPointerDownDoesNotFreeze() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.note(width: 440)
        engine.note(width: 520)
        engine.note(width: 600)
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)
    }

    /// 连续拖动只翻一次 `true`，冻结宽度取"变化前"的值。
    func testPointerDownDragFlipsOnceAndFreezesPreviousWidth() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.note(width: 440)
        engine.setPointerDown(true)

        var flips: [Bool] = []
        let subscription = engine.$isResizing.dropFirst().sink { flips.append($0) }
        defer { subscription.cancel() }

        for width in stride(from: 441, through: 520, by: 1) {
            engine.note(width: CGFloat(width))
        }

        XCTAssertEqual(flips, [true], "连续拖动不应该反复翻转 isResizing")
        XCTAssertTrue(engine.isResizing)
        XCTAssertEqual(engine.frozenWidth, 440)
    }

    /// 小于 0.5pt 的抖动不算拖动，避免窗口边缘亚像素变化就冻结内容。
    func testSubThresholdJitterDoesNotStartResize() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.setPointerDown(true)
        engine.note(width: 440)
        engine.note(width: 440.2)
        engine.note(width: 440.1)
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)
    }

    /// 指针抬起立即解冻，不等任何计时器——这是"停手后再渲染"的判据。
    func testPointerUpEndsFreezeImmediately() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.note(width: 440)
        engine.setPointerDown(true)
        engine.note(width: 500)
        XCTAssertTrue(engine.isResizing)

        engine.setPointerDown(false)
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)
    }

    /// 拖动中途的亚像素抖动既不能启动、也不能结束冻结：用户仍按着鼠标，内容必须停在旧宽度。
    ///
    /// 回归用例：分栏在夹紧边界附近来回抖 1pt 时，若亚阈值变化被当成"没有活动"，旧的静默
    /// 计时器会在拖动中途到期，`isResizing` 反复翻转、蒙层动画不停闪烁。
    func testSubThresholdJitterDuringDragDoesNotEndFreeze() async throws {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.note(width: 440)
        engine.setPointerDown(true)
        engine.note(width: 460)
        XCTAssertTrue(engine.isResizing)

        var width: CGFloat = 460
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(120))
            width += 0.1
            engine.note(width: width)
            XCTAssertTrue(engine.isResizing, "指针仍按着，亚像素抖动不应该解除冻结")
        }

        engine.setPointerDown(false)
        XCTAssertFalse(engine.isResizing)
    }

    /// 兜底：鼠标抬起事件丢失时，冻结状态必须能自我恢复，不能永久钉在旧宽度上。
    func testSafetyTimeoutRecoversWhenPointerUpIsLost() async throws {
        let engine = SplitResizeEngine(safetyDelay: .milliseconds(300))
        engine.note(width: 440)
        engine.setPointerDown(true)
        engine.note(width: 500)
        XCTAssertTrue(engine.isResizing)

        // 不调用 setPointerDown(false)，模拟抬起事件丢失。
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)
    }

    /// `reset()` 用于面板收起 / 视图消失，必须立刻回到干净状态。
    func testResetClearsDragState() {
        let engine = SplitResizeEngine(safetyDelay: safetyDelay)
        engine.note(width: 440)
        engine.setPointerDown(true)
        engine.note(width: 500)
        XCTAssertTrue(engine.isResizing)

        engine.reset()
        XCTAssertFalse(engine.isResizing)
        XCTAssertNil(engine.frozenWidth)

        // 重置后第一次上报重新建立基准，不应被上一轮的宽度判成"正在拖动"。
        engine.setPointerDown(true)
        engine.note(width: 600)
        XCTAssertFalse(engine.isResizing)
    }
}
