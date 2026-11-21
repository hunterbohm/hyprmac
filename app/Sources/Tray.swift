import AppKit
import ApplicationServices

// Menu bar apps inside OmniWM's bar, like Waybar's tray. OmniWM's full-width bar covers the macOS menu
// bar, so HyprMac finds every app's menu bar item over Accessibility and hands the list to the bar's
// `tray` widget as the `hyprmac_tray` value; the widget draws each app's icon. Clicking one opens
// hyprmac://tray/<token>/<bundle>/<index>, and HyprMac presses the real item, so its own menu opens.
// macOS 27 draws the whole menu bar in MenuBarAgent, and apps no longer publish `AXExtrasMenuBar`: the
// items are the children of MenuBarAgent's bar windows, each wrapping an element of the app that owns the
// item (see agentItems). Items tucked behind macOS's own overflow arrow stay there and still open when
// pressed. macOS 26 and older still use each app's `AXExtrasMenuBar` (see extrasItems).
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
        "com.apple.TextInputMenuAgent", "com.apple.MenuBarAgent", "com.barut.OmniWM", "com.hunterbohm.hyprmac",
        "com.stonerl.Thaw", "com.jordanbaird.Ice",
    ]
    static let agentBundle = "com.apple.MenuBarAgent"

    // State, touched only on `queue`.
    private static var hidden: [String] = []
    private static var current: [Item] = []
    private static var lastPublished = ""
    private static var omniPid: pid_t = 0
    private static var timer: DispatchSourceTimer?

    /// The app that was active before HyprMac came forward: the last other app macOS deactivated, which
    /// a tray click hands activation back to. Main thread only.
    private static var lastActive: NSRunningApplication?
    private static let deactivations = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
    ) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        lastActive = app
    }

    /// Start watching menu bar items. `hide` lists apps (names or bundle IDs) to leave out. Main thread.
    static func start(hide: [String]) {
        _ = deactivations
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

    /// macOS 27 draws the whole menu bar in MenuBarAgent; older systems leave each app's items to the app.
    static let drawnByAgent = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    static func scan() -> [Item] {
        let items = drawnByAgent ? shownBar()?.items ?? [] : extrasItems()
        // Same order as in the macOS menu bar: left to right.
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func shown(_ app: NSRunningApplication) -> (bundle: String, name: String)? {
        guard let bundle = app.bundleIdentifier, !skipBundles.contains(bundle) else { return nil }
        let name = app.localizedName ?? bundle
        if hidden.contains(bundle.lowercased()) || hidden.contains(name.lowercased()) { return nil }
        return (bundle, name)
    }

    /// One of MenuBarAgent's menu bars; it draws one per screen, each with every item. Only the active
    /// screen's bar holds the apps' real items: the others hold stand-ins, each the whole app's element,
    /// which can't be pressed.
    private struct AgentBar {
        let frame: CGRect       // Accessibility coordinates
        let items: [Item]
        let live: Bool
    }

    private static func agentBars() -> [AgentBar] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundle).first?.processIdentifier
        else { return [] }
        let app = AXUIElementCreateApplication(agent)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // The agent also has an empty shield window over each bar.
        return (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).compactMap { w in
            let (items, live) = agentItems(agent, bar: w)
            return items.isEmpty ? nil : AgentBar(frame: frame(w), items: items, live: live)
        }
    }

    /// The bar to list and press: the live one, else the main screen's.
    private static func shownBar() -> AgentBar? {
        let bars = agentBars()
        let main = CGDisplayBounds(CGMainDisplayID())
        return bars.first { $0.live } ?? bars.first { main.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) } ?? bars.first
    }

    /// The items in one of MenuBarAgent's bars, and whether they are the real ones. Each child wraps the
    /// app's own element a level or two down; children that are the agent's all the way down are Apple's
    /// items (Wi-Fi, battery, clock and so on, which the bar has widgets for) and the overflow arrow. A live
    /// activity pill is the agent's too, and shows as the app its label names. Frames are the children's,
    /// which stand-ins have too.
    private static func agentItems(_ agent: pid_t, bar: AXUIElement) -> (items: [Item], live: Bool) {
        var found: [(bundle: String, name: String, title: String?, frame: CGRect, element: AXUIElement, activity: Bool)] = []
        var live = false
        for child in children(bar) {
            if (attr(child, kAXIdentifierAttribute) as? String)?.hasPrefix("live-activity-pill") == true {
                guard let label = attr(child, kAXDescriptionAttribute) as? String,
                      let app = activityApp(label), let (bundle, name) = shown(app) else { continue }
                AXUIElementSetMessagingTimeout(child, 0.25)
                found.append((bundle, name, "live activity", frame(child), child, true))
                continue
            }
            var el = child
            for _ in 0..<4 where pid(el) == agent {
                guard let next = children(el).first else { break }
                el = next
            }
            let owner = pid(el)
            guard owner != agent, let app = NSRunningApplication(processIdentifier: owner), let (bundle, name) = shown(app) else { continue }
            AXUIElementSetMessagingTimeout(el, 0.25)
            let standIn = attr(el, kAXRoleAttribute) as? String == kAXApplicationRole
            if !standIn { live = true }
            found.append((bundle, name, standIn ? nil : title(el), frame(child), el, false))
        }
        // An app's items are numbered left to right, the same way on every screen's bar.
        var counts: [String: Int] = [:]
        let items = found.sorted { $0.frame.minX < $1.frame.minX }.map { f -> Item in
            let i = counts[f.bundle, default: 0]
            counts[f.bundle] = i + 1
            return Item(id: f.activity ? "\(f.bundle)/activity" : "\(f.bundle)/\(i)", bundle: f.bundle, name: f.name,
                        title: f.title ?? f.name, frame: f.frame, element: f.element)
        }
        return (items, live)
    }

    /// The app a live activity's label names. The label carries no bundle ID, and it can leave out part of
    /// the app's name ("T3 Code" for "T3 Code (Nightly)"), so an app whose name adds to it counts when only one does.
    private static func activityApp(_ label: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let exact = apps.first(where: { $0.localizedName == label }) { return exact }
        let longer = apps.filter { $0.localizedName?.hasPrefix(label + " ") == true }
        return longer.count == 1 ? longer[0] : nil
    }

    /// macOS 26 and older: each app's own `AXExtrasMenuBar`.
    private static func extrasItems() -> [Item] {
        var out: [Item] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let (bundle, name) = shown(app) else { continue }
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.25)
            guard let bar = attr(el, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for (i, k) in kids.enumerated() {
                let f = frame(k)
                guard f.width > 1, f.height > 1, f.width < 400 else { continue }   // skip spacers such as a hider's separator
                out.append(Item(id: "\(bundle)/\(i)", bundle: bundle, name: name, title: title(k) ?? name, frame: f, element: k))
            }
        }
        return out
    }

    /// The item's own label: what VoiceOver reads for it.
    private static func title(_ e: AXUIElement) -> String? {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].lazy.compactMap { attr(e, $0) as? String }.first { !$0.isEmpty }
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
            guard var item = current.first(where: { $0.id == id }) else { Log.write("tray: no menu bar item \(id)"); return }
            var note = ""
            if drawnByAgent {
                // The list can be 3 s old, and the real items move to whichever screen's bar becomes active.
                var bar = shownBar()
                if let s = screen, s.all.count > 1, !(bar.map { $0.live && isOn(s, $0.frame) } ?? false) {
                    var here: AgentBar?
                    note = moveMenuBar(to: s) {
                        here = agentBars().first { $0.live && isOn(s, $0.frame) }
                        return here != nil
                    }
                    bar = here ?? shownBar()
                }
                if let fresh = bar?.items.first(where: { $0.id == id }) { item = fresh }
            } else if let s = screen, s.all.count > 1, !isOn(s, frame(item.element)) {
                note = moveMenuBar(to: s) { isOn(s, frame(item.element)) }
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
        // Opening the link brings HyprMac forward. On macOS 27 a menu that opens then closes again as soon as
        // macOS hands activation back to the app you were in, so HyprMac hands it back first.
        afterSteppingBack { press(parts[1], from: screen) }
    }

    /// Gives activation back to the app that had it and runs body on the main thread once HyprMac is no
    /// longer active, waiting at most half a second. `deactivate()` doesn't hand it back on macOS 27.
    private static func afterSteppingBack(_ body: @escaping () -> Void) {
        guard drawnByAgent, NSApp.isActive else { body(); return }
        var observer: NSObjectProtocol?
        var done = false
        let finish = {
            guard !done else { return }
            done = true
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            body()
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { _ in finish() }
        if let app = lastActive, !app.isTerminated {
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: finish)
    }

    /// Whether a menu bar item, or a whole bar, is in this screen's menu bar: the screen beside or under which it sits.
    /// A hidden menu bar puts its items just above the top of the screen.
    private static func isOn(_ s: ClickScreen, _ f: CGRect) -> Bool {
        let holders = s.all.filter { f.midX >= $0.minX && f.midX < $0.maxX }
        let nearest = holders.min { abs($0.minY - f.midY) < abs($1.minY - f.midY) }
        return nearest == s.frame
    }

    /// Make the clicked screen's menu bar the active one, the way a click on that screen does: focus its
    /// window through OmniWM, or click its bare desktop when it has none. Returns a note for the log.
    private static func moveMenuBar(to s: ClickScreen, until arrived: () -> Bool) -> String {
        func moved() -> Bool {
            for _ in 0..<20 {   // about a second
                if arrived() { return true }
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

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// The process an element belongs to; 0 when it is gone.
    private static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        return AXUIElementGetPid(e, &p) == .success ? p : 0
    }

    private static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v = attr(e, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
        if let v = attr(e, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
}
