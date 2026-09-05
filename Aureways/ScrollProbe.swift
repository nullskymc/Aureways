#if DEBUG
import AppKit
import QuartzCore

/// Scroll-cost probe for the transcript.
///
/// Deliberately shaped as **fixed work, measured time**: it performs a fixed
/// number of scroll steps and, for each one, forces layout and display
/// synchronously and times that. An earlier version drove scroll from a 120 Hz
/// timer and measured frame pacing; that was unsound, because an occluded or
/// inactive window has its drawing throttled, so the timer ran at full rate
/// doing almost no work and a slow configuration measured as fast.
///
///     AUREWAYS_PERF_TURNS=50 AUREWAYS_PERF_SCROLL=1 \
///       .derived/Build/Products/Debug/Aureways.app/Contents/MacOS/Aureways
///
/// What the number means: the main-thread cost of moving the transcript by one
/// 55 pt step and bringing the view tree back to a displayable state. It is not
/// a frame time — there is no async compositing in the loop — so read it as a
/// relative measure for comparing configurations at equal transcript size, not
/// as an absolute fps figure.
@MainActor
final class ScrollProbe {
    static let shared = ScrollProbe()

    /// 600 steps × 55 pt = 33,000 pt of travel, more than one full pass over a
    /// 300-block transcript, so view creation and release both get exercised.
    private let steps = 600
    private let pixelsPerStep: CGFloat = 55
    /// Let the first render and the highlight queue settle before measuring.
    private let warmup: CFTimeInterval = 6

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["AUREWAYS_PERF_SCROLL"] == "1"
    }

    func start() {
        guard Self.isRequested else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + warmup) {
            MainActor.assumeIsolated { Self.shared.run() }
        }
    }

    private func run() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView,
              let scrollView = Self.tallestScrollView(in: content),
              let document = scrollView.documentView else {
            NSLog("[perf] scroll probe: no transcript scroll view found")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let clip = scrollView.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        NSLog(
            "[perf] scroll probe: %d steps × %.0f pt over %.0f pt of content, %.0f pt viewport",
            steps, pixelsPerStep, document.bounds.height, clip.bounds.height
        )
        guard maxY > 0 else {
            NSLog("[perf] scroll probe: content shorter than viewport, nothing to scroll")
            return
        }

        let rssAtStart = Self.residentMB()
        let cpuAtStart = Self.processCPUSeconds()
        let wallAtStart = CACurrentMediaTime()
        PerfCounters.reset()

        var costs: [Double] = []
        costs.reserveCapacity(steps)
        var y: CGFloat = 0
        var direction: CGFloat = 1

        for _ in 0..<steps {
            y += direction * pixelsPerStep
            if y >= maxY { y = maxY; direction = -1 } else if y <= 0 { y = 0; direction = 1 }

            // Real scrolling returns to the run loop every frame, which drains
            // the autorelease pool. This loop does not, so without an explicit
            // pool per step the peak footprint is an artefact of the probe
            // rather than a property of the transcript.
            let start = DispatchTime.now().uptimeNanoseconds
            autoreleasepool {
                clip.setBoundsOrigin(CGPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
                // Force the work this step implies to happen now, inside the
                // timed region, instead of being deferred to a display cycle we
                // are not measuring.
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
            }
            costs.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }

        report(
            costs: costs,
            cpu: Self.processCPUSeconds() - cpuAtStart,
            wall: CACurrentMediaTime() - wallAtStart,
            rssAtStart: rssAtStart,
            occluded: !window.occlusionState.contains(.visible),
            inactive: !NSApp.isActive,
            groupCalls: PerfCounters.groupCalls
        )
        checkRendering(scrollView: scrollView, content: content, window: window, heightAtStart: document.bounds.height)
        trackMemorySettling(from: rssAtStart)
    }

    /// The loop above never returns to the run loop, so nothing that is released
    /// on a run-loop turn — the autorelease pool, SwiftUI's deferred teardown of
    /// off-screen views — gets a chance to run while it is measuring. Watch RSS
    /// once the run loop is going again to tell a real leak from a deferred
    /// release.
    private func trackMemorySettling(from rssAtStart: Double) {
        let peak = Self.residentMB()
        let cache = MarkdownDocumentCache.shared.debugFootprint
        NSLog(
            "[perf]   markdown cache: %d entries, %d KB of sources behind them",
            cache.entries, cache.sourceKB
        )
        for delay in [1.0, 3.0, 10.0, 30.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let now = Self.residentMB()
                NSLog(
                    "[perf]   rss +%.0fs idle: %.0f MB (peak %.0f, start %.0f, %.0f%% of the growth released)",
                    delay, now, peak, rssAtStart,
                    peak > rssAtStart ? (peak - now) / (peak - rssAtStart) * 100 : 0
                )
            }
        }
    }

    /// A virtualized stack estimates the height of everything it has not placed,
    /// so the scrollable extent can be wrong and the viewport can come up empty
    /// — the failure the eager `VStack` was working around. Jump to the bottom,
    /// force layout, and report what is actually there.
    private func checkRendering(
        scrollView: NSScrollView,
        content: NSView,
        window: NSWindow,
        heightAtStart: CGFloat
    ) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        clip.setBoundsOrigin(CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(clip)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()

        let visible = clip.bounds
        var total = 0
        var inViewport = 0
        func walk(_ view: NSView) {
            for sub in view.subviews {
                total += 1
                let frame = sub.convert(sub.bounds, to: clip)
                if frame.intersects(visible), frame.height > 1 { inViewport += 1 }
                walk(sub)
            }
        }
        walk(document)
        NSLog("""
        [perf] rendering check at bottom
        [perf]   content height: %.0f pt at start -> %.0f pt after a full traversal
        [perf]   document subviews: %d total, %d intersecting the viewport
        """,
        heightAtStart, document.bounds.height, total, inViewport)
    }

    private func report(
        costs: [Double],
        cpu: Double,
        wall: Double,
        rssAtStart: Double,
        occluded: Bool,
        inactive: Bool,
        groupCalls: Int
    ) {
        guard !costs.isEmpty else { return }
        if occluded || inactive {
            NSLog(
                "[perf] WARNING: window occluded=%@ app inactive=%@ — drawing may have been throttled",
                occluded ? "yes" : "no", inactive ? "yes" : "no"
            )
        }
        let sorted = costs.sorted()
        func pct(_ p: Double, _ v: [Double]) -> Double { v[min(v.count - 1, Int(Double(v.count) * p))] }
        NSLog("""
        [perf] scroll probe results (cost per 55 pt step, layout + display forced)
        [perf]   steps=%d  total %.2f s wall  mean %.2f ms
        [perf]   per step: median %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms
        [perf]   cpu %.2f s over %.2f s wall = %.0f%% of one core
        [perf]   rss %.0f MB -> %.0f MB (delta %+.0f MB)
        [perf]   TranscriptBlock.group() calls: %d (%.2f per step)
        """,
        costs.count, wall, costs.reduce(0, +) / Double(costs.count),
        pct(0.5, sorted), pct(0.95, sorted), pct(0.99, sorted), sorted.last ?? 0,
        cpu, wall, cpu / wall * 100,
        rssAtStart, Self.residentMB(), Self.residentMB() - rssAtStart,
        groupCalls, Double(groupCalls) / Double(costs.count))

        // Chronological thirds: a lazy stack that accumulates views instead of
        // releasing them gets worse over the run; a warming cache gets better.
        let third = costs.count / 3
        guard third > 4 else { return }
        for (label, slice) in [
            ("first  third", Array(costs[0..<third])),
            ("middle third", Array(costs[third..<(third * 2)])),
            ("last   third", Array(costs[(third * 2)...]))
        ] {
            let s = slice.sorted()
            NSLog(
                "[perf]   %@: median %.2f ms  p95 %.2f ms  max %.2f ms",
                label, pct(0.5, s), pct(0.95, s), s.last ?? 0
            )
        }
    }

    /// The transcript is the tallest scroll view on screen; the sidebar and
    /// inspector scrollers hold far less content.
    private static func tallestScrollView(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var bestHeight: CGFloat = 0
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               let height = scroll.documentView?.bounds.height,
               height > bestHeight {
                best = scroll
                bestHeight = height
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ tv: timeval) -> Double {
            Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
#endif
