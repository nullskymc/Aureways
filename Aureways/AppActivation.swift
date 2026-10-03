import AppKit
import SwiftUI

/// Menu bar status item icon (template image).
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

extension Notification.Name {
    static let aurewaysRevealMainWindow = Notification.Name("ai.aureways.revealMainWindow")
}

enum AppActivation {
    static let mainWindowID = "main"
    @MainActor static var openMainWindow: (() -> Void)?
    @MainActor static var allowsTermination = false
    @MainActor private static var pendingOpenURLs: [URL] = []

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
        pendingOpenURLs.append(contentsOf: urls)
        flushPendingOpens()
    }

    @MainActor
    static func flushPendingOpens() {
        guard let model = AppModel.shared, WebShellBridge.current != nil else { return }
        let urls = pendingOpenURLs
        guard !urls.isEmpty else { return }
        pendingOpenURLs.removeAll()
        revealMainWindow()
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
