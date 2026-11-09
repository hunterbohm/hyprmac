import AppKit

// Hyprland dispatchers, carried out on macOS through OmniWM's command line (`omniwmctl`).

enum Dispatchers {
    static let known: Set<String> = [
        "exec", "execr", "killactive", "closewindow", "togglefloating", "setfloating", "settiled",
        "fullscreen", "fullscreenstate", "movefocus", "movewindow", "swapwindow", "moveintogroup",
        "moveoutofgroup", "workspace", "movetoworkspace", "movetoworkspacesilent", "togglespecialworkspace",
        "togglesplit", "swapsplit", "layoutmsg", "resizeactive", "focusmonitor", "movecurrentworkspacetomonitor",
        "swapactiveworkspaces", "focuscurrentorlast", "focusurgentorlast", "cyclenext", "changegroupactive",
        "togglegroup", "pseudo", "pin", "centerwindow", "submap", "exit", "forcerendererreload", "dpms",
        // HyprMac additions
        "omniwm", "omniwmctl", "focusapp", "layout", "reload", "overview", "balance", "sendshortcut",
        "readingmode", "recordmode", "prompter", "reserve",
    ]

    /// Shows a short message: a pill on screen in the agent, a printed line in the CLI.
    static var notify: ((String) -> Void)?

    static let omniQueue = DispatchQueue(label: "hyprmac.omniwm")

