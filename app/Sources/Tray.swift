import AppKit
import ApplicationServices

// Menu bar apps inside OmniWM's bar, like Waybar's tray. OmniWM's full-width bar covers the macOS menu
// bar, so HyprMac finds every app's menu bar item over Accessibility and hands the list to the bar's
// `tray` widget as the `hyprmac_tray` value; the widget draws each app's icon. Clicking one opens
// hyprmac://tray/<token>/<bundle>/<index>, and HyprMac presses the real item, so its own menu opens.
// Any app or web page can open a hyprmac:// link, so a click counts only with this run's random token,
// which only the bar receives, and only for an item the bar was shown.
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
    }

    // MARK: clicks

    /// Open a menu bar item's menu, as clicking it in the macOS menu bar would.
    static func press(_ id: String) {
        queue.async {
            guard let item = current.first(where: { $0.id == id }) else { Log.write("tray: no menu bar item \(id)"); return }
            let r = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            Log.write("tray: open \(item.name) (\(item.title))\(r == .success ? "" : " failed: \(r.rawValue)")")
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
        press(parts[1])
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
