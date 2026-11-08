import AppKit
import ApplicationServices

// Menu bar apps inside OmniWM's bar, like Waybar's tray. OmniWM's full-width bar covers the macOS menu
// bar, so HyprMac finds every app's menu bar item over Accessibility and hands the list to the bar's
// `tray` widget as the `hyprmac_tray` value; the widget draws each app's icon. Clicking one opens
// hyprmac://tray/<token>/<bundle>/<index>, and HyprMac presses the real item, so its own menu opens.
// Any app or web page can open a hyprmac:// link, so a click counts only with this run's random token,
// which only the bar receives, and only for an item the bar was shown.
// macOS keeps the real items only in the active screen's menu bar and opens their menus there, so a click on
// another screen's bar first makes that screen active (see press).
//
// The tray shows app icons rather than pictures of the menu bar items: the hidden menu bar's items can't
// be captured (ScreenCaptureKit fails on them), and capturing would also bring macOS screen-recording prompts.

enum Tray {
    struct Item {
        let id: String          // "<bundle>/<index>"
        let bundle: String
        let name: String
        let title: String
        let frame: CGRect       // Accessibility coordinates (top-left origin)
        let element: AXUIElement
    }

    static let queue = DispatchQueue(label: "hyprmac.tray")
    static let token = UUID().uuidString

    /// Items the bar already has its own widget for, or that belong to the tiling setup itself.
    static let skipBundles: Set<String> = [
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.Siri",
        "com.apple.TextInputMenuAgent", "com.barut.OmniWM", "com.hunterbohm.hyprmac",
        "com.stonerl.Thaw", "com.jordanbaird.Ice",
    ]

    // State, touched only on `queue`.
    private static var hidden: [String] = []
    private static var current: [Item] = []
    private static var lastPublished = ""
    private static var omniPid: pid_t = 0
    private static var timer: DispatchSourceTimer?

    /// Start watching menu bar items. `hide` lists apps (names or bundle IDs) to leave out.
    static func start(hide: [String]) {
        queue.async {
            hidden = hide.map { $0.lowercased() }
            lastPublished = ""
            guard timer == nil else { refresh(); return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 3.0)
            t.setEventHandler { refresh() }
            t.resume()
            timer = t
        }
    }

