import AppKit
import QuartzCore

/// Opt-in frame-pacing probe for window chrome work, started only by
/// `-AurewaysPerfProbe <out.json>` on the command line (dormant otherwise).
///
/// It resizes the main window in place (width only; the origin never moves,
/// so the window stays on its display), toggles the sidebar an even number of
/// times, records display-link frame intervals and this process's CPU time
/// per phase, restores the original frame, writes a JSON report and quits.
/// Wall-clock phase bounds let an outside sampler attribute WebKit / GPU /
/// WindowServer CPU and GPU utilisation to the same phases.
@MainActor
final class PerfProbe: NSObject {
    static let defaultsKey = "AurewaysPerfProbe"
    private static var shared: PerfProbe?
    /// Page → native messages by type while the probe runs (`role:type`).
    private static var messages: [String: Int] = [:]
    static var isRunning: Bool { shared != nil }

    static func noteMessage(_ type: String, role: WebShellBridge.Role) {
        messages["\(role):\(type)", default: 0] += 1
    }

    static func startIfRequested(window: NSWindow, host: NSView) {
        guard shared == nil,
              let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else { return }
        let probe = PerfProbe(window: window, host: host, output: URL(fileURLWithPath: path))
        shared = probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { MainActor.assumeIsolated { probe.begin() } }
    }

    private struct Phase {
        var name: String
        var duration: Double
        var step: ((Double) -> Void)?
    }

    private weak var window: NSWindow?
    private weak var host: NSView?
    private let output: URL
    private var link: CADisplayLink?
    private var phases: [Phase] = []
    private var index = 0
    private var phaseStart: CFTimeInterval = 0
    private var stamps: [CFTimeInterval] = []
    private var cpuStart: Double = 0
    private var wallStart: Double = 0
    private var results: [[String: Any]] = []
    private var originalFrame: NSRect = .zero
    private var messagesStart: [String: Int] = [:]

    private init(window: NSWindow, host: NSView, output: URL) {
        self.window = window
        self.host = host
        self.output = output
    }

    private func begin() {
        guard let window, let host else { return }
        originalFrame = window.frame
        let minWidth = max(window.minSize.width, 760)
        let amplitude = min(360, max(0, originalFrame.width - minWidth))
        let base = originalFrame
        let resize: (Double) -> Void = { [weak self] t in
            guard let window = self?.window else { return }
            // Width only, 1 Hz: origin fixed, so the window never changes display.
            let width = (base.width - amplitude * (1 - cos(2 * .pi * t)) / 2).rounded()
            let frame = NSRect(x: base.minX, y: base.minY, width: width, height: base.height)
            if window.frame != frame { window.setFrame(frame, display: true) }
        }
        var toggles = 0
        let sidebar: (Double) -> Void = { t in
            // 10 toggles, 0.4 s apart: even, so the sidebar ends as it started.
            let due = min(10, Int(t / 0.4) + 1)
            while toggles < due {
                toggles += 1
                WebShellBridge.current?.sendCommand("toggleSidebar")
            }
        }
        phases = [
            Phase(name: "idle", duration: 3),
            Phase(name: "resize", duration: 6, step: resize),
            Phase(name: "settle", duration: 1.5),
            Phase(name: "sidebar", duration: 4.4, step: sidebar),
            Phase(name: "settle2", duration: 1.5),
        ]
        let link = host.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        index = -1
        nextPhase(at: CACurrentMediaTime())
    }

    private func nextPhase(at now: CFTimeInterval) {
        if index >= 0 { finishPhase(at: now) }
        index += 1
        guard index < phases.count else { finish(); return }
        phaseStart = now
        stamps = []
        cpuStart = Self.cpuSeconds()
        messagesStart = Self.messages
        wallStart = Date().timeIntervalSince1970
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        guard index >= 0, index < phases.count else { return }
        let phase = phases[index]
        let t = now - phaseStart
        if t >= phase.duration {
            nextPhase(at: now)
            return
        }
        stamps.append(now)
        phase.step?(t)
    }

    private func finishPhase(at now: CFTimeInterval) {
        let phase = phases[index]
        let wall = Date().timeIntervalSince1970
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
        let refresh = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        let nominal = 1000 / max(refresh, 1)
        func pct(_ p: Double) -> Double { intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count - 1) * p))] }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let dropped = intervals.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        results.append([
            "phase": phase.name,
            "wallStart": wallStart,
            "wallEnd": wall,
            "frames": stamps.count,
            "fps": span > 0 ? Double(stamps.count - 1) / span : 0,
            "refreshHz": refresh,
            "p50ms": pct(0.5), "p95ms": pct(0.95), "p99ms": pct(0.99), "maxms": intervals.last ?? 0,
            "hitches": intervals.filter { $0 > nominal * 1.5 }.count,
            "droppedFrames": dropped,
            "appCPUPercent": (Self.cpuSeconds() - cpuStart) / max(wall - wallStart, 0.001) * 100,
            "messages": Self.messages.compactMapValues { $0 }.reduce(into: [String: Int]()) { out, entry in
                let delta = entry.value - (messagesStart[entry.key] ?? 0)
                if delta > 0 { out[entry.key] = delta }
            },
        ])
    }

    private func finish() {
        link?.invalidate()
        link = nil
        if let window, window.frame != originalFrame { window.setFrame(originalFrame, display: true) }
        let report: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
            "windowWidth": originalFrame.width, "windowHeight": originalFrame.height,
            "backingScale": window?.backingScaleFactor ?? 0,
            "phases": results,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { AppActivation.terminate() } }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
