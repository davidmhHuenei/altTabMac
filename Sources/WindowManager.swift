@preconcurrency import ScreenCaptureKit
import Cocoa

actor WindowManager {
    struct WindowInfo: Identifiable, Sendable {
        let id: CGWindowID
        let appName: String
        let appPID: pid_t
        let title: String?
        let frame: CGRect
    }

    private var thumbnailCache: [CGWindowID: (NSImage, CGImage)] = [:]
    private var windowMap: [CGWindowID: SCWindow] = [:]

    func fetchWindows(recentWindowIDs: [CGWindowID] = []) async throws -> [WindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let regularApps = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
        )

        let windowLayers = Self.windowLayers()
        let onScreenIDs = Self.onScreenWindowIDs()

        let filtered = content.windows.filter { window in
            guard let scApp = window.owningApplication else { return false }
            guard regularApps.contains(scApp.processID) else { return false }
            guard windowLayers[window.windowID] == 0 else { return false }
            guard onScreenIDs.contains(window.windowID) else {
                print("[WindowManager] Excluded off-screen: \(window.title ?? "?") [\(window.windowID)]")
                return false
            }
            let f = window.frame
            return f != .zero && f.width >= 100 && f.height >= 50
        }

        print("[WindowManager] \(content.windows.count) raw → \(filtered.count) after filter (onScreen: \(onScreenIDs.count))")

        let recentRanks = Dictionary(uniqueKeysWithValues: recentWindowIDs.enumerated().map { ($1, $0) })

        let sorted = filtered.sorted { lhs, rhs in
            let lRank = recentRanks[lhs.windowID] ?? Int.max
            let rRank = recentRanks[rhs.windowID] ?? Int.max

            if lRank != rRank {
                return lRank < rRank
            }

            if lhs.frame.origin.y != rhs.frame.origin.y {
                return lhs.frame.origin.y > rhs.frame.origin.y
            }

            return lhs.frame.origin.x < rhs.frame.origin.x
        }

        thumbnailCache.removeAll()
        windowMap.removeAll()

        var result: [WindowInfo] = []
        for window in sorted {
            windowMap[window.windowID] = window
            result.append(WindowInfo(
                id: window.windowID,
                appName: window.owningApplication?.applicationName ?? "Unknown",
                appPID: window.owningApplication?.processID ?? 0,
                title: window.title,
                frame: window.frame
            ))
        }
        return result
    }

    func captureThumbnail(for info: WindowInfo, targetSize: CGSize) async -> NSImage? {
        if let cached = thumbnailCache[info.id] {
            return cached.0
        }

        if let nsImage = try? await captureWithSCK(windowID: info.id, targetSize: targetSize) {
            if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                nsImage.size = CGSize(width: cgImage.width, height: cgImage.height)
                thumbnailCache[info.id] = (nsImage, cgImage)
            }
            return nsImage
        }

        if let nsImage = captureWithCG(windowID: info.id, targetSize: targetSize) {
            if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                nsImage.size = CGSize(width: cgImage.width, height: cgImage.height)
                thumbnailCache[info.id] = (nsImage, cgImage)
            }
            return nsImage
        }

        print("[WindowManager] ❌ All capture methods failed for window \(info.id) \"\(info.appName)\"")
        return nil
    }

    private func captureWithSCK(windowID: CGWindowID, targetSize: CGSize) async throws -> NSImage? {
        guard let window = windowMap[windowID] else { return nil }

        do {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale: CGFloat = 2.0
            config.width = Int(targetSize.width * scale)
            config.height = Int(targetSize.height * scale)
            config.showsCursor = false
            config.backgroundColor = .clear

            if #available(macOS 14.0, *) {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                print("[WindowManager] ✅ SCK capture succeeded for window \(windowID)")
                return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
            }

            return try await captureViaStream(filter: filter, config: config, targetSize: targetSize)
        } catch {
            print("[WindowManager] ⚠️ SCK failed for window \(windowID): \(error.localizedDescription)")
            return nil
        }
    }

    private func captureViaStream(
        filter: SCContentFilter,
        config: SCStreamConfiguration,
        targetSize: CGSize
    ) async throws -> NSImage? {
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        return try await withCheckedThrowingContinuation { continuation in
            let output = StreamFrameReceiver(targetSize: targetSize) { result in
                continuation.resume(with: result)
            }
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                stream.startCapture()
            } catch {
                try? stream.removeStreamOutput(output, type: .screen)
                continuation.resume(throwing: error)
            }
        }
    }

    private func captureWithCG(windowID: CGWindowID, targetSize: CGSize) -> NSImage? {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            print("[WindowManager] ⚠️ CGWindowListCreateImage returned nil for window \(windowID)")
            return nil
        }
        print("[WindowManager] ✅ CG capture succeeded for window \(windowID)")
        return NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    func activateWindow(_ info: WindowInfo) {
        print("[WindowManager] activateWindow: \"\(info.appName)\" windowID=\(info.id) title=\"\(info.title ?? "")\"")

        // AXUIElement APIs and app activation must run on the main thread.
        // Since WindowManager is an actor, we dispatch to main explicitly.
        let pid = info.appPID
        let windowID = info.id
        let frame = info.frame
        let title = info.title
        let appName = info.appName

        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                print("[WindowManager] ❌ No NSRunningApplication for PID \(pid)")
                return
            }

            print("[WindowManager]   frame=\(frame)")

            // Step 1: Raise the target window via AX BEFORE activating the app.
            // This ensures the target window is on top within the app's Z-order,
            // so the subsequent app.activate() brings the right window to front.
            Self.raiseAXWindow(pid: pid, windowID: windowID, frame: frame, title: title, appName: appName)

            // Step 2: Activate the app (brings it to front)
            app.activate(options: [.activateIgnoringOtherApps])

            // Step 3: Retry raising after activation (in case the app reordered windows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.raiseAXWindow(pid: pid, windowID: windowID, frame: frame, title: title, appName: appName)
            }
        }
    }

    /// Attempts to raise and focus a specific AX window using multiple matching strategies.
    /// - Tries AXWindowNumber first (exact match).
    /// - Falls back to frame comparison with tolerance (handles Electron/VS Code differences).
    /// - Falls back to title comparison (partial match).
    /// - Falls back to AppleScript for problematic apps (Electron/VS Code).
    private static func raiseAXWindow(pid: pid_t, windowID: CGWindowID, frame: CGRect, title: String?, appName: String) {
        let appElement = AXUIElementCreateApplication(pid)

        // ── Debug: dump all AX windows ──
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard windowsResult == .success, let axWindows = windowsValue as? [AXUIElement] else {
            print("[WindowManager] ⚠️ raiseAXWindow: No AX windows for pid \(pid) (error=\(windowsResult.rawValue))")

            // Fallback: try AppleScript for apps where AX doesn't list windows
            Self.activateViaAppleScript(appName: appName, title: title)
            return
        }

        print("[WindowManager] raiseAXWindow: target ID=\(windowID) AX has \(axWindows.count) windows")

        for (i, axWindow) in axWindows.enumerated() {
            // ── Strategy 1: Match by AXWindowNumber (exact) ──
            var windowNumberValue: CFTypeRef?
            let numResult = AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &windowNumberValue)

            if numResult == .success, let windowNumberValue = windowNumberValue as? NSNumber {
                let axWindowID = CGWindowID(windowNumberValue.intValue)
                if axWindowID == windowID {
                    print("[WindowManager] ✅ Window[\(i)] matched by ID: \(axWindowID)")
                    Self.raiseAndFocus(axWindow)
                    return
                } else {
                    // AXWindowNumber available but doesn't match → skip
                    continue
                }
            }

            // ── Debug: log AX window info ──
            var debugTitle: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &debugTitle)
            let axTitle = debugTitle as? String ?? "<nil>"

            // ── Strategy 2: Match by title (partial match) ──
            // This is more reliable for Electron apps where frame may differ
            if let targetTitle = title, !targetTitle.isEmpty {
                if let axTitleStr = debugTitle as? String, !axTitleStr.isEmpty {
                    // Check if titles match (case-insensitive)
                    if axTitleStr.caseInsensitiveCompare(targetTitle) == .orderedSame ||
                       targetTitle.caseInsensitiveCompare(axTitleStr) == .orderedSame {
                        print("[WindowManager] ✅ Window[\(i)] matched by title: \"\(axTitleStr)\"")
                        Self.raiseAndFocus(axWindow)
                        return
                    }

                    // For Electron apps, check if the titles share a common substring
                    // (e.g., "project — Visual Studio Code" contains the project name)
                    if axTitleStr.contains("Visual Studio Code") && targetTitle.contains("Visual Studio Code") {
                        print("[WindowManager]   Window[\(i)] title=\"\(axTitleStr)\" is also VS Code, trying frame match...")
                        // fall through to frame matching below
                    } else {
                        print("[WindowManager]   Window[\(i)] title=\"\(axTitleStr)\" ≠ \"\(targetTitle)\"")
                        continue
                    }
                }
            }

            // ── Strategy 3: Match by frame (with tolerance) ──
            var pos: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &pos) == .success,
                  let posVal = pos else { print("[WindowManager]   Window[\(i)]: no position"); continue }
            var point = CGPoint.zero
            guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point) else { continue }

            var sz: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sz) == .success,
                  let szVal = sz else { print("[WindowManager]   Window[\(i)]: no size"); continue }
            var size = CGSize.zero
            guard AXValueGetValue(szVal as! AXValue, .cgSize, &size) else { continue }

            let axFrame = CGRect(origin: point, size: size)

            let tolerance: CGFloat = 20.0
            let frameMatch = abs(axFrame.origin.x - frame.origin.x) < tolerance
                          && abs(axFrame.origin.y - frame.origin.y) < tolerance
                          && abs(axFrame.width - frame.width) < tolerance
                          && abs(axFrame.height - frame.height) < tolerance

            if frameMatch {
                print("[WindowManager] ✅ Window[\(i)] matched by frame (tol=\(tolerance)): ax=\(axFrame)")
                Self.raiseAndFocus(axWindow)
                return
            }

            print("[WindowManager]   Window[\(i)]: title=\"\(axTitle)\" frame=\(axFrame) → no match")
        }

        print("[WindowManager] ⚠️ AX matching failed for ID=\(windowID), trying AppleScript fallback...")
        Self.activateViaAppleScript(appName: appName, title: title)
    }

    /// Fallback: use AppleScript to focus a window by title.
    /// Works reliably for apps that don't properly expose AX attributes (Electron, etc.)
    private static func activateViaAppleScript(appName: String, title: String?) {
        guard let title, !title.isEmpty else {
            print("[WindowManager] ⚠️ activateViaAppleScript: no title provided")
            return
        }

        // Find the app by name to get its bundle identifier
        let bundleID = NSWorkspace.shared.runningApplications
            .first(where: { $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame || $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame })?
            .bundleIdentifier

        guard let bundleID, !bundleID.isEmpty else {
            print("[WindowManager] ⚠️ activateViaAppleScript: no bundle ID found for \"\(appName)\"")
            // Fallback: try using the app name directly
            Self.runAppleScript(appName: appName, title: title)
            return
        }

        print("[WindowManager] activateViaAppleScript: bundleID=\(bundleID) title=\"\(title)\"")
        Self.runAppleScript(bundleID: bundleID, title: title)
    }

    private static func runAppleScript(bundleID: String, title: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "\(bundleID)"
            activate
            set targetWindow to first window whose title contains "\(escapedTitle)"
            if targetWindow is not missing value then
                set index of targetWindow to 1
            end if
        end tell
        """
        Self.executeAppleScript(script, title: title)
    }

    private static func runAppleScript(appName: String, title: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "\(escapedAppName)"
            activate
            set targetWindow to first window whose title contains "\(escapedTitle)"
            if targetWindow is not missing value then
                set index of targetWindow to 1
            end if
        end tell
        """
        Self.executeAppleScript(script, title: title)
    }

    private static func executeAppleScript(_ script: String, title: String) {
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let error {
                print("[WindowManager] ⚠️ AppleScript error: \(error)")
            } else if let resultStr = result.stringValue {
                print("[WindowManager] ✅ AppleScript result: \(resultStr)")
            } else {
                print("[WindowManager] ✅ AppleScript executed for \"\(title)\"")
            }
        } else {
            print("[WindowManager] ⚠️ AppleScript compilation failed")
        }
    }

    private static func raiseAndFocus(_ axWindow: AXUIElement) {
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    func clearCache() {
        thumbnailCache.removeAll()
        windowMap.removeAll()
    }

    private static func windowLayers() -> [CGWindowID: Int32] {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: Int32] = [:]
        for dict in info {
            let id = dict[kCGWindowNumber as String] as? CGWindowID ?? 0
            let layer = dict[kCGWindowLayer as String] as? Int32 ?? 0
            result[id] = layer
        }
        return result
    }

    private static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result = Set<CGWindowID>()
        for dict in info {
            if let id = dict[kCGWindowNumber as String] as? CGWindowID {
                result.insert(id)
            }
        }
        return result
    }
}

private final class StreamFrameReceiver: NSObject, SCStreamOutput {
    private let targetSize: CGSize
    private let completion: (Result<NSImage?, Error>) -> Void
    private var didDeliver = false

    init(targetSize: CGSize, completion: @escaping (Result<NSImage?, Error>) -> Void) {
        self.targetSize = targetSize
        self.completion = completion
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !didDeliver, type == .screen,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        didDeliver = true
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            completion(.failure(NSError(domain: "WindowManager", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to convert CIImage to CGImage"])))
            return
        }
        completion(.success(NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))))
    }
}