    static func scan() -> [Item] {
        var out: [Item] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, !skipBundles.contains(bundle) else { continue }
            let name = app.localizedName ?? bundle
            if hidden.contains(bundle.lowercased()) || hidden.contains(name.lowercased()) { continue }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.25)
            guard let bar = attr(el, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for (i, k) in kids.enumerated() {
                let f = frame(k)
                guard f.width > 1, f.height > 1, f.width < 400 else { continue }   // skip spacers such as a hider's separator
                let title = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].lazy
                    .compactMap { attr(k, $0) as? String }.first { !$0.isEmpty } ?? name
                out.append(Item(id: "\(bundle)/\(i)", bundle: bundle, name: name, title: title, frame: f, element: k))
            }
        }
        // Same order as in the macOS menu bar: left to right.
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func refresh() {
        current = scan()
        // OmniWM forgets what it was sent when it restarts (its setup guide restarts it), so send the list again.
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.barut.OmniWM").first?.processIdentifier ?? 0
        if pid != 0 && pid != omniPid {
            if omniPid != 0 { Log.write("tray: OmniWM restarted; sending the menu bar apps again") }
            omniPid = pid
            lastPublished = ""
        }
        publish()
    }

    /// JSON for the bar: id, app bundle (for its icon), app name, the item's own label and its click link.
    private static func publish() {
        let list: [[String: Any]] = current.map {
            ["id": $0.id, "bundle": $0.bundle, "name": $0.name, "title": $0.title, "url": "hyprmac://tray/\(token)/\($0.id)"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8), json != lastPublished else { return }
        if Dispatchers.omniwmctl(["shell", "set", "hyprmac_tray", json], quiet: true).ok { lastPublished = json }
        // The notifications panel's Clear All and × open this link (see Notifications).
        Dispatchers.omniwmctl(["shell", "set", "hyprmac_notifications", Notifications.link], quiet: true)
    }

    // MARK: clicks

    /// The screen a tray click came from, read on the main thread. Frames use Accessibility coordinates.
    struct ClickScreen {
        let name: String
        let uuid: String?
        let frame: CGRect
        let desktop: CGRect     // below the menu bar, above the Dock
        let all: [CGRect]       // every screen, to tell which one a menu bar item sits on
    }

    /// Open a menu bar item's menu, as clicking it in the macOS menu bar would. With more than one screen,
    /// macOS keeps the real items on the screen whose menu bar is active and opens menus there, so when the
    /// click came from another screen's bar, that screen's menu bar is made active first.
    static func press(_ id: String, from screen: ClickScreen? = nil) {
        queue.async {
            guard let item = current.first(where: { $0.id == id }) else { Log.write("tray: no menu bar item \(id)"); return }
            var note = ""
            if let s = screen, s.all.count > 1, !isOn(s, frame(item.element)) {
                note = moveMenuBar(to: s, item: item.element)
            }
            let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            // An app answers "cannot complete" when its menu opened and holds it until the menu closes.
            let ok = r == .success || r == .cannotComplete
            Log.write("tray: open \(item.name) (\(item.title))\(note)\(ok ? "" : " failed: \(r.rawValue)")")
        }
    }

    /// hyprmac://tray/<token>/<bundle>/<index>
    static func handle(_ url: URL) {
        guard url.scheme == "hyprmac", url.host == "tray" else { return }
        let parts = url.path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == token else {
            Log.write("tray: ignored a hyprmac:// link that didn't come from the bar")
            return
        }
        // The click just happened, so the pointer is still on the bar that was clicked.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }.map {
            ClickScreen(name: $0.localizedName, uuid: Screens.uuid($0), frame: Screens.axFrame($0.frame),
                        desktop: Screens.axFrame($0.visibleFrame), all: NSScreen.screens.map { Screens.axFrame($0.frame) })
        }
        press(parts[1], from: screen)
    }

    /// Whether a menu bar item is in this screen's menu bar: the screen beside or under which it sits.
    /// A hidden menu bar puts its items just above the top of the screen.
    private static func isOn(_ s: ClickScreen, _ f: CGRect) -> Bool {
        let holders = s.all.filter { f.midX >= $0.minX && f.midX < $0.maxX }
        let nearest = holders.min { abs($0.minY - f.midY) < abs($1.minY - f.midY) }
        return nearest == s.frame
    }

    /// Make the clicked screen's menu bar the active one, the way a click on that screen does: focus its
    /// window through OmniWM, or click its bare desktop when it has none. Returns a note for the log.
    private static func moveMenuBar(to s: ClickScreen, item: AXUIElement) -> String {
        func moved() -> Bool {
            for _ in 0..<20 {   // about a second
                if isOn(s, frame(item)) { return true }
                usleep(50_000)
            }
            return false
        }
        if let window = focusedWindow(on: s), Dispatchers.omniwmctl(["window", "focus", window], quiet: true).ok, moved() {
            return "; focused \(s.name) first"
        }
        // With "Click wallpaper to reveal desktop" set to Always, that click would push every window aside.
        let revealsDesktop = UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "EnableStandardClickToShowDesktop") ?? false
        if !revealsDesktop, let spot = bareDesktop(on: s) {
            click(spot)
            if moved() { return "; clicked \(s.name)'s desktop first" }
        }
        return "; its menu bar stayed on another screen"
    }

    /// The window OmniWM would focus on this screen, when its workspace there has any.
    private static func focusedWindow(on s: ClickScreen) -> String? {
        guard let uuid = s.uuid,
              let displays = queryPayload(["query", "displays", "--fields", "uuid,active-workspace"])?["displays"] as? [[String: Any]],
              let display = displays.first(where: { ($0["uuid"] as? String)?.uppercased() == uuid.uppercased() }),
              let workspaceId = (display["activeWorkspace"] as? [String: Any])?["id"] as? String,
              let workspaces = queryPayload(["query", "workspaces", "--visible", "--fields", "id,focused-window-id,window-counts"])?["workspaces"] as? [[String: Any]],
              let workspace = workspaces.first(where: { $0["id"] as? String == workspaceId }),
              ((workspace["counts"] as? [String: Any])?["total"] as? Int ?? 0) > 0 else { return nil }
        // A workspace remembers no focused window until one was focused there, as after a window moved in.
        if let id = workspace["focusedWindowId"] as? String { return id }
        let windows = queryPayload(["query", "windows", "--workspace", workspaceId, "--sort", "mru", "--fields", "id"])?["windows"] as? [[String: Any]]
        return windows?.first?["id"] as? String
    }

    private static func queryPayload(_ args: [String]) -> [String: Any]? {
        let r = Dispatchers.omniwmctl(args + ["--format", "json"], quiet: true)
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["result"] as? [String: Any])?["payload"] as? [String: Any]
    }

    /// A spot on the screen's desktop that no window or desktop widget covers. Windows that cover the
    /// whole screen are overlays that let clicks through (Notification Center's, for one), and windows
    /// above layer 19 are the Dock, menu bar and OmniWM's bar, which the spots stay clear of.
    private static func bareDesktop(on s: ClickScreen) -> CGPoint? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let covers: [CGRect] = list.compactMap { w in
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > Int(CGWindowLevelForKey(.desktopIconWindow)), layer < 20,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.intersects(s.frame) else { return nil }
            return r.insetBy(dx: -1, dy: -1).contains(s.frame) ? nil : r
        }
        let area = s.desktop.insetBy(dx: 60, dy: 60)
        guard area.width > 0, area.height > 0 else { return nil }
        for fy in [0.5, 0.25, 0.75, 0.1, 0.9] {
            for fx in [0.5, 0.25, 0.75, 0.1, 0.9] {
                let p = CGPoint(x: area.minX + area.width * fx, y: area.minY + area.height * fy)
                if !covers.contains(where: { $0.contains(p) }) { return p }
            }
        }
        return nil
    }

    /// One left click at p (Accessibility coordinates); the pointer goes back where it was.
    private static func click(_ p: CGPoint) {
        let back = CGEvent(source: nil)?.location ?? p
        let src = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        CGWarpMouseCursorPosition(back)
    }

    // MARK: Accessibility helpers

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
}
