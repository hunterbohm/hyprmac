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

    /// Run omniwmctl synchronously (call from omniQueue or a CLI context).
    @discardableResult
    static func omniwmctl(_ args: [String], quiet: Bool = false) -> Result {
        guard let path = omniwmctlPath else {
            Log.write("omniwmctl not found; is OmniWM installed?")
            return Result(status: 127, output: "omniwmctl not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return Result(status: 126, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        // "ignored: no_change" (e.g. switching to the workspace you are on) is not a failure worth logging.
        if p.terminationStatus != 0 && !quiet && !out.contains("ignored") {
            Log.write("omniwmctl \(args.joined(separator: " ")) -> \(p.terminationStatus): \(out.prefix(300))")
        }
        return Result(status: p.terminationStatus, output: out)
    }

    /// Try each command in turn until one succeeds; used where Dwindle and the scrolling layout differ.
    static func omniCommand(_ alternatives: [String]...) {
        for args in alternatives {
            let r = omniwmctl(["command"] + args)
            if r.ok { return }
            // Only fall through on a layout mismatch or unsupported command; a real failure stops here.
            if !(r.output.contains("layout_mismatch") || r.output.contains("unsupported") || r.output.contains("invalid")) { return }
        }
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
            exec(cmd)
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
            if d == "up" || d == "down" {
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
