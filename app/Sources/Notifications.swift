import AppKit
import ApplicationServices

// Clearing notifications from OmniWM's bar. OmniWM's notifications panel clears them by driving Notification
// Center over Accessibility, but it looks for the menu bar clock in com.apple.MenuBarAgent, which macOS 26
// doesn't have (Control Center holds the clock there), so its Clear All and × fail with "Notification Center
// is unavailable". HyprMac does the same steps with whichever process holds the clock. The installer points
// those two buttons at hyprmac://notifications/<token>/dismiss-all and .../dismiss/<notification id>; the
// token is the tray's, which only the bar receives.

enum Notifications {
    static let queue = DispatchQueue(label: "hyprmac.notifications")
    /// The base link the bar's buttons open, published as the `hyprmac_notifications` value.
    static var link: String { "hyprmac://notifications/\(Tray.token)" }

    /// hyprmac://notifications/<token>/dismiss-all or hyprmac://notifications/<token>/dismiss/<id>
    static func handle(_ url: URL) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.first == Tray.token else {
            Log.write("notifications: ignored a hyprmac:// link that didn't come from the bar")
            return
        }
        if parts.count == 2, parts[1] == "dismiss-all" {
            queue.async { run("clear all", dismissAll) }
        } else if parts.count == 3, parts[1] == "dismiss", let id = UUID(uuidString: parts[2]) {
            queue.async { run("clear one") { try dismiss(id, in: $0) } }
        } else {
            Log.write("notifications: unknown link \(url.path)")
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    // OmniWM's panel is meant to re-read notifications when their database changes, but its file watch
    // misses the changes (seen on macOS 26.5 and 26.6), so the bar kept showing notifications that were
    // already gone and missed new ones. HyprMac checks the database files every two seconds and asks the
    // patched panel to re-read (its `trigger` in bar/notifications-patch.py) when they change.
    private static var timer: DispatchSourceTimer?
    private static var lastStamp: [String]?

    static func startWatching() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler {
            let stamp = [Paths.notificationDatabase, Paths.notificationDatabase + "-wal"].map { path -> String in
                var s = stat()
                guard stat(path, &s) == 0 else { return "-" }
                return "\(s.st_ino) \(s.st_size) \(s.st_mtimespec.tv_sec).\(s.st_mtimespec.tv_nsec)"
            }
            defer { lastStamp = stamp }
            if let last = lastStamp, last != stamp { refreshBar() }
        }
        t.resume()
        timer = t
    }

    /// Asks the patched panel to re-read. An unpatched panel has no trigger to receive it.
    private static func refreshBar() {
        guard FileManager.default.fileExists(atPath: Paths.patchedNotificationsMarker) else { return }
        Dispatchers.omniwmctl(["shell", "trigger", "notifications", "hyprmac-refresh"], quiet: true)
    }

    /// Opens Notification Center's panel when it is closed, does the work, and closes the panel again.
    private static func run(_ what: String, _ body: (Panel) throws -> Int) {
        // The database changes a few seconds later and the watch above refreshes the panel then; this
        // refresh drops a notification that was already gone when its × was clicked.
        defer { refreshBar() }
        guard let panel = Panel() else { Log.write("notifications: \(what): Notification Center isn't running"); return }
        do {
            let opened = try panel.open()
            defer { if opened { panel.close() } }
            Log.write("notifications: \(what): cleared \(try body(panel))")
        } catch {
            Log.write("notifications: \(what) failed: \(error)")
        }
    }

    /// Clears every notification: "Clear All" on each app's stack, "Close" on a lone notification.
    private static func dismissAll(_ panel: Panel) throws -> Int {
        var cleared = 0
        for _ in 0..<100 {
            let items = panel.items()
            guard let first = items.first else { break }
            let names = actions(first)
            guard let action = names.first(where: { $0.hasPrefix("Name:Clear All\n") }) ?? names.first(where: { $0.hasPrefix("Name:Close\n") }) else {
                throw Failure(description: "no Clear All or Close on \(string(first, kAXSubroleAttribute) ?? "an item")")
            }
            AXUIElementPerformAction(first, action as CFString)
            cleared += 1
            guard panel.wait({ panel.items().count < items.count || !(panel.items().first.map { CFEqual($0, first) } ?? false) }) else {
                throw Failure(description: "Notification Center didn't clear \(string(first, kAXSubroleAttribute) ?? "an item")")
            }
        }
        return cleared
    }

