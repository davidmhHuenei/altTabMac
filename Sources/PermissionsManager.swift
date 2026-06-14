@preconcurrency import ApplicationServices
import Cocoa
import ScreenCaptureKit

final class PermissionsManager: @unchecked Sendable {

    var screenRecordingGranted: Bool {
        get async {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                return true
            } catch {
                return false
            }
        }
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func areRequiredPermissionsGranted() async -> Bool {
        await screenRecordingGranted && accessibilityGranted
    }

    @MainActor
    func requestRequiredPermissions() {
        requestScreenRecording()
        requestAccessibility()
    }

    @MainActor
    private func requestScreenRecording() {
        if #available(macOS 14.0, *) {
            CGRequestScreenCaptureAccess()
        } else {
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "altTab needs Screen Recording permission to show window thumbnails.\n\n"
                + "Open System Settings → Privacy & Security → Screen Recording and enable altTab."
            alert.runModal()
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            )
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as! String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
