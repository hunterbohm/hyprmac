import AppKit
import ApplicationServices

let hyprmacVersion = "0.1.0"

// MARK: - On-screen notices (Hyprland shows config errors in a red bar; submaps get a small pill)

final class Notice {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let color: NSColor
    private let atTop: Bool

    init(color: NSColor, atTop: Bool) {
        self.color = color
        self.atTop = atTop
    }

    func show(_ text: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = color.cgColor
            box.layer?.cornerRadius = 8
            label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            box.addSubview(label)
            p.contentView = box
            panel = p
        }
        label.stringValue = text
        let maxWidth = min(900, screen.visibleFrame.width - 40)
        label.preferredMaxLayoutWidth = maxWidth - 24
        let size = label.sizeThatFits(NSSize(width: maxWidth - 24, height: 1000))
        let w = min(maxWidth, size.width + 24), h = size.height + 16
        label.frame = NSRect(x: 12, y: 8, width: w - 24, height: size.height)
        let vf = screen.visibleFrame
        let y = atTop ? screen.frame.maxY - Notice.topInset(screen) - h - 8 : vf.minY + 24
        panel?.setFrame(NSRect(x: vf.midX - w / 2, y: y, width: w, height: h), display: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private var flashToken = 0
    /// Show a message briefly.
    func flash(_ text: String, seconds: Double = 1.6) {
        flashToken += 1
        let token = flashToken
        show(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.flashToken == token { self?.hide() }
        }
    }

    /// Height taken at the top of the screen: the menu bar, or a bar drawn over it (OmniWM's workspace bar,
    /// SketchyBar), which macOS leaves out of visibleFrame when the menu bar hides itself.
    static func topInset(_ screen: NSScreen) -> CGFloat {
        var inset = screen.frame.maxY - screen.visibleFrame.maxY
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTop = primaryHeight - screen.frame.maxY  // window bounds use a top-left origin
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) != getpid(),
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let top = b["Y"], let width = b["Width"], let height = b["Height"] else { continue }
            guard abs(top - screenTop) <= 1, height <= 80, width >= screen.frame.width / 2,
                  x < screen.frame.maxX, x + width > screen.frame.minX else { continue }
            inset = max(inset, top + height - screenTop)
        }
        return inset
    }
}

// MARK: - Daemon

final class Daemon: NSObject, NSApplicationDelegate {
    let tap = KeyTap()
    var config = HyprConfig(path: Paths.config)
    var mtimes: [String: Date] = [:]
    let errorNotice = Notice(color: NSColor(calibratedRed: 0.75, green: 0.12, blue: 0.16, alpha: 0.95), atTop: true)
    let submapNotice = Notice(color: NSColor(calibratedWhite: 0.12, alpha: 0.92), atTop: false)
    let toast = Notice(color: NSColor(calibratedWhite: 0.12, alpha: 0.92), atTop: false)
    var permissionTimer: Timer?
    var permissionTries = 0
    var hupSource: DispatchSourceSignal?
    var termSource: DispatchSourceSignal?
    var omniSettingsSeen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
        try? "\(getpid())".write(toFile: Paths.pidFile, atomically: true, encoding: .utf8)
        Log.write("HyprMac \(hyprmacVersion) starting (config \(Paths.config))")

        // Record mode and the prompter don't outlast the agent, as in the AeroSpace setup they replace.
        try? FileManager.default.removeItem(atPath: Modes.recordState)
        try? FileManager.default.removeItem(atPath: Modes.prompterState)
        Dispatchers.notify = { [weak self] text in
            Log.write(text)
            DispatchQueue.main.async { self?.toast.flash(text) }
        }

        tap.onDispatch = { [weak self] bind in self?.dispatch(bind) }
        tap.onSubmap = { [weak self] name in
            // Drawing waits for the key tap's callback to return.
            DispatchQueue.main.async {
                if name.isEmpty { self?.submapNotice.hide() } else { self?.submapNotice.show("submap: \(name)   (Esc to leave)") }
            }
        }

