import AppKit

// Writes hyprland.conf's look-and-feel settings into OmniWM's settings.toml, which OmniWM reloads live.
// The file is OmniWM's canonical TOML: `[table]` / `[[array]]` headers followed by `key = value` lines.
// Edits are line-based and only touch the keys HyprMac owns; everything else is left as OmniWM wrote it.

struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    var tomlLines: [String] {
        ["alpha = \(fmt(a))", "blue = \(fmt(b))", "green = \(fmt(g))", "red = \(fmt(r))"]
    }
    private func fmt(_ v: Double) -> String { String(format: "%.4f", min(max(v, 0), 1)) }
}

struct BorderSpec {
    var colors: [RGBA]
    var angle: Double?
}

enum ColorParser {
    /// Parse Hyprland color syntax: rgba(33ccffee) rgb(33ccff) rgba(51,204,255,0.93) 0xee33ccff, optionally
    /// several colors and an angle (`45deg`) for a gradient.
    static func parse(_ text: String) -> BorderSpec? {
        var colors: [RGBA] = []
        var angle: Double?
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        while !rest.isEmpty {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty { break }
            if rest.lowercased().hasPrefix("rgb") {
                guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") else { return nil }
                let inner = rest[rest.index(after: open)..<close].replacingOccurrences(of: " ", with: "")
                guard let c = parseFunction(String(inner)) else { return nil }
                colors.append(c)
                rest = rest[rest.index(after: close)...]
            } else {
                let token = rest.prefix(while: { $0 != " " && $0 != "\t" })
                rest = rest.dropFirst(token.count)
                let t = token.lowercased()
                if t.hasSuffix("deg"), let v = Double(t.dropLast(3)) { angle = v; continue }
                if t.hasPrefix("0x"), t.count == 10, let v = UInt32(t.dropFirst(2), radix: 16) {
                    colors.append(RGBA(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255,
                                       b: Double(v & 0xff) / 255, a: Double((v >> 24) & 0xff) / 255))
                    continue
                }
                if t.hasPrefix("#"), let c = hex(String(t.dropFirst())) { colors.append(c); continue }
                return nil
            }
        }
        return colors.isEmpty ? nil : BorderSpec(colors: colors, angle: angle)
    }

    private static func parseFunction(_ inner: String) -> RGBA? {
        if inner.contains(",") {
            let parts = inner.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 3 else { return nil }
            return RGBA(r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255, a: parts.count > 3 ? parts[3] : 1)
        }
        return hex(inner)
    }

    private static func hex(_ s: String) -> RGBA? {
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return RGBA(r: Double((v >> 16) & 0xff) / 255, g: Double((v >> 8) & 0xff) / 255, b: Double(v & 0xff) / 255, a: 1)
        }
        return RGBA(r: Double((v >> 24) & 0xff) / 255, g: Double((v >> 16) & 0xff) / 255,
                    b: Double((v >> 8) & 0xff) / 255, a: Double(v & 0xff) / 255)
    }
}

final class TomlLines {
    var lines: [String]

    init(_ text: String) { lines = text.components(separatedBy: "\n") }
    var text: String { lines.joined(separator: "\n") }

    static func isHeader(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && (t.hasSuffix("]") || t.contains("] #"))
    }