    static var omniwmctlPath: String? = {
        for p in ["/opt/homebrew/bin/omniwmctl", "/usr/local/bin/omniwmctl",
                  "/Applications/OmniWM.app/Contents/MacOS/omniwmctl",
                  "/Applications/OmniWM.app/Contents/Resources/omniwmctl"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    static let shellPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        return (extra + base.split(separator: ":").map(String.init)).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    struct Result {
        var status: Int32
        var output: String
        var ok: Bool { status == 0 }
    }

    /// One omniwmctl process, built but maybe not yet started.
    private struct Launch {
        let args: [String]
        let process: Process?
        let pipe = Pipe()
        let exited = DispatchSemaphore(value: 0)
    }

    private static func makeLaunch(_ args: [String]) -> Launch {
        guard let path = omniwmctlPath else { return Launch(args: args, process: nil) }
        let l = Launch(args: args, process: Process())
        let p = l.process!
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = l.pipe
        p.standardError = l.pipe
        p.standardInput = FileHandle.nullDevice
        // Not `waitUntilExit()`: it polls the run loop and added ~65 ms to every call (omniwmctl itself takes ~8 ms).
        let exited = l.exited
        p.terminationHandler = { _ in exited.signal() }
        return l
    }

    /// Start the process, then wait for it and read what it printed.
    private static func collect(_ l: Launch, started: Bool, quiet: Bool) -> Result {
        guard let p = l.process else {
            Log.write("omniwmctl not found; is OmniWM installed?")
            return Result(status: 127, output: "omniwmctl not found")
        }
        guard started else { return Result(status: 126, output: "could not start omniwmctl") }
        let data = l.pipe.fileHandleForReading.readDataToEndOfFile()
        l.exited.wait()
        let out = String(data: data, encoding: .utf8) ?? ""
        // "ignored: no_change" (e.g. switching to the workspace you are on) is not a failure worth logging.
        if p.terminationStatus != 0 && !quiet && !out.contains("ignored") {
            Log.write("omniwmctl \(l.args.joined(separator: " ")) -> \(p.terminationStatus): \(out.prefix(300))")
        }
        return Result(status: p.terminationStatus, output: out)
    }

    /// Run omniwmctl synchronously (call from omniQueue or a CLI context).
    @discardableResult
    static func omniwmctl(_ args: [String], quiet: Bool = false) -> Result {
        omniwmctlTogether([args], quiet: quiet)[0]
    }

    /// Run several omniwmctl calls at the same time and return their results in order. All processes are
    /// built first and started back to back, so the commands reach OmniWM within about a millisecond of each
    /// other (and two queries cost one round trip, not two).
    @discardableResult
    static func omniwmctlTogether(_ calls: [[String]], quiet: Bool = false) -> [Result] {
        let launches = calls.map(makeLaunch)
        let started = launches.map { l -> Bool in
            guard let p = l.process else { return false }
            do { try p.run(); return true } catch { Log.write("omniwmctl \(l.args.joined(separator: " ")): \(error)"); return false }
        }
        return zip(launches, started).map { collect($0, started: $1, quiet: quiet) }
    }

    /// Try each command in turn until one succeeds; used where Dwindle and the scrolling layout differ.
    /// True when one of them was carried out.
    @discardableResult
    static func omniCommand(_ alternatives: [String]...) -> Bool {
        for args in alternatives {
            let r = omniwmctl(["command"] + args)
            if r.ok { return true }
            // Only fall through on a layout mismatch or unsupported command; a real failure stops here.
            if !(r.output.contains("layout_mismatch") || r.output.contains("unsupported") || r.output.contains("invalid")) { return false }
        }
        return false
    }

    static func exec(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shellPath
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        let log = Log.handle()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        do {
            try p.run()
            DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
        } catch {
            Log.write("exec failed: \(command): \(error)")
        }
    }

    static func direction(_ arg: String) -> String? {
        switch arg.trimmingCharacters(in: .whitespaces).lowercased() {
        case "l", "left": return "left"
        case "r", "right": return "right"
        case "u", "t", "up", "top": return "up"
        case "d", "b", "down", "bottom": return "down"
        default: return nil
        }
    }

    static func scratchSlot(_ name: String) -> String {
        // special, special:magic -> 1; special:2 -> 2; any other name hashes to a stable slot 1-10.
        var n = name.lowercased()
        if n.hasPrefix("special") { n = String(n.dropFirst(7)) }
        if n.hasPrefix(":") { n = String(n.dropFirst()) }
        if n.isEmpty || n == "magic" || n == "scratchpad" { return "1" }
        if let i = Int(n), (1...10).contains(i) { return String(i) }
        let sum = n.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return String(sum % 10 + 1)
    }

    /// Carry out one dispatcher. `submapHandler` is set by the daemon; the CLI has none.
    static func run(_ dispatcher: String, _ rawArg: String, sync: Bool = false, submapHandler: ((String) -> Void)? = nil, reload: (() -> Void)? = nil) {
        let arg = rawArg.trimmingCharacters(in: .whitespaces)
        switch dispatcher {
        case "exec", "execr":
            // Hyprland exec rules look like `[float] cmd`; drop the rule block.
            var cmd = arg
            if cmd.hasPrefix("["), let close = cmd.firstIndex(of: "]") { cmd = String(cmd[cmd.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
            // Off the caller's thread (the key tap's): starting a process takes a millisecond or two, and
            // running in order with the omniwmctl dispatchers keeps presses in the order they were made.
            if sync { exec(cmd) } else { omniQueue.async { exec(cmd) } }
        case "submap":
            submapHandler?(arg.lowercased() == "reset" ? "" : arg)
        case "reload":
            reload?()
        default:
            if sync { omniQueue.sync { runOmni(dispatcher, arg) } }
            else { omniQueue.async { runOmni(dispatcher, arg) } }
        }
    }

    private static func runOmni(_ dispatcher: String, _ arg: String) {
        switch dispatcher {
        case "killactive", "closewindow":
            omniCommand(["close-focused-window"])
            refocusAfterClose()
        case "togglefloating", "setfloating", "settiled":
            omniCommand(["toggle-focused-window-floating"])
        case "fullscreen", "fullscreenstate":
            if arg == "native" || arg == "2" { omniCommand(["toggle-native-fullscreen"]) }
            else { omniCommand(["toggle-fullscreen"]) }
        case "movefocus":
            guard let d = direction(arg) else { return Log.write("movefocus: bad direction '\(arg)'") }
            omniCommand(["focus", d])
        case "movewindow", "swapwindow":
            if arg.lowercased().hasPrefix("mon:") {
                if let d = direction(String(arg.dropFirst(4))) { omniCommand(["move-to-monitor", d]) }
                return
            }
            guard let d = direction(arg) else { return Log.write("\(dispatcher): bad direction '\(arg)'") }
            if let ws = readFocusedWorkspace(), ws.layout == "dwindle" {
                moveDwindleWindow(d, read: ws)
            } else if d == "up" || d == "down" {
                omniCommand(["move-column", d], ["move-window-\(d)"])
            } else {
                omniCommand(["move-column", d], ["move", d])
            }
        case "moveintogroup", "moveoutofgroup":
            guard let d = direction(arg.isEmpty ? "r" : arg) else { return }
            omniCommand(["move", d])
        case "workspace":
            workspace(arg)
        case "movetoworkspace", "movetoworkspacesilent":
            let follow = dispatcher == "movetoworkspace"
            let target = arg.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? arg
            if target.lowercased().hasPrefix("special") {
                omniCommand(["scratchpad", "assign", scratchSlot(target)])
            } else if let n = Int(target) {
                moveFocused(to: String(n), follow: follow)
            } else if ["+1", "e+1", "r+1", "m+1"].contains(target) {
                moveFocused(to: "down", follow: follow)
            } else if ["-1", "e-1", "r-1", "m-1"].contains(target) {
                moveFocused(to: "up", follow: follow)
            } else {
                Log.write("\(dispatcher): unsupported target '\(target)'")
            }
        case "togglespecialworkspace":
            omniCommand(["scratchpad", "toggle", scratchSlot(arg)])
        case "togglesplit":
            omniCommand(["toggle-split"])
        case "swapsplit":
            omniCommand(["swap-split"])
        case "layoutmsg":
            let words = arg.split(separator: " ").map { String($0).lowercased() }
            switch words.first ?? "" {
            case "togglesplit": omniCommand(["toggle-split"])
            case "swapsplit": omniCommand(["swap-split"])
            case "preselect":
                if words.count > 1, let d = direction(words[1]) { omniCommand(["preselect", d]) }
                else { omniCommand(["preselect", "clear"]) }
            case "movetoroot", "move-to-root": omniCommand(["move-to-root"])
            default: Log.write("layoutmsg: unsupported '\(arg)'")
            }
        case "resizeactive":
            resize(arg)
        case "focusmonitor":
            switch arg.lowercased() {
            case "-1", "l", "left", "u", "up", "prev", "previous": omniCommand(["focus-monitor", "prev"])
            case "last": omniCommand(["focus-monitor", "last"])
            default: omniCommand(["focus-monitor", "next"])
            }
        case "movecurrentworkspacetomonitor", "swapactiveworkspaces":
            let d = direction(arg) ?? (arg.contains("-") ? "left" : "right")
            omniCommand(["swap-workspace-with-monitor", d])
        case "focuscurrentorlast", "focusurgentorlast", "cyclenext":
            omniCommand(["focus", "previous"])
        case "changegroupactive":
            if arg.lowercased().hasPrefix("b") { omniCommand(["focus-window", "up-or-bottom"]) }
            else { omniCommand(["focus-window", "down-or-top"]) }
        case "centerwindow":
            omniCommand(["center-column"])
        case "dpms":
            if arg.lowercased().hasPrefix("off") { exec("pmset displaysleepnow") }
        case "togglegroup", "pseudo", "pin", "exit", "forcerendererreload":
            Log.write("\(dispatcher) has no macOS equivalent; ignored")
        case "omniwm":
            let words = arg.split(separator: " ").map(String.init)
            if !words.isEmpty { omniwmctl(["command"] + words) }
        case "omniwmctl":
            let words = arg.split(separator: " ").map(String.init)
            if !words.isEmpty { omniwmctl(words) }
        case "layout":
            switch arg.lowercased() {
            case "dwindle", "tiling": omniCommand(["set-workspace-layout", "dwindle"])
            case "scrolling", "niri", "scroller": omniCommand(["set-workspace-layout", "niri"])
            default: omniCommand(["toggle-workspace-layout"])
            }
        case "overview":
            omniCommand(["toggle-overview"])
        case "balance":
            omniCommand(["balance-sizes"])
        case "focusapp":
            focusApp(arg)
        case "sendshortcut":
            sendShortcut(arg)
        case "readingmode":
            Modes.readingMode(arg)
        case "recordmode":
            Modes.recordMode(arg, config: { HyprConfig.load(path: Paths.config) })
        case "prompter":
            Modes.prompter(arg)
        case "reserve":
            Modes.reserve(arg, config: { HyprConfig.load(path: Paths.config) })
        default:
            Log.write("unknown dispatcher \(dispatcher)")
        }
    }

    // MARK: movewindow on a dwindle workspace

    /// One tiled window as `omniwmctl query windows` reports it (Cocoa coordinates: larger y is higher).
    /// `frame` is live, so it is mid-flight while the window animates; `id` and `focused` are always current.
    private struct Tile {
        var id: String
        var frame: CGRect
        var focused: Bool
    }

    /// The focused workspace as OmniWM reports it right now.
    private struct WorkspaceRead {
        var number: Int
        var layout: String
        var tiles: [Tile]
    }

    private static func payload(_ r: Result) -> [String: Any]? {
        guard r.ok, let data = r.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let payload = result["payload"] as? [String: Any] else { return nil }
        return payload
    }

    private static func tiles(from list: [[String: Any]]) -> [Tile] {
        list.compactMap { w in
            guard w["mode"] as? String == "tiling", let id = w["id"] as? String,
                  let f = w["frame"] as? [String: Any],
                  let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
                  let width = (f["width"] as? NSNumber)?.doubleValue, let height = (f["height"] as? NSNumber)?.doubleValue
            else { return nil }
            return Tile(id: id, frame: CGRect(x: x, y: y, width: width, height: height), focused: w["isFocused"] as? Bool ?? false)
        }
    }

    /// The focused workspace's layout and tiles. The two queries run at the same time: one round trip, not two.
    /// `windows --visible` covers every visible workspace (one per screen); the focused workspace's id picks its own.
    private static func readFocusedWorkspace() -> WorkspaceRead? {
        let fields = ["--fields", "id,workspace,frame,mode,is-focused"]
        let r = omniwmctlTogether([["query", "workspaces", "--visible", "--format", "json"],
                                   ["query", "windows", "--visible"] + fields + ["--format", "json"]], quiet: true)
        guard let spaces = payload(r[0])?["workspaces"] as? [[String: Any]],
              let ws = spaces.first(where: { $0["isFocused"] as? Bool == true }),
              let wsID = ws["id"] as? String, let layout = ws["layout"] as? String, let n = ws["number"] as? Int,
              let windows = payload(r[1])?["windows"] as? [[String: Any]] else { return nil }
        let mine = windows.filter { ($0["workspace"] as? [String: Any])?["id"] as? String == wsID }
        return WorkspaceRead(number: n, layout: layout, tiles: tiles(from: mine))
    }

    private static func tiles(workspace: Int) -> [Tile] {
        guard let list = payload(omniwmctl(["query", "windows", "--workspace", String(workspace), "--visible", "--format", "json"], quiet: true))?["windows"] as? [[String: Any]] else { return [] }
        return tiles(from: list)
    }

    private static func same(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // State below is touched only on omniQueue.

    /// When our last move command went out.
    private static var lastDwindleMove = Date.distantPast
    /// Where each tile of the workspace ends up once the last move has finished animating (window id -> frame);
    /// nil when we couldn't tell.
    private static var expectedFrames: [String: CGRect]?
    /// OmniWM's animations are over well within this; frames read later than this are final.
    private static let animationWindow: TimeInterval = 1.2

    /// OmniWM's frames are live, so a window still animating from the last key press reports mid-flight
    /// numbers. Wait until it has had 150 ms to start and two polls in a row agree.
    private static func settledTiles(workspace: Int, limit: TimeInterval = 1.2) -> [Tile] {
        let sinceMove = Date().timeIntervalSince(lastDwindleMove)
        // Nothing of ours hasn't started yet (it starts ~50 ms after the command).
        if sinceMove < 0.15 { Thread.sleep(forTimeInterval: 0.15 - sinceMove) }
        let begin = Date()
        var last = tiles(workspace: workspace)
        while Date().timeIntervalSince(begin) < limit {
            Thread.sleep(forTimeInterval: 0.03)
            let now = tiles(workspace: workspace)
            if now.count == last.count && zip(now, last).allSatisfy({ $0.id == $1.id && same($0.frame, $1.frame, tolerance: 0.5) }) { return now }
            last = now
        }
        return last
    }

    /// The layout the next move should be decided from, without waiting for the last animation when we can
    /// say where it ends. Window ids and the focused flag come fresh from `read`; the frames come from what
    /// the last move was expected to produce, as long as the same windows are still on the workspace.
    private static func layoutToDecideFrom(_ read: WorkspaceRead) -> [Tile] {
        guard Date().timeIntervalSince(lastDwindleMove) <= animationWindow else {
            expectedFrames = nil
            return read.tiles   // not animating any more: the live frames are the final ones
        }
        if let expected = expectedFrames {
            if expected.count == read.tiles.count, read.tiles.allSatisfy({ expected[$0.id] != nil }) {
                return read.tiles.map { Tile(id: $0.id, frame: expected[$0.id]!, focused: $0.focused) }
            }
            if read.tiles.allSatisfy({ expected[$0.id] == nil }) {
                expectedFrames = nil
                return read.tiles   // the last move was on another workspace
            }
        }
        return settledTiles(workspace: read.number)
    }

    /// AeroSpace-style `move` for Dwindle, decided from the (expected) settled layout and sent without waiting on
    /// the animation. If a tile is next to the window in that direction, `move-column` swaps with it. If not,
    /// and the window's partner sits across the other axis (two windows side by side and J pressed), flip
    /// the split so the window lands below/above/left/right of the partner, plus `swap-split` when it would
    /// land on the wrong side. A window already at the edge of its row stays put.
    /// (`move` can't be used here: in Dwindle it joins the neighbor's tab group instead of swapping.)
    private static func moveDwindleWindow(_ d: String, read: WorkspaceRead) {
        let now = layoutToDecideFrom(read)
        guard let focus = now.first(where: { $0.focused }) else {
            if omniCommand(["move-column", d]) { lastDwindleMove = Date(); expectedFrames = nil }
            return
        }
        let f = focus.frame
        let others = now.filter { !$0.focused }
        let tol: CGFloat = 8
        let horizontal = d == "left" || d == "right"

        func overlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool { min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound) > tol }
        // Cocoa coordinates: up is a larger y.
        let neighbors = others.filter { t in
            switch d {
            case "right": return t.frame.minX >= f.maxX - tol && overlap(t.frame.minY...t.frame.maxY, f.minY...f.maxY)
            case "left": return t.frame.maxX <= f.minX + tol && overlap(t.frame.minY...t.frame.maxY, f.minY...f.maxY)
            case "up": return t.frame.minY >= f.maxY - tol && overlap(t.frame.minX...t.frame.maxX, f.minX...f.maxX)
            default: return t.frame.maxY <= f.minY + tol && overlap(t.frame.minX...t.frame.maxX, f.minX...f.maxX)
            }
        }
        var frames = Dictionary(uniqueKeysWithValues: now.map { ($0.id, $0.frame) })

        if !neighbors.isEmpty {
            guard omniCommand(["move-column", d]) else { return }
            lastDwindleMove = Date()
            // A swap trades the two frames. With several tiles that way we can't tell which one `move-column` took.
            if neighbors.count == 1, let n = neighbors.first {
                frames[focus.id] = n.frame
                frames[n.id] = f
                expectedFrames = frames
            } else {
                expectedFrames = nil
            }
            return
        }

        // No tile that way. The partner to flip against shares the window's extent across the move axis.
        let partner = others.filter { t in
            horizontal
                ? abs(t.frame.minX - f.minX) <= tol && abs(t.frame.width - f.width) <= tol
                : abs(t.frame.minY - f.minY) <= tol && abs(t.frame.height - f.height) <= tol
        }.min { a, b in
            hypot(a.frame.midX - f.midX, a.frame.midY - f.midY) < hypot(b.frame.midX - f.midX, b.frame.midY - f.midY)
        }
        guard let p = partner else { return }

        // toggle-split keeps child order: the first child is the left / lower tile, the second the right / upper
        // one (Cocoa coordinates). So the window ends up left or lower if it is first now, right or upper if second.
        let isFirst = horizontal ? f.midY < p.frame.midY : f.midX < p.frame.midX
        let wantFirst = d == "left" || d == "down"
        let needsSwap = isFirst != wantFirst
        // The two commands commute. Sent one after the other (a process start apart), OmniWM would start
        // animating toward the half-done layout and then turn round: the windows visibly hop the wrong way.
        // Started together, both are in before a frame is drawn.
        let results = omniwmctlTogether([["command", "toggle-split"]] + (needsSwap ? [["command", "swap-split"]] : []))
        lastDwindleMove = Date()
        guard results.allSatisfy(\.ok) else { expectedFrames = nil; return }

        let (first, second) = isFirst ? (focus, p) : (p, focus)
        let (firstFrame, secondFrame) = flipped(first: first.frame, second: second.frame, toSideBySide: horizontal)
        frames[first.id] = needsSwap ? secondFrame : firstFrame
        frames[second.id] = needsSwap ? firstFrame : secondFrame
        expectedFrames = frames
    }

    /// Where a pair of sibling tiles goes when their split flips: the pair's union rect is split along the other
    /// axis, keeping the gap between them and the first tile's share. The first child (left or lower) stays first.
    private static func flipped(first: CGRect, second: CGRect, toSideBySide: Bool) -> (CGRect, CGRect) {
        let u = first.union(second)
        if toSideBySide {
            let gap = max(0, u.height - first.height - second.height)
            let room = u.width - gap
            let w = room * first.height / (first.height + second.height)
            return (CGRect(x: u.minX, y: u.minY, width: w, height: u.height),
                    CGRect(x: u.minX + w + gap, y: u.minY, width: room - w, height: u.height))
        }
        let gap = max(0, u.width - first.width - second.width)
        let room = u.height - gap
        let h = room * first.width / (first.width + second.width)
        return (CGRect(x: u.minX, y: u.minY, width: u.width, height: h),
                CGRect(x: u.minX, y: u.minY + h + gap, width: u.width, height: room - h))
    }

    private static func workspace(_ arg: String) {
        let a = arg.lowercased()
        if let n = Int(a) {
            omniCommand(["switch-workspace", String(n)])
        } else if ["+1", "e+1", "r+1", "m+1"].contains(a) {
            omniCommand(["switch-workspace", "next"])
        } else if ["-1", "e-1", "r-1", "m-1"].contains(a) {
            omniCommand(["switch-workspace", "prev"])
        } else if a == "previous" || a == "previous_per_monitor" {
            omniCommand(["switch-workspace", "back-and-forth"])
        } else if a.hasPrefix("special") {
            omniCommand(["scratchpad", "toggle", scratchSlot(a)])
        } else if a.hasPrefix("name:") {
            omniwmctl(["workspace", "focus-name", String(arg.dropFirst(5))])
        } else {
            omniwmctl(["workspace", "focus-name", arg])
        }
    }

    private static func resize(_ arg: String) {
        let nums = arg.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
        guard nums.count >= 2 else { return Log.write("resizeactive needs 'X Y'") }
        let dx = nums[0], dy = nums[1]
        if dx != 0 {
            let op = dx > 0 ? "grow" : "shrink"
            let pct = (dx > 0 ? "+" : "-") + "10%"
            omniCommand(["resize", "horizontal", op], ["set-container-primary-span", pct])
        }
        if dy != 0 {
            let op = dy > 0 ? "grow" : "shrink"
            let pct = (dy > 0 ? "+" : "-") + "10%"
            omniCommand(["resize", "vertical", op], ["set-window-secondary-span", pct])
        }
    }

    /// Move the focused window to a workspace; with `follow`, go there with that window still focused,
    /// as Hyprland's movetoworkspace does (switching alone would focus the workspace's last window).
    private static func moveFocused(to workspace: String, follow: Bool) {
        let id = follow ? focusedWindowID() : nil
        omniCommand(["move-to-workspace", workspace])
        guard follow else { return }
        if let id { omniwmctl(["window", "navigate", id]) }
        else if let n = Int(workspace) { omniCommand(["switch-workspace", String(n)]) }
        else { omniCommand(["switch-workspace", workspace == "down" ? "next" : "prev"]) }
    }

    /// When the closed window was its app's last (Finder, say), macOS leaves that app active with nothing
    /// focused. Hyprland moves focus to the next window on the workspace; do the same.
    private static func refocusAfterClose() {
        for _ in 0..<6 {
            usleep(100_000)
            if focusedWindowID() != nil { return }
        }
        let ws = omniwmctl(["query", "workspaces", "--current", "--fields", "id", "--format", "json"])
        guard let wsData = ws.output.data(using: .utf8),
              let wsJSON = try? JSONSerialization.jsonObject(with: wsData) as? [String: Any],
              let payload = (wsJSON["result"] as? [String: Any])?["payload"] as? [String: Any],
              let wsID = (payload["workspaces"] as? [[String: Any]])?.first?["id"] as? String else { return }
        let r = omniwmctl(["query", "windows", "--workspace", wsID, "--fields", "id,focus-rank", "--format", "json"])
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return }
        var found: [(String, Int)] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let id = d["id"] as? String, id.hasPrefix("ow_") { found.append((id, d["focusRank"] as? Int ?? Int.max)) }
                d.values.forEach(walk)
            } else if let a = v as? [Any] { a.forEach(walk) }
        }
        walk(json)
        if let next = found.min(by: { $0.1 < $1.1 })?.0 { omniwmctl(["window", "focus", next]) }
    }

    private static func focusedWindowID() -> String? {
        let r = omniwmctl(["query", "windows", "--focused", "--fields", "id", "--format", "json"])
        guard r.ok, let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func find(_ v: Any) -> String? {
            if let d = v as? [String: Any] {
                if let id = d["id"] as? String, id.hasPrefix("ow_") { return id }
                for x in d.values { if let f = find(x) { return f } }
            } else if let a = v as? [Any] { for x in a { if let f = find(x) { return f } } }
            return nil
        }
        return find(json)
    }

    /// Focus the most recent window of an app (bundle id or app name), launching it when it has none.
    private static func focusApp(_ target: String) {
        guard !target.isEmpty else { return }
        let isBundle = target.contains(".") && !target.contains(" ")
        func newestWindow() -> String? {
            let selector = isBundle ? ["--bundle-id", target] : ["--app", target]
            let r = omniwmctl(["query", "windows"] + selector + ["--fields", "id,focus-rank", "--format", "json"])
            guard r.ok, let data = r.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            var found: [(String, Int)] = []
            func walk(_ v: Any) {
                if let d = v as? [String: Any] {
                    if let id = d["id"] as? String, id.hasPrefix("ow_") {
                        found.append((id, d["focusRank"] as? Int ?? Int.max))
                    }
                    d.values.forEach(walk)
                } else if let a = v as? [Any] { a.forEach(walk) }
            }
            walk(json)
            return found.min(by: { $0.1 < $1.1 })?.0
        }
        if let id = newestWindow() {
            omniwmctl(["window", "navigate", id])
            return
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = isBundle ? ["-b", target] : ["-a", target]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<40 {
            usleep(100_000)
            if let id = newestWindow() { omniwmctl(["window", "navigate", id]); return }
        }
    }

    private static func sendShortcut(_ arg: String) {
        // `sendshortcut, MODS, key` — post a key chord to the focused app.
        let parts = arg.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let mods = Mods.parse(parts[0]), case .code(let code)? = Keys.parse(parts[1]) else {
            return Log.write("sendshortcut needs 'MODS, key'")
        }
        let flags = mods.resolve(superIs: Settings.superIs).cgFlags
        DispatchQueue.main.async {
            let src = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                if let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) {
                    e.flags = flags
                    e.setIntegerValueField(.eventSourceUserData, value: KeyTap.syntheticMarker)
                    e.post(tap: .cgSessionEventTap)
                }
            }
        }
    }
}
