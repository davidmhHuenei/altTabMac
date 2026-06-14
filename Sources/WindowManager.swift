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
        guard let app = NSRunningApplication(processIdentifier: info.appPID) else { return }
        app.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.focusAXWindow(pid: info.appPID, windowID: info.id, frame: info.frame)
        }
    }

    private static func focusAXWindow(pid: pid_t, windowID: CGWindowID, frame: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard let axWindows = value as? [AXUIElement] else { return }

        for axWindow in axWindows {
            var windowNumberValue: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, "AXWindowNumber" as CFString, &windowNumberValue)
            if let windowNumberValue = windowNumberValue as? NSNumber,
               CGWindowID(windowNumberValue.intValue) == windowID {
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    break
            }

            var pos: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &pos)
            guard let posVal = pos else { continue }
            var point = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &point)

            var sz: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sz)
            guard let szVal = sz else { continue }
            var size = CGSize.zero
            AXValueGetValue(szVal as! AXValue, .cgSize, &size)

            let axFrame = CGRect(origin: point, size: size)
            if axFrame.equalTo(frame) {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                break
            }
        }
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
