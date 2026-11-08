import Foundation

// Keeping OmniWM's notifications panel current. The panel is meant to re-read notifications when their
// database changes, but its file watch misses the changes (seen on macOS 26.5 and 26.6), so the bar kept
// showing notifications that were already gone and missed new ones. HyprMac checks the database files every
// two seconds and asks the patched panel to re-read (its `trigger` in bar/notifications-patch.py) when they
// change. Clearing is the panel's own job: on macOS 26 it hides cleared notifications in the bar.

enum Notifications {
    private static let queue = DispatchQueue(label: "hyprmac.notifications")
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
}
