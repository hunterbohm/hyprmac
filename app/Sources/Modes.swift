import AppKit
import ApplicationServices

// Hunter's AeroSpace modes, carried over: reading mode, the recording stage, and the prompter.
// Window frames here use Accessibility coordinates (origin at the top left of the main screen).

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// True when the Mac's own screen is the only one connected.
    static func laptopOnly() -> Bool {
        let screens = NSScreen.screens
        return !screens.isEmpty && screens.allSatisfy { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    static func axFrame(_ cocoa: CGRect) -> CGRect {
        CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    /// The screen holding most of a window (Accessibility coordinates), else the main screen.
    static func screen(for axRect: CGRect) -> NSScreen? {
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        return NSScreen.screens.first { axFrame($0.frame).contains(center) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func menuBarInset(_ s: NSScreen) -> CGFloat { max(0, s.frame.maxY - s.visibleFrame.maxY) }

    /// Where tiled windows can go on a screen with no gaps: below the menu bar and OmniWM's workspace bar.
    static func usableFrame(_ s: NSScreen) -> CGRect {
        var r = axFrame(s.visibleFrame)
        let bar = omniReservedTop(s)
        r.origin.y += bar
        r.size.height -= bar
        return r
    }

    /// Height OmniWM's workspace bar keeps free at the top of a screen (0 when it sits inside the menu bar).
    static func omniReservedTop(_ s: NSScreen) -> CGFloat {
        let r = Dispatchers.omniwmctl(["query", "displays", "--fields", "frame,reserved-insets", "--format", "json"], quiet: true)
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        var found: CGFloat?
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let f = d["frame"] as? [String: Any], let insets = d["reservedInsets"] as? [String: Any],
                   let x = f["x"] as? Double, let y = f["y"] as? Double, abs(x - s.frame.minX) < 1, abs(y - s.frame.minY) < 1 {
                    found = CGFloat(insets["top"] as? Double ?? 0)
                }
                d.values.forEach(walk)
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(json)
        return found ?? 0
    }
}

/// The focused window as OmniWM sees it, plus its Accessibility handle for moving and sizing it.
struct FocusedWindow {
    let id: String
    let pid: pid_t
    let floating: Bool

    static func current() -> FocusedWindow? {
        let r = Dispatchers.omniwmctl(["query", "windows", "--focused", "--fields", "id,pid,mode", "--format", "json"])
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var result: FocusedWindow?
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let id = d["id"] as? String, id.hasPrefix("ow_"), let pid = d["pid"] as? Int {
                    result = FocusedWindow(id: id, pid: pid_t(pid), floating: (d["mode"] as? String) == "floating")
                }
                d.values.forEach(walk)
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(json)
        return result
    }

    var element: AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    var frame: CGRect? {
        guard let w = element else { return nil }
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Float the window (if tiled) and place it. OmniWM animates a newly floated window, so wait for that
    /// to settle, then set the frame and set it again if the window drifted.
    func floatAndPlace(_ target: (NSScreen) -> CGRect?) -> Bool {
        if !floating {
            Dispatchers.omniwmctl(["window", "toggle-floating", id])
            usleep(350_000)
        }
        guard let screen = Screens.screen(for: frame ?? .zero), let rect = target(screen) else { return false }
        for _ in 0..<3 {
            guard let w = element else { return false }
            var origin = rect.origin, size = rect.size
            if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
            if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
            if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
            usleep(250_000)
            if let now = frame, abs(now.minX - rect.minX) < 2, abs(now.minY - rect.minY) < 2 { break }
        }
        return true
    }
}

enum Modes {
    static func size(_ arg: String, default d: CGSize) -> CGSize {
        let n = arg.lowercased().split(whereSeparator: { $0 == "x" || $0 == " " || $0 == "," }).compactMap { Double($0) }
        return n.count >= 2 ? CGSize(width: n[0], height: n[1]) : d
    }

    /// The recording stage: a box of `stage` size centered where tiled windows go on the screen.
    static func stageRect(_ stage: CGSize, on screen: NSScreen) -> CGRect? {
        let u = Screens.usableFrame(screen)
        guard stage.width <= u.width, stage.height <= u.height else { return nil }
        return CGRect(x: u.minX + ((u.width - stage.width) / 2).rounded(.down),
                      y: u.minY + ((u.height - stage.height) / 2).rounded(.down),
                      width: stage.width, height: stage.height)
    }

    // MARK: reading mode (⌥⇧F)

    /// Float the window as a centered reading column; press again to put it back in the tiling.
    static func readingMode(_ arg: String) {
        guard let w = FocusedWindow.current() else { return }
        if w.floating {
            Dispatchers.omniwmctl(["window", "toggle-floating", w.id])
            return
        }
        let maxWidth = Double(arg.trimmingCharacters(in: .whitespaces)) ?? 1600
        _ = w.floatAndPlace { screen in
            let u = Screens.usableFrame(screen)
            let width = min(u.width * 0.68, CGFloat(maxWidth)).rounded()
            let height = (u.height * 0.85).rounded()
            return CGRect(x: u.minX + ((u.width - width) / 2).rounded(), y: u.minY + ((u.height - height) / 2).rounded(),
                          width: width, height: height)
        }
    }

    // MARK: record mode (Hyper+R)

    /// OmniWM gap values for the stage, saved while record mode is on: outer top, right, bottom, left.
    static var recordState: String { Paths.stateDir + "/record-mode" }

    static func recordGaps() -> (top: Double, right: Double, bottom: Double, left: Double)? {
        guard let s = try? String(contentsOfFile: recordState, encoding: .utf8) else { return nil }
        let n = s.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        return n.count == 4 ? (n[0], n[1], n[2], n[3]) : nil
    }

    static func recordMode(_ arg: String, config: () -> HyprConfig) {
        if FileManager.default.fileExists(atPath: recordState) {
            try? FileManager.default.removeItem(atPath: recordState)
            OmniSettings.apply(config())
            Dispatchers.notify?("Record mode off")
            return
        }
        let stage = size(arg, default: CGSize(width: 2134, height: 1200))
        let frame = FocusedWindow.current()?.frame
        guard let screen = frame.flatMap({ Screens.screen(for: $0) }) ?? NSScreen.main,
              let rect = stageRect(stage, on: screen) else {
            Dispatchers.notify?("Record mode: a \(Int(stage.width))×\(Int(stage.height)) stage doesn't fit this screen")
            return
        }
        // OmniWM measures the top gap from the screen's top edge, menu bar included.
        let v = Screens.axFrame(screen.visibleFrame)
        let bar = Screens.omniReservedTop(screen)
        let top = Screens.menuBarInset(screen) + (rect.minY - v.minY - bar)
        let gaps = [top, v.maxX - rect.maxX, v.maxY - rect.maxY, rect.minX - v.minX].map { String(format: "%.0f", $0) }
        try? gaps.joined(separator: " ").write(toFile: recordState, atomically: true, encoding: .utf8)
        OmniSettings.apply(config())
        Dispatchers.notify?("Record mode on: \(Int(stage.width))×\(Int(stage.height)) stage")
    }

    // MARK: prompter (Hyper+P)

    static var prompterState: String { Paths.stateDir + "/prompter-window" }

    /// Float the focused window (your Obsidian note) into the margin right of the recording stage;
    /// press again to put that window back in the tiling.
    static func prompter(_ arg: String) {
        if let id = (try? String(contentsOfFile: prompterState, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? FileManager.default.removeItem(atPath: prompterState)
            if !id.isEmpty { Dispatchers.omniwmctl(["window", "toggle-floating", id]) }
            Dispatchers.notify?("Prompter off")
            return
        }
        guard let w = FocusedWindow.current() else { return }
        let stage = size(arg, default: CGSize(width: 2134, height: 1200))
        var roomy = true
        let placed = w.floatAndPlace { screen in
            guard let st = stageRect(stage, on: screen) else { roomy = false; return nil }
            let v = Screens.axFrame(screen.visibleFrame)
            let x = st.maxX + 8, width = v.maxX - 8 - x
            guard width >= 200 else { roomy = false; return nil }
            return CGRect(x: x, y: st.minY, width: width, height: st.height)
        }
        guard placed else {
            if !w.floating { Dispatchers.omniwmctl(["window", "toggle-floating", w.id]) }
            Dispatchers.notify?(roomy ? "Prompter: no window to move" : "Prompter: no room right of the stage on this screen")
            return
        }
        try? w.id.write(toFile: prompterState, atomically: true, encoding: .utf8)
        Dispatchers.notify?("Prompter on")
    }
}