        signal(SIGHUP, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        src.setEventHandler { [weak self] in self?.reload(reason: "hyprctl reload") }
        src.resume()
        hupSource = src
        // Stopping the agent (launchd sends SIGTERM) gives Notification Center's window back its own place.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { Banners.restore(); exit(0) }
        term.resume()
        termSource = term

        omniSettingsSeen = FileManager.default.fileExists(atPath: Paths.omniSettings)
        reload(reason: "startup")
        Tray.start(hide: trayHidden())
        Notifications.startWatching()
        Banners.start()
        runExecOnce()
        installTap()

        // Hyprland reloads on save; poll the config files' timestamps (cheap, and survives editors that replace files).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkForChanges() }
        // Screens changing shifts the menu bar height that the top gap is computed from.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            OmniSettings.apply(self.config)
            Banners.screensChanged()
        }
    }

    func installTap() {
        if tap.install() {
            permissionTimer?.invalidate(); permissionTimer = nil
            if config.errors.isEmpty { errorNotice.hide() }
            return
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        errorNotice.show("HyprMac needs Accessibility access to read your shortcuts.\nSystem Settings → Privacy & Security → Accessibility → turn on HyprMac.")
        Log.write("waiting for Accessibility permission")
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.tap.install() {
                    self.permissionTimer?.invalidate(); self.permissionTimer = nil
                    self.showErrors()
                } else {
                    // macOS can keep answering "no" to a process that started before the switch was turned on,
                    // so every 30 s hand over to a fresh process (launchd restarts the agent).
                    self.permissionTries += 1
                    if AXIsProcessTrusted() || self.permissionTries >= 15 {
                        Log.write("restarting to pick up Accessibility permission")
                        exit(0)
                    }
                }
            }
        }
    }

    func reload(reason: String) {
        let c = HyprConfig.load(path: Paths.config)
        config = c
        Settings.superIs = (c.setting("hyprmac:super_key") ?? "option").lowercased()
        if !["option", "command", "control"].contains(Settings.superIs) { Settings.superIs = "option" }
        tap.load(c.binds, superIs: Settings.superIs)
        mtimes = currentMtimes()
        let changed = OmniSettings.apply(c)
        Log.write("loaded config (\(reason)): \(c.binds.count) binds, \(c.errors.count) errors\(changed != nil ? ", OmniWM updated" : "")")
        for cmd in c.exec { Dispatchers.exec(cmd) }   // Hyprland runs `exec` lines at start and on every reload
        if reason != "startup" { Tray.start(hide: trayHidden()) }
        showErrors()
    }

    /// `tray_hide = Google Drive, com.example.app` in `hyprmac { }`: menu bar apps to leave out of the bar.
    func trayHidden() -> [String] {
        (config.setting("hyprmac:tray_hide") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The bar's tray widget opens hyprmac://tray/<bundle>/<index> when you click a menu bar app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "hyprmac" {
            Tray.handle(url)
        }
    }

    func showErrors() {
        guard tap.isInstalled else { return }
        if config.errors.isEmpty { errorNotice.hide(); return }
        let shown = config.errors.prefix(6).map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
        let more = config.errors.count > 6 ? "\n…and \(config.errors.count - 6) more" : ""
        errorNotice.show("hyprland.conf has errors (\((config.path as NSString).abbreviatingWithTildeInPath)):\n\(shown)\(more)")
    }

    func runExecOnce() {
        let boot = bootSessionID()
        let stamp = (try? String(contentsOfFile: Paths.execOnceStamp, encoding: .utf8)) ?? ""
        guard stamp != boot else { return }
        for cmd in config.execOnce { Dispatchers.exec(cmd) }
        try? boot.write(toFile: Paths.execOnceStamp, atomically: true, encoding: .utf8)
    }

    func currentMtimes() -> [String: Date] {
        var m: [String: Date] = [:]
        for f in Set(config.sources + [Paths.config]) {
            m[f] = (try? FileManager.default.attributesOfItem(atPath: f)[.modificationDate] as? Date) ?? .distantPast
        }
        return m
    }

    func checkForChanges() {
        if currentMtimes() != mtimes { reload(reason: "file changed"); return }
        // OmniWM writes its settings only after its first-run permission window; apply ours once it has.
        let omniReady = FileManager.default.fileExists(atPath: Paths.omniSettings)
        if omniReady && !omniSettingsSeen {
            reload(reason: "OmniWM settings appeared")
            DispatchQueue.global(qos: .utility).async { OmniSettings.ensureOmniWMPickedUp() }
        }
        omniSettingsSeen = omniReady
    }

    /// Called from the key tap's callback, which must return at once. Submaps change right here (the next key
    /// press already resolves against the new one); reload runs on the main thread after the callback; everything
    /// else is queued on `Dispatchers.omniQueue`, which runs binds one at a time in the order they were pressed.
    func dispatch(_ bind: Bind) {
        Log.write("bind \(bind.mods.resolve(superIs: Settings.superIs).symbols)\(bind.key.label) -> \(bind.dispatcher) \(bind.arg)")
        Dispatchers.run(bind.dispatcher, bind.arg,
                        submapHandler: { [weak self] name in self?.tap.setSubmap(name) },
                        reload: { DispatchQueue.main.async { [weak self] in self?.reload(reason: "reload bind") } })
    }
}

// MARK: - CLI