    /// Clears one notification. A collapsed app stack shows only its newest notification, so stacks are
    /// opened one at a time until the notification stands on its own.
    private static func dismiss(_ id: UUID, in panel: Panel) throws -> Int {
        func identifier(_ e: AXUIElement) -> UUID? { string(e, kAXIdentifierAttribute).flatMap(UUID.init(uuidString:)) }
        func find() -> AXUIElement? { panel.items().first { identifier($0) == id } }
        func isStack(_ e: AXUIElement) -> Bool { string(e, kAXSubroleAttribute)?.hasSuffix("Stack") ?? false }
        var opened = Set<UUID>()
        var target: AXUIElement
        while true {
            if let found = find(), !isStack(found) { target = found; break }
            guard let stack = panel.items().first(where: { isStack($0) && !(identifier($0).map(opened.contains) ?? true) }),
                  let stackId = identifier(stack) else {
                throw Failure(description: "notification \(id) isn't in Notification Center")
            }
            opened.insert(stackId)
            AXUIElementPerformAction(stack, kAXPressAction as CFString)
            _ = panel.wait { panel.items().first { identifier($0) == stackId }.map { !isStack($0) } ?? true }
        }
        guard let close = actions(target).first(where: { $0.hasPrefix("Name:Close\n") }) else {
            throw Failure(description: "no Close on \(string(target, kAXSubroleAttribute) ?? "the notification")")
        }
        AXUIElementPerformAction(target, close as CFString)
        guard panel.wait({ find() == nil }) else { throw Failure(description: "Notification Center kept it") }
        return 1
    }

    /// Notification Center's panel, opened and closed with the menu bar clock, as a click on it would.
    private final class Panel {
        let center: AXUIElement
        let clockOwner: AXUIElement

        init?() {
            func pid(_ bundle: String) -> pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier }
            guard let centerPid = pid("com.apple.notificationcenterui"),
                  let clockPid = pid("com.apple.MenuBarAgent") ?? pid("com.apple.controlcenter") else { return nil }
            center = AXUIElementCreateApplication(centerPid)
            clockOwner = AXUIElementCreateApplication(clockPid)
            AXUIElementSetMessagingTimeout(center, 1)
            AXUIElementSetMessagingTimeout(clockOwner, 1)
        }

        /// Opens the panel unless it is open already; true when this opened it.
        func open() throws -> Bool {
            if list() != nil { return false }
            AXUIElementPerformAction(try clock(), kAXPressAction as CFString)
            guard wait({ self.list() != nil }) else { throw Failure(description: "Notification Center's panel didn't open") }
            return true
        }

        func close() {
            guard list() != nil, let clock = try? clock() else { return }
            AXUIElementPerformAction(clock, kAXPressAction as CFString)
        }

        func clock() throws -> AXUIElement {
            guard let bar = attribute(clockOwner, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else {
                throw Failure(description: "the menu bar clock isn't reachable")
            }
            for item in children(bar as! AXUIElement) {
                for e in [item] + children(item) where string(e, kAXIdentifierAttribute) == "com.apple.menuextra.clock" { return e }
            }
            throw Failure(description: "the menu bar clock isn't there")
        }

        /// The panel's list of notifications (identifier AXNotificationListItems), when the panel is open.
        func list() -> AXUIElement? {
            var budget = 400
            func search(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
                budget -= 1
                guard budget > 0, depth < 8 else { return nil }
                if string(e, kAXIdentifierAttribute) == "AXNotificationListItems" { return e }
                for child in children(e) { if let found = search(child, depth + 1) { return found } }
                return nil
            }
            for window in (attribute(center, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                if let found = search(window, 0) { return found }
            }
            return nil
        }

        /// The notifications and app stacks in the list, top first.
        func items() -> [AXUIElement] {
            guard let list = list() else { return [] }
            return children(list).filter { string($0, kAXSubroleAttribute)?.hasPrefix("AXNotificationCenter") ?? false }
        }

        /// Polls until the condition holds, for up to two seconds.
        func wait(_ condition: () -> Bool) -> Bool {
            for _ in 0..<40 {
                if condition() { return true }
                usleep(50_000)
            }
            return condition()
        }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(e, &names) == .success ? (names as? [String]) ?? [] : []
    }
}
