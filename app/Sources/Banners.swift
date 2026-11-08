import AppKit
import ApplicationServices

// Notification banners below OmniWM's bar. macOS draws banners inside Notification Center's own window,
// which covers the whole screen, 16 points below the menu bar, or below the top of the screen when the menu
// bar hides itself. OmniWM's bar sits on top of that spot and cut the banners off. HyprMac moves that window
// down over Accessibility so the first banner sits the same 16 points below the bar. Notification Center's
// other windows (desktop widgets) stay put. It makes that window when a banner comes and drops it when the
// last one goes, so HyprMac moves it the moment it appears, and checks every two seconds for the times macOS
// puts it back (its panel closing, screens changing).

enum Banners {
    private static let queue = DispatchQueue(label: "hyprmac.banners")
    private static var timer: DispatchSourceTimer?
    private static let gap: CGFloat = 16

    /// A screen in Accessibility coordinates (top-left origin), with how far OmniWM's bar and the menu bar
    /// reach down from its top.
    struct Screen {
        let name: String
        let frame: CGRect
        let barBottom: CGFloat
        let menuBar: CGFloat
        var key: String { "\(name) \(Int(frame.minX)),\(Int(frame.minY))" }
    }
    /// Notification Center's full-screen window on one screen.
    struct Dialog {
        let element: AXUIElement
        let frame: CGRect
        let screen: Screen
    }
    private static var screens: [Screen] = []
    private static var screensRead = Date.distantPast
    /// How far below the window's top macOS put the first banner, by screen, when last seen standing still.
    private static var bannerTop: [String: CGFloat] = [:]
    private static var lastSeen: [String: CGFloat] = [:]
    private static var moved: [String: CGFloat] = [:]
    private static var observer: AXObserver?      // main thread only
    private static var observedPid: pid_t = 0

    static func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { tick() }
        t.resume()
        timer = t
    }

    /// Re-reads the screens and the bar on the next check.
    static func screensChanged() { queue.async { screensRead = .distantPast } }

    /// Puts Notification Center's window back where macOS keeps it, when HyprMac quits.
    static func restore() {
        queue.sync {
            for d in dialogs() where d.frame.minY != d.screen.frame.minY {
                move(d.element, to: CGPoint(x: d.frame.minX, y: d.screen.frame.minY))
            }
        }
    }

    private static func tick() {
        if Date().timeIntervalSince(screensRead) > 30 { screens = readScreens(); screensRead = Date() }
        if let pid = centerPid() { watch(pid) }
        for d in dialogs() {
            let key = d.screen.key
            let (panelOpen, firstBanner) = look(inside: d.element)
            if panelOpen { continue }
            if let top = firstBanner.map({ $0 - d.frame.minY }) {
                // Learn where macOS puts banners once one stands still (banners slide while they come and go).
                if lastSeen[key] == top, abs((bannerTop[key] ?? .infinity) - top) >= 2 { bannerTop[key] = top }
                lastSeen[key] = top
            }
            let natural = bannerTop[key] ?? d.screen.menuBar + gap
            let shift = max(0, d.screen.barBottom + gap - natural)
            guard abs(d.frame.minY - (d.screen.frame.minY + shift)) > 0.5 else { continue }
            move(d.element, to: CGPoint(x: d.frame.minX, y: d.screen.frame.minY + shift))
            if moved[key] != shift {
                moved[key] = shift
                Log.write("banners: Notification Center's banners on \(d.screen.name) start \(Int(shift)) points lower, below the bar")
            }
        }
    }

    /// Notification Center's full-screen windows (subrole AXSystemDialog), each with the screen it covers.
    /// It may already be moved down, so the screen is matched by left edge and size.
    private static func dialogs() -> [Dialog] {
        guard !screens.isEmpty, let pid = centerPid() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var out: [Dialog] = []
        for w in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where string(w, kAXSubroleAttribute) == "AXSystemDialog" {
            guard let f = frame(w) else { continue }
            let matching = screens.filter { abs($0.frame.minX - f.minX) < 1 && abs($0.frame.width - f.width) < 1 && abs($0.frame.height - f.height) < 1 }
            guard let s = matching.min(by: { abs($0.frame.minY - f.minY) < abs($1.frame.minY - f.minY) }) else { continue }
            out.append(Dialog(element: w, frame: f, screen: s))
        }
        return out
    }

    private static func centerPid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier
    }

    /// Runs a check as soon as Notification Center makes a window. Set up again when it restarts.
    private static func watch(_ pid: pid_t) {
        guard pid != observedPid else { return }
        observedPid = pid
        DispatchQueue.main.async {
            if let old = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes) }
            observer = nil
            var made: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, _ in Banners.windowAppeared() }, &made) == .success, let o = made,
                  AXObserverAddNotification(o, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString, nil) == .success
            else { queue.async { observedPid = 0 }; return }   // try again on the next check
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
            observer = o
        }
    }

    private static func windowAppeared() { queue.async { tick() } }

    /// Whether Notification Center's panel is open in this window, and the top of the list banners sit in.
    /// The list's top stays put; a banner's own frame grows when the pointer shows its close button.
    private static func look(inside window: AXUIElement) -> (panelOpen: Bool, firstBanner: CGFloat?) {
        var budget = 300
        var panelOpen = false
        var top: CGFloat?
        func walk(_ e: AXUIElement, _ depth: Int) {
            budget -= 1
            guard budget > 0, depth < 8, !panelOpen else { return }
            let id = string(e, kAXIdentifierAttribute)
            // Only the open panel has the Edit Widgets button; banners use the same list.
            if id == "widget-editor-button" { panelOpen = true; return }
            if id == "AXNotificationListItems" {
                if let f = frame(e), f.height > 0 { top = f.minY }
                return
            }
            for child in (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        walk(window, 0)
        return (panelOpen, top)
    }

    /// Each screen and OmniWM's bar on it, from `omniwmctl query displays` (bottom-left origin) turned into
    /// Accessibility coordinates.
    private static func readScreens() -> [Screen] {
        let r = Dispatchers.omniwmctl(["query", "displays", "--fields", "name,frame,visible-frame,bar-frames", "--format", "json"], quiet: true)
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displays = ((json["result"] as? [String: Any])?["payload"] as? [String: Any])?["displays"] as? [[String: Any]]
        else { return [] }
        func rect(_ v: Any?) -> CGRect? {
            guard let d = v as? [String: Any], let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let w = d["width"] as? Double, let h = d["height"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        let frames = displays.compactMap { rect($0["frame"]) }
        guard let primaryHeight = frames.first(where: { $0.origin == .zero })?.height else { return [] }
        let menuBarHidden = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
        return displays.compactMap { d in
            guard let f = rect(d["frame"]) else { return nil }
            let visible = rect(d["visibleFrame"]) ?? f
            let bars = ((d["barFrames"] as? [Any]) ?? []).compactMap(rect).filter { $0.maxY >= f.maxY - 1 }
            return Screen(name: d["name"] as? String ?? "a screen",
                          frame: CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height),
                          barBottom: bars.map { f.maxY - $0.minY }.max() ?? 0,
                          menuBar: menuBarHidden ? 0 : f.maxY - visible.maxY)
        }
    }

    private static func move(_ e: AXUIElement, to point: CGPoint) {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, v)
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pv = attribute(e, kAXPositionAttribute), let sv = attribute(e, kAXSizeAttribute),
              AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
}