func printUsage() {
    print("""
    HyprMac \(hyprmacVersion): Hyprland-style config and keybinds for macOS, on top of OmniWM.

    usage: hyprmac <command>     (also available as `hyprctl`)
      daemon                 run the background agent (the LaunchAgent does this)
      reload                 reload hyprland.conf in the running agent
      dispatch <name> [arg]  run a dispatcher now, e.g. `hyprctl dispatch workspace 2`
      binds                  list keybinds
      check [file]           check a config for errors
      apply                  write the config's look and feel into OmniWM now
      status                 show whether the agent runs and has permission
      version

    config: \((Paths.config as NSString).abbreviatingWithTildeInPath)
    """)
}

func runningPid() -> pid_t? {
    guard let s = try? String(contentsOfFile: Paths.pidFile, encoding: .utf8), let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kill(p, 0) == 0 ? p : nil
}

func cli(_ args: [String]) -> Int32 {
    guard let cmd = args.first else { printUsage(); return 0 }
    switch cmd {
    case "daemon":
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Daemon()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return 0
    case "reload":
        guard let p = runningPid() else { print("HyprMac agent is not running"); return 1 }
        kill(p, SIGHUP)
        let c = HyprConfig.load(path: Paths.config)
        if c.errors.isEmpty { print("ok") } else { c.errors.forEach { print("line \($0.line): \($0.message)") } }
        return c.errors.isEmpty ? 0 : 1
    case "dispatch":
        guard args.count >= 2 else { print("usage: hyprctl dispatch <dispatcher> [args]"); return 1 }
        let d = args[1].lowercased()
        guard Dispatchers.known.contains(d) else { print("unknown dispatcher \(d)"); return 1 }
        if d == "submap" || d == "reload" { print("\(d) only works inside the agent; use a keybind"); return 1 }
        let c = HyprConfig.load(path: Paths.config)
        Settings.superIs = (c.setting("hyprmac:super_key") ?? "option").lowercased()
        Log.echo = true
        Dispatchers.notify = { print($0) }
        Dispatchers.run(d, args.dropFirst(2).joined(separator: " "), sync: true)
        if d == "exec" || d == "execr" { usleep(200_000) }
        if d == "sendshortcut" { usleep(100_000) }
        return 0
    case "binds":
        let c = HyprConfig.load(path: Paths.config)
        let superIs = (c.setting("hyprmac:super_key") ?? "option").lowercased()
        for b in c.binds {
            let mods = b.mods.resolve(superIs: superIs).symbols
            let where_ = b.submap.isEmpty ? "" : "[\(b.submap)] "
            let chord = (mods + b.key.label).padding(toLength: 14, withPad: " ", startingAt: 0)
            let arg = b.arg.isEmpty ? "" : " \(b.arg)"
            let desc = b.description.isEmpty ? "" : "  # \(b.description)"
            print("\(where_)\(chord) \(b.dispatcher)\(arg)\(desc)")
        }
        return 0
    case "check":
        let path = args.count > 1 ? args[1] : Paths.config
        let c = HyprConfig.load(path: path)
        if c.errors.isEmpty { print("ok: \(c.binds.count) binds, \(c.workspaces.count) workspace rules"); return 0 }
        c.errors.forEach { print("line \($0.line): \($0.message)") }
        return 1
    case "apply":
        let c = HyprConfig.load(path: Paths.config)
        Settings.superIs = (c.setting("hyprmac:super_key") ?? "option").lowercased()
        print(OmniSettings.apply(c) ?? "OmniWM settings already match")
        OmniSettings.ensureOmniWMPickedUp()
        return 0
    case "status":
        let p = runningPid()
        print(p.map { "agent: running (pid \($0))" } ?? "agent: not running")
        print("omniwmctl: \(Dispatchers.omniwmctlPath ?? "not found")")
        if Dispatchers.omniwmctlPath != nil {
            let r = Dispatchers.omniwmctl(["ping"], quiet: true)
            print("OmniWM: \(r.ok ? "answering" : "not answering (is it running with IPC on?)")")
        }
        let c = HyprConfig.load(path: Paths.config)
        print("config: \((Paths.config as NSString).abbreviatingWithTildeInPath), \(c.binds.count) binds, \(c.errors.count) errors")
        let laptopOnly = Screens.laptopOnly()
        print("screens: \(NSScreen.screens.map(\.localizedName).joined(separator: ", "))\(laptopOnly ? " (laptop screen only)" : "")")
        if laptopOnly && c.bool("hyprmac:laptop_gaps") == false { print("gaps: off until another screen is connected") }
        if Modes.recordGaps() != nil { print("record mode: on") }
        return p == nil ? 1 : 0
    case "version", "--version", "-v":
        print("HyprMac \(hyprmacVersion)")
        return 0
    case "help", "--help", "-h":
        printUsage()
        return 0
    default:
        print("unknown command: \(cmd)\n")
        printUsage()
        return 1
    }
}

exit(cli(Array(CommandLine.arguments.dropFirst())))
