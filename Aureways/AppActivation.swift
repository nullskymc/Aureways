import AppKit
import SwiftUI

/// Menu bar status item: just the Aureways template icon. (A lowest-remaining
/// percentage used to sit next to it; across providers it matched no specific
/// quota, so it was removed along with its 菜单栏显示剩余额度 setting.)
struct MenuBarExtraLabel: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
            .accessibilityLabel("Aureways")
    }

    private static let templateImage: NSImage = {
        let canvas = NSImage(size: NSSize(width: 16, height: 16))
        canvas.isTemplate = true
        if let named = NSImage(named: "MenuBarIcon") {
            named.isTemplate = true
            canvas.lockFocus()
            named.draw(
                in: NSRect(x: 0, y: 0, width: 16, height: 16),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            canvas.unlockFocus()
        }
        return canvas
    }()
}

/// Settings that no longer exist; their stored values are dropped at launch.
enum RetiredDefaults {
    /// 菜单栏显示剩余额度 (always / whenLow / never).
    static let keys = ["menuBarQuotaIndicator"]

    static func remove(from defaults: UserDefaults = .standard) {
        for key in keys where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
    }
}

extension Notification.Name {
    static let aurewaysRevealMainWindow = Notification.Name("ai.aureways.revealMainWindow")
}

enum AppActivation {
    static let mainWindowID = "main"
    @MainActor static var openMainWindow: (() -> Void)?
    @MainActor static var allowsTermination = false
    @MainActor private static var pendingOpenURLs: [URL] = []
    /// Document open also posts a reopen. Ordering the window front during that
    /// activation makes it flash and jump onto the file's screen.
    @MainActor private static var suppressRevealUntil = Date.distantPast

    /// True while AppKit is delivering an Open Documents (`odoc`) event.
    @MainActor
    static var isOpeningDocument: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.eventID == AEEventID(0x6F646F63)
    }

    @MainActor
    static var shouldSuppressReveal: Bool {
        isOpeningDocument || Date() < suppressRevealUntil
    }

    @MainActor
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.canBecomeMain
                && window.styleMask.contains(.titled)
                && window.styleMask.contains(.closable)
        }
    }

    @MainActor
    static func receiveOpenedURLs(_ urls: [URL]) {
        suppressRevealUntil = Date().addingTimeInterval(0.6)
        pendingOpenURLs.append(contentsOf: urls)
        flushPendingOpens()
    }

    @MainActor
    static func flushPendingOpens() {
        guard let model = AppModel.shared, WebShellBridge.current != nil else { return }
        let urls = pendingOpenURLs
        guard !urls.isEmpty else { return }
        pendingOpenURLs.removeAll()
        // Ordering the window front inside the document-open event makes macOS
        // move it onto the file's screen. A visible window only switches tabs.
        let visible = mainWindows.contains { $0.isVisible && !$0.isMiniaturized }
        if !visible { revealMainWindow() }
        model.openMarkdownDocuments(urls: urls)
    }

    /// 关掉主窗口和 Dock 图标，只留菜单栏。
    @MainActor
    static func resignToMenuBar() {
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    // Four-char codes spelled out ('aevt', 'quit', 'why?', 'spid') so this needs no Carbon import.
    static let coreEventClass = AEEventClass(0x6165_7674)
    static let quitEventID = AEEventID(0x7175_6974)
    static let quitReasonKeyword = AEKeyword(0x7768_793F)
    static let senderPIDKeyword = AEKeyword(0x7370_6964)

    /// A quit Apple Event (`aevt/quit`) that should really end the process: one sent
    /// for logout / restart / shutdown (it carries a `why?` reason), or one from any
    /// sender other than the Dock. The Dock's 退出 keeps the old behaviour and only
    /// resigns to the menu bar, like ⌘Q.
    @MainActor
    static func isExternalQuitRequest(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        let hasReason = event.paramDescriptor(forKeyword: quitReasonKeyword) != nil
        let senderPID = event.attributeDescriptor(forKeyword: senderPIDKeyword)?.int32Value ?? 0
        let senderBundleID = senderPID > 0 ? NSRunningApplication(processIdentifier: pid_t(senderPID))?.bundleIdentifier : nil
        return shouldQuit(eventClass: event.eventClass, eventID: event.eventID, hasQuitReason: hasReason, senderBundleID: senderBundleID)
    }

    /// Pure part of `isExternalQuitRequest` (unit tested).
    static func shouldQuit(eventClass: AEEventClass, eventID: AEEventID, hasQuitReason: Bool, senderBundleID: String?) -> Bool {
        guard eventClass == coreEventClass, eventID == quitEventID else { return false }
        if hasQuitReason { return true }
        return senderBundleID != "com.apple.dock"
    }

    /// 从菜单栏真正退出进程。
    @MainActor
    static func terminate() {
        allowsTermination = true
        NSApp.terminate(nil)
    }

    @MainActor
    static func hideDockIfNoMainWindow() {
        if mainWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Settings 在 `.accessory`（只留菜单栏）时 `openSettings()` 是空操作。
    /// 先回到 regular 并激活，再用 `SettingsLink` 打开。
    @MainActor
    static func prepareForSettings() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func revealMainWindow(openIfNeeded: (() -> Void)? = nil) {
        let restoreDock = NSApp.activationPolicy() != .regular
        if restoreDock {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let present = {
            if let window = mainWindows.first {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                return
            }
            (openIfNeeded ?? openMainWindow)?()
        }

        if restoreDock {
            DispatchQueue.main.async(execute: present)
        } else {
            present()
        }
    }
}
