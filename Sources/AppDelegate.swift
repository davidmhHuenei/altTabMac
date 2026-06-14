import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowManager = WindowManager()
    private let permissionsManager = PermissionsManager()
    private var keyboardMonitor: KeyboardMonitor?
    private var hudController: HUDController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        addStatusItem()

        Task {
            let granted = await permissionsManager.areRequiredPermissionsGranted()
            if granted {
                start()
            } else {
                print("[AppDelegate] Permissions missing — requesting...")
                permissionsManager.requestRequiredPermissions()
                pollPermissionsIndefinitely()
            }
        }
    }

    private func addStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "⇥"
        statusItem?.button?.toolTip = "altTab — waiting for Alt+Tab"
    }

    private func pollPermissionsIndefinitely() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await permissionsManager.areRequiredPermissionsGranted() {
                    print("[AppDelegate] Permissions granted — starting")
                    start()
                    statusItem?.button?.title = "⇥"
                    return
                }
            }
        }
    }

    private func start() {
        hudController = HUDController(windowManager: windowManager)

        keyboardMonitor = KeyboardMonitor(
            onOptionPressed: { [weak self] in
                self?.hudController?.handleOptionPressed()
            },
            onShortcutActivate: { [weak self] reverse in
                self?.hudController?.handleTab(reverse: reverse)
            },
            onShortcutDeactivate: { [weak self] in
                self?.hudController?.handleOptionRelease()
            }
        )

        keyboardMonitor?.start()
    }
}
