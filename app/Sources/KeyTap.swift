import AppKit

// Global key handling. A session event tap sees every key press, runs the matching bind and swallows it,
// so bound chords never reach the focused app. Unbound chords pass through untouched.

struct Combo: Hashable {
    var code: UInt16
    var mods: MacMods
}

final class KeyTap {
    static let syntheticMarker: Int64 = 0x4859_5052   // "HYPR": events HyprMac posts itself

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyTable: [String: [Combo: Bind]] = [:]
    private var scrollTable: [String: [MacMods: (up: Bind?, down: Bind?)]] = [:]
    private var swallowedKeyUps = Set<UInt16>()
    private var scrollAccum: Double = 0
    private var lastScrollFire = Date.distantPast
    private(set) var submap = ""

    var onDispatch: ((Bind) -> Void)?
    var onSubmap: ((String) -> Void)?

    var isInstalled: Bool { tap != nil }

    func load(_ binds: [Bind], superIs: String) {
        var keys: [String: [Combo: Bind]] = [:]
        var scrolls: [String: [MacMods: (up: Bind?, down: Bind?)]] = [:]
        for b in binds {
            let mods = b.mods.resolve(superIs: superIs)
            switch b.key {
            case .code(let c):
                keys[b.submap, default: [:]][Combo(code: c, mods: mods)] = b
            case .scrollUp:
                scrolls[b.submap, default: [:]][mods, default: (nil, nil)].up = b
            case .scrollDown:
                scrolls[b.submap, default: [:]][mods, default: (nil, nil)].down = b
            case .mouse:
                break   // bindm is applied to OmniWM's drag settings
            }
        }
        keyTable = keys
        scrollTable = scrolls
        if keyTable[submap] == nil && scrollTable[submap] == nil && !submap.isEmpty { setSubmap("") }
    }

    func setSubmap(_ name: String) {
        submap = name
        onSubmap?(name)
    }

    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: keyTapCallback, userInfo: me) else {
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        Log.write("key tap installed")
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            Log.write("key tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return Unmanaged.passUnretained(event)
        default: break
        }
        if event.getIntegerValueField(.eventSourceUserData) == KeyTap.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let mods = MacMods(flags: event.flags)

        if type == .scrollWheel {
            guard let entry = scrollTable[submap]?[mods] else { return Unmanaged.passUnretained(event) }
            let delta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let lines = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            scrollAccum += delta != 0 ? delta : lines * 10
            // One workspace step per flick: fire past a threshold, then cool down briefly.
            if abs(scrollAccum) >= 20, Date().timeIntervalSince(lastScrollFire) > 0.25 {
                let bind = scrollAccum < 0 ? entry.down : entry.up
                scrollAccum = 0
                lastScrollFire = Date()
                if let b = bind { onDispatch?(b) }
            }
            return nil
        }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            if swallowedKeyUps.remove(code) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        guard let bind = keyTable[submap]?[Combo(code: code, mods: mods)] else {
            return Unmanaged.passUnretained(event)
        }
        swallowedKeyUps.insert(code)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat && !bind.repeats { return nil }
        onDispatch?(bind)
        return nil
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keyTap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    return keyTap.handle(type, event)
}