    static func headerName(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard isHeader(t) else { return nil }
        var s = t
        if let hash = s.range(of: " #") { s = String(s[..<hash.lowerBound]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return s
    }

    /// Range of lines belonging to a single `[name]` table (header excluded), or nil.
    func tableRange(_ name: String) -> (header: Int, end: Int)? {
        guard let h = lines.firstIndex(where: { TomlLines.headerName($0) == name && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[[") }) else { return nil }
        var e = h + 1
        while e < lines.count && !TomlLines.isHeader(lines[e]) { e += 1 }
        return (h, e)
    }

    func get(_ table: String, _ key: String) -> String? {
        guard let r = tableRange(table) else { return nil }
        for i in (r.header + 1)..<r.end {
            let parts = lines[i].split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Set `key = value` inside `[table]`; creates the table (after `after`, or at the end) when missing.
    func set(_ table: String, _ key: String, _ value: String, createAfter after: String? = nil) {
        if tableRange(table) == nil { createTable(table, after: after) }
        guard let r = tableRange(table) else { return }
        for i in (r.header + 1)..<r.end {
            let parts = lines[i].split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                lines[i] = "\(key) = \(value)"
                return
            }
        }
        // Insert keeping the table's keys contiguous: after the last key line of the table.
        var insertAt = r.header + 1
        for i in (r.header + 1)..<r.end where lines[i].contains("=") { insertAt = i + 1 }
        lines.insert("\(key) = \(value)", at: insertAt)
    }

    func createTable(_ table: String, after: String?) {
        var insertAt = lines.count
        if let a = after, let r = tableRange(a) {
            insertAt = r.end
            // Also skip the after-table's own subtables (e.g. [borders.color] when creating after [borders]).
            while insertAt < lines.count, let n = TomlLines.headerName(lines[insertAt]), n.hasPrefix(a + ".") {
                var e = insertAt + 1
                while e < lines.count && !TomlLines.isHeader(lines[e]) { e += 1 }
                insertAt = e
            }
        }
        lines.insert("[\(table)]", at: insertAt)
    }

    func removeTable(_ table: String) {
        guard let r = tableRange(table) else { return }
        lines.removeSubrange(r.header..<r.end)
    }

    /// Replace a table's key lines entirely.
    func replaceTable(_ table: String, with body: [String], createAfter after: String?) {
        if tableRange(table) == nil { createTable(table, after: after) }
        guard let r = tableRange(table) else { return }
        lines.replaceSubrange((r.header + 1)..<r.end, with: body)
    }

    /// The `[[workspaces]]` blocks, each with its trailing `[workspaces.*]` subtables.
    func workspaceBlocks() -> [(start: Int, end: Int)] {
        var blocks: [(Int, Int)] = []
        var i = 0
        while i < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "[[workspaces]]" {
                var e = i + 1
                while e < lines.count {
                    if let n = TomlLines.headerName(lines[e]) {
                        let isSub = n.hasPrefix("workspaces.") && !lines[e].trimmingCharacters(in: .whitespaces).hasPrefix("[[")
                        if !isSub { break }
                    }
                    e += 1
                }
                blocks.append((i, e))
                i = e
            } else { i += 1 }
        }
        return blocks
    }
}

enum OmniSettings {
    static func modifierName(_ m: MacMods) -> String? {
        var parts: [String] = []
        if m.contains(.control) { parts.append("control") }
        if m.contains(.option) { parts.append("option") }
        if m.contains(.command) { parts.append("command") }
        if m.contains(.shift) { parts.append("shift") }
        guard let first = parts.first else { return nil }
        return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// Hyprland's gaps_out: one value, or top, right, bottom, left (two or three values work like CSS).
    static func parseGapsOut(_ text: String) -> (top: Double, right: Double, bottom: Double, left: Double)? {
        let n = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.map { max(0, $0) }
        switch n.count {
        case 1: return (n[0], n[0], n[0], n[0])
        case 2: return (n[0], n[1], n[0], n[1])
        case 3: return (n[0], n[1], n[2], n[1])
        case 4...: return (n[0], n[1], n[2], n[3])
        default: return nil
        }
    }

    /// OmniWM skips a settings change that lands while it is still starting, and then keeps IPC off.
    /// If it is running but not answering a few seconds after we wrote its settings, restart it once.
    static func ensureOmniWMPickedUp() {
        let bundle = "com.barut.OmniWM"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return }
        for _ in 0..<10 {
            if Dispatchers.omniwmctl(["ping"], quiet: true).ok { return }
            usleep(500_000)
        }
        Log.write("OmniWM missed the new settings; restarting it")
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
        for i in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { break }
            if i == 20 { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.forceTerminate() } }
            usleep(250_000)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", bundle]
        try? open.run()
        open.waitUntilExit()
    }

    static func menuBarHeight() -> Double {
        guard let s = NSScreen.screens.first else { return 24 }
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 0 ? Double(h) : 0
    }

    /// Apply the config to OmniWM's settings. Returns a short summary of what changed, or nil when nothing did.
    @discardableResult
    static func apply(_ config: HyprConfig) -> String? {
        let path = Paths.omniSettings
        guard let original = try? String(contentsOfFile: path, encoding: .utf8) else {
            Log.write("OmniWM settings not found at \(path); start OmniWM once first")
            return nil
        }
        let t = TomlLines(original)
        func num(_ v: Double) -> String { v == v.rounded() ? String(format: "%.1f", v) : String(v) }

        // HyprMac owns the keyboard; OmniWM's own shortcuts would double-fire.
        t.set("general", "hotkeysEnabled", "false")
        t.set("general", "ipcEnabled", "true")

        // Gaps: the config's, none on the laptop screen alone when `hyprmac:laptop_gaps = false`,
        // or the recording stage while record mode is on (which also hides the border).
        var gapsIn = config.double("general:gaps_in")
        var gapsOut = config.setting("general:gaps_out").flatMap(parseGapsOut)
        if config.bool("hyprmac:laptop_gaps") == false && Screens.laptopOnly() {
            gapsIn = 0
            gapsOut = (0, 0, 0, 0)
        }
        let stage = Modes.recordGaps()
        if let gin = stage == nil ? gapsIn : 0 {
            t.set("gaps", "size", num(min(64, max(0, gin * 2))))
        }
        if let stage {
            // Already in OmniWM's terms (top gap measured from the screen's top edge).
            t.set("gaps.outer", "top", num(stage.top))
            t.set("gaps.outer", "right", num(stage.right))
            t.set("gaps.outer", "bottom", num(stage.bottom))
            t.set("gaps.outer", "left", num(stage.left))
        } else if let g = gapsOut {
            t.set("gaps.outer", "left", num(g.left))
            t.set("gaps.outer", "right", num(g.right))
            t.set("gaps.outer", "bottom", num(g.bottom))
            // OmniWM measures the top gap from the screen edge and subtracts the menu bar first.
            t.set("gaps.outer", "top", num(g.top + menuBarHeight()))
        }
        // A lone window keeps the gaps, as in Hyprland (OmniWM's "fill" would stretch it over them, and off
        // the recording stage). A size bigger than any screen means "fill the gapped area".
        t.set("dwindle", "singleWindowFit", "\"100000x100000\"")
        t.set("niri", "singleWindowFit", "\"100000x100000\"")
        if stage != nil {
            t.set("borders", "enabled", "false")
        } else if let bs = config.double("general:border_size") {
            t.set("borders", "enabled", bs > 0 ? "true" : "false")
            if bs > 0 { t.set("borders", "width", num(min(12, max(1, bs)))) }
        }
        if let colorText = config.setting("general:col.active_border"), let spec = ColorParser.parse(colorText) {
            t.replaceTable("borders.color", with: spec.colors[0].tomlLines, createAfter: "borders")
            t.removeTable("borders.darkColor")
            if spec.colors.count >= 2 {
                let a = (spec.angle ?? 45).truncatingRemainder(dividingBy: 360)
                let norm = a < 0 ? a + 360 : a
                let dir = (norm < 90 || (norm >= 180 && norm < 270)) ? "topLeftToBottomRight" : "topRightToBottomLeft"
                t.replaceTable("borders.gradient", with: ["direction = \"\(dir)\"", "enabled = true"], createAfter: "borders.color")
                t.replaceTable("borders.gradient.end", with: spec.colors[spec.colors.count - 1].tomlLines, createAfter: "borders.gradient")
                t.replaceTable("borders.gradient.start", with: spec.colors[0].tomlLines, createAfter: "borders.gradient")
            } else {
                t.removeTable("borders.gradient.start")
                t.removeTable("borders.gradient.end")
                t.removeTable("borders.gradient.dark.start")
                t.removeTable("borders.gradient.dark.end")
                t.removeTable("borders.gradient.dark")
                t.removeTable("borders.gradient")
            }
        }
        if let layout = config.setting("general:layout")?.lowercased() {
            t.set("general", "defaultLayoutType", (layout == "scrolling" || layout == "niri" || layout == "scroller") ? "\"niri\"" : "\"dwindle\"")
        }
        if let anim = config.bool("animations:enabled") {
            t.set("general", "animationsEnabled", anim ? "true" : "false")
        }
        if let speed = config.double("animations:speed") {
            t.set("general", "animationSpeed", num(min(4, max(0.25, speed))))
        }
        if let fm = config.setting("input:follow_mouse") {
            t.set("focus", "followsMouse", (fm == "0" || fm.lowercased() == "false") ? "false" : "true")
        }
        if let m = config.double("dwindle:split_width_multiplier") { t.set("dwindle", "splitWidthMultiplier", num(m)) }
        if let s = config.bool("dwindle:smart_split") { t.set("dwindle", "smartSplit", s ? "true" : "false") }
        if let r = config.double("dwindle:default_split_ratio") { t.set("dwindle", "defaultSplitRatio", num(min(1.9, max(0.1, r)))) }

        // bindm = MODS, mouse:272, movewindow / mouse:273, resizewindow -> OmniWM drag modifiers.
        for b in config.binds where b.submap.isEmpty {
            guard case .mouse(let button) = b.key, let name = modifierName(b.mods.resolve(superIs: Settings.superIs)) else { continue }
            if button == 272 { t.set("gestures", "mouseMoveModifierKey", "\"\(name)\"") }
            if button == 273 { t.set("gestures", "mouseResizeModifierKey", "\"\(name)\"") }
        }

        applyWorkspaces(config, t)

        let updated = t.text
        guard updated != original else { return nil }
        let backup = path + ".hyprmac-backup"
        if !FileManager.default.fileExists(atPath: backup) {
            try? original.write(toFile: backup, atomically: true, encoding: .utf8)
        }
        do {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            Log.write("updated OmniWM settings")
            return "OmniWM settings updated"
        } catch {
            Log.write("could not write OmniWM settings: \(error)")
            return nil
        }
    }

    /// Workspace rules: make sure each listed workspace exists with its monitor and layout. Workspaces the
    /// config does not mention keep whatever OmniWM has, except that the per-workspace layout is reset to
    /// follow `general:layout` so one setting controls them all.
    private static func applyWorkspaces(_ config: HyprConfig, _ t: TomlLines) {
        let hasLayout = config.setting("general:layout") != nil
        var rules: [Int: WorkspaceRule] = [:]
        for r in config.workspaces { rules[r.number] = r }

        var existing: [Int: (start: Int, end: Int)] = [:]
        for block in t.workspaceBlocks() {
            for i in block.start..<block.end {
                let parts = t.lines[i].split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "name",
                   let n = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))) {
                    existing[n] = block
                }
            }
        }

        // Rewrite matching blocks bottom-up so earlier indices stay valid.
        for (n, block) in existing.sorted(by: { $0.value.start > $1.value.start }) {
            let rule = rules[n]
            guard rule != nil || hasLayout else { continue }
            var id = UUID().uuidString
            var monitorType = "main"
            var displayName: String?
            var current = "main"
            for i in block.start..<block.end {
                let parts = t.lines[i].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "id" { id = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                if parts[0] == "type" { current = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                if parts[0] == "displayName" { displayName = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            monitorType = current
            var layoutType = "default"
            var keepSpecific = false
            if let r = rule {
                if let m = r.monitor?.lowercased(), ["main", "secondary", "tertiary"].contains(m) { monitorType = m }
                else if r.monitor == nil && current == "specificDisplay" { keepSpecific = true }
                if let l = r.layout { layoutType = (l == "scrolling" || l == "niri") ? "niri" : "dwindle" }
                displayName = r.name
            } else if current == "specificDisplay" {
                keepSpecific = true
            }
            if keepSpecific {
                // Leave a display-specific assignment exactly as OmniWM stored it; only the layout changes.
                for i in block.start..<block.end where t.lines[i].hasPrefix("layoutType") {
                    t.lines[i] = "layoutType = \"\(layoutType)\""
                }
                continue
            }
            var body = ["[[workspaces]]"]
            if let d = displayName, !d.isEmpty { body.append("displayName = \"\(d)\"") }
            body += ["id = \"\(id)\"", "layoutType = \"\(layoutType)\"", "name = \"\(n)\"",
                     "[workspaces.monitorAssignment]", "type = \"\(monitorType)\""]
            t.lines.replaceSubrange(block.start..<block.end, with: body)
        }

        // Create workspaces the config names that OmniWM does not have yet.
        let missing = rules.keys.filter { existing[$0] == nil }.sorted()
        guard !missing.isEmpty else { return }
        let blocks = t.workspaceBlocks()
        let insertAt = blocks.last?.end ?? t.lines.count
        var added: [String] = []
        for n in missing {
            let r = rules[n]!
            let monitor = r.monitor.map { $0.lowercased() }.flatMap { ["main", "secondary", "tertiary"].contains($0) ? $0 : nil } ?? "main"
            let layout = r.layout.map { ($0 == "scrolling" || $0 == "niri") ? "niri" : "dwindle" } ?? "default"
            added.append("[[workspaces]]")
            if let d = r.name, !d.isEmpty { added.append("displayName = \"\(d)\"") }
            added += ["id = \"\(UUID().uuidString)\"", "layoutType = \"\(layout)\"", "name = \"\(n)\"",
                      "[workspaces.monitorAssignment]", "type = \"\(monitor)\""]
        }
        t.lines.insert(contentsOf: added, at: insertAt)
    }
}
