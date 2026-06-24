import Cocoa
import SwiftUI
import ApplicationServices

@MainActor
final class HUDController: NSObject {
    private let windowManager: WindowManager
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?
    private let state = HUDState()
    private(set) var isVisible = false
    private var isFetching = false
    private var cachedWindows: [WindowManager.WindowInfo] = []
    private var recentWindowIDs: [CGWindowID] = []

    private var lastAdvance: Date = .distantPast
    private let advanceInterval: TimeInterval = 0.12

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
        super.init()
        seedRecentWindow()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func handleOptionPressed() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            do {
                cachedWindows = try await windowManager.fetchWindows(recentWindowIDs: recentWindowIDs)
                print("[HUDController] Pre-fetched \(cachedWindows.count) windows")
            } catch {
                print("[HUDController] Pre-fetch error: \(error)")
            }
            isFetching = false
        }
    }

    func handleTab(reverse: Bool) {
        if isVisible {
            let now = Date()
            guard now.timeIntervalSince(lastAdvance) >= advanceInterval else { return }
            lastAdvance = now

            let count = state.windowCount
            guard count > 0 else { return }

            if reverse {
                state.selectedIndex = (state.selectedIndex - 1 + count) % count
            } else {
                state.selectedIndex = (state.selectedIndex + 1) % count
            }
            if state.selectedIndex < currentWindowIDs.count {
                let selectedWindowID = currentWindowIDs[state.selectedIndex]
                recordRecentWindow(selectedWindowID)
            }
            return
        }

        if !cachedWindows.isEmpty {
            showWithWindows(cachedWindows)
            return
        }

        guard !isFetching else { return }
        isFetching = true
        Task {
            do {
                let windows = try await windowManager.fetchWindows(recentWindowIDs: recentWindowIDs)
                cachedWindows = windows
                isFetching = false
                guard !windows.isEmpty else {
                    print("[HUDController] No windows to show")
                    return
                }
                await MainActor.run {
                    self.showWithWindows(windows)
                }
            } catch {
                isFetching = false
                print("[HUDController] Fetch error: \(error)")
            }
        }
    }

    private func showWithWindows(_ windows: [WindowManager.WindowInfo]) {
        currentWindowIDs = windows.map(\.id)
        activeWindows = windows
        presentPanel(with: windows)
        isVisible = true
        print("[HUDController] showWithWindows: \(windows.count) windows loaded")
        for (i, w) in windows.enumerated() {
            print("[HUDController]   [\(i)] ID=\(w.id) pid=\(w.appPID) title=\"\(w.title ?? "")\" frame=\(w.frame)")
        }
    }

    func handleOptionRelease() {
        guard isVisible else { return }
        activateAndHide()
    }

    private func activateAndHide() {
        guard isVisible else {
            print("[HUDController] activateAndHide: not visible, abort")
            return
        }

        let idx = state.selectedIndex
        let windows = activeWindows

        print("[HUDController] activateAndHide: idx=\(idx) windows.count=\(windows.count)")
        guard idx < windows.count else {
            print("[HUDController] activateAndHide: idx \(idx) out of bounds, hiding")
            hide()
            return
        }

        let target = windows[idx]
        print("[HUDController] activateAndHide: → idx=\(idx) ID=\(target.id) pid=\(target.appPID) title=\"\(target.title ?? "")\"")
        recordRecentWindow(target.id)
        Task { await windowManager.activateWindow(target) }
        hide()
    }

    private func hide() {
        panel?.close()
        panel = nil
        hostingView = nil
        isVisible = false
        cachedWindows = []
        currentWindowIDs = []
        Task { await windowManager.clearCache() }
    }

    private func presentPanel(with windows: [WindowManager.WindowInfo]) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main!
        let margin: CGFloat = 40
        let maxW = screen.frame.width - margin * 2
        let w: CGFloat = min(maxW, max(1100, screen.frame.width * 0.82))
        let h: CGFloat = min(screen.frame.height - margin * 2, max(420, screen.frame.height * 0.58))

        let hudView = HUDView(windows: windows, windowManager: windowManager, state: state)
        let host = NSHostingView(rootView: hudView)
        host.setFrameSize(NSSize(width: w, height: h))

        panel.contentView = host
        panel.setFrame(NSRect(x: 0, y: 0, width: w, height: h), display: false)

        let sf = screen.frame
        let px = sf.midX - panel.frame.width / 2
        let py = sf.minY + (sf.height - panel.frame.height) / 2
        panel.setFrameOrigin(NSPoint(x: px, y: py))

        self.panel = panel
        self.hostingView = host
        state.selectedIndex = 0
        state.windowCount = windows.count
        lastAdvance = .distantPast

        panel.orderFront(nil)
        print("[HUDController] Panel shown at (\(panel.frame.origin.x), \(panel.frame.origin.y)) size (\(panel.frame.width), \(panel.frame.height))")
    }

    private func seedRecentWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy == .regular {
            recordFocusedWindow(for: frontmost.processIdentifier)
        }
    }

    @objc private func handleApplicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            self?.recordFocusedWindow(for: pid)
        }
    }

    private func recordFocusedWindow(for pid: pid_t) {
        guard let windowID = focusedWindowID(for: pid) else { return }
        recordRecentWindow(windowID)
    }

    private func recordRecentWindow(_ windowID: CGWindowID) {
        recentWindowIDs.removeAll { $0 == windowID }
        recentWindowIDs.insert(windowID, at: 0)
        if recentWindowIDs.count > 50 {
            recentWindowIDs = Array(recentWindowIDs.prefix(50))
        }
    }

    private func focusedWindowID(for pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXFocusedWindow" as CFString, &value) == .success,
              let windowElement = value,
              CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
            return nil
        }

        let axWindow = unsafeBitCast(windowElement, to: AXUIElement.self)

        var numberValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &numberValue) == .success,
              let number = numberValue as? NSNumber else {
            return nil
        }

        return CGWindowID(number.intValue)
    }

    private var currentWindowIDs: [CGWindowID] = []

    /// Stored reference to the windows currently displayed in the HUD.
    /// Used instead of `hostingView.rootView.windows` for reliable access during activation.
    private var activeWindows: [WindowManager.WindowInfo] = []
}
