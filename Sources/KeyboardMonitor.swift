import Cocoa

final class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onOptionPressed: () -> Void
    private let onShortcutActivate: (_ reverse: Bool) -> Void
    private let onShortcutDeactivate: () -> Void

    private var optionDown = false
    private var tabWasUsed = false

    init(
        onOptionPressed: @escaping () -> Void,
        onShortcutActivate: @escaping (_ reverse: Bool) -> Void,
        onShortcutDeactivate: @escaping () -> Void
    ) {
        self.onOptionPressed = onOptionPressed
        self.onShortcutActivate = onShortcutActivate
        self.onShortcutDeactivate = onShortcutDeactivate
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                  | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[KeyboardMonitor] ❌ Event tap creation failed — missing Accessibility permission.")
            print("[KeyboardMonitor] Go to System Settings → Privacy & Security → Accessibility → add/enable altTab")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[KeyboardMonitor] ✅ Listening for Option+Tab")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit { stop() }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            let nowDown = event.flags.contains(.maskAlternate)
            if nowDown && !optionDown {
                optionDown = true
                tabWasUsed = false
                onOptionPressed()
            } else if !nowDown && optionDown {
                optionDown = false
                if tabWasUsed {
                    onShortcutDeactivate()
                }
            }

        case .keyDown:
            guard optionDown else { break }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 48 {
                tabWasUsed = true
                let shiftHeld = event.flags.contains(.maskShift)
                onShortcutActivate(shiftHeld)
                return nil
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(event: event, type: type)
    }
}
