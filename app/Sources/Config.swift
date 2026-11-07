import Foundation

// A parsed hyprland.conf: variables, settings sections, binds per submap, exec lines and workspace rules.

struct Bind {
    var mods: Mods
    var key: KeySpec
    var dispatcher: String
    var arg: String
    var repeats: Bool
    var description: String
    var submap: String
    var line: Int
}

enum KeySpec: Hashable {
    case code(UInt16)
    case mouse(Int)        // mouse:272 left, mouse:273 right (bindm)
    case scrollUp, scrollDown

    var label: String {
        switch self {
        case .code(let c): return Keys.name(for: c)
        case .mouse(let b): return "mouse:\(b)"
        case .scrollUp: return "mouse_up"
        case .scrollDown: return "mouse_down"
        }
    }
}

struct WorkspaceRule {
    var number: Int
    var monitor: String?   // main, secondary, tertiary, or a display name
    var layout: String?    // dwindle | scrolling
    var name: String?      // label shown in OmniWM's bar
}

struct ConfigError {
    var line: Int
    var message: String
}

final class HyprConfig {
    var path: String
    var variables: [String: String] = [:]
    var settings: [String: String] = [:]          // "general:gaps_in" -> "5"
    var binds: [Bind] = []
    var execOnce: [String] = []
    var exec: [String] = []
    var workspaces: [WorkspaceRule] = []
    var errors: [ConfigError] = []
    var sources: [String] = []

    init(path: String) {
        self.path = path
    }

    static func load(path: String) -> HyprConfig {
        let config = HyprConfig(path: path)
        config.parse(file: path, depth: 0)
        return config
    }

    func setting(_ key: String) -> String? { settings[key] }

    func bool(_ key: String) -> Bool? {
        guard let v = settings[key]?.lowercased() else { return nil }
        switch v {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        guard let v = settings[key] else { return nil }
        return Double(v)
    }

    private func parse(file: String, depth: Int) {
        guard depth < 8 else { return }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            if depth == 0 { errors.append(ConfigError(line: 0, message: "cannot read \(file)")) }
            else { errors.append(ConfigError(line: 0, message: "source not found: \(file)")) }
            return
        }
        sources.append(file)
        var sections: [String] = []
        var submap = ""
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            var line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Section open/close: `general {`, `}`. Allow `name {` and lone `{` on the same line only.
            if line == "}" {
                if sections.isEmpty { errors.append(ConfigError(line: lineNo, message: "unexpected }")) }
                else { sections.removeLast() }
                continue
            }
            if line.hasSuffix("{") {
                let name = line.dropLast().trimmingCharacters(in: .whitespaces)
                if name.isEmpty || name.contains("=") {
                    errors.append(ConfigError(line: lineNo, message: "bad section header"))
                } else {
                    sections.append(name.lowercased())
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                errors.append(ConfigError(line: lineNo, message: "expected key = value"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            // Variable definition
            if key.hasPrefix("$") {
                variables[String(key.dropFirst())] = expand(value)
                continue
            }
            value = expand(value)
            line = ""

            if !sections.isEmpty {
                let fullKey = (sections + [key]).joined(separator: ":")
                settings[fullKey.lowercased()] = value
                continue
            }

            let lowerKey = key.lowercased()
            switch lowerKey {
            case "source":
                let target = expandPath(value, relativeTo: file)
                parse(file: target, depth: depth + 1)
            case "exec-once":
                execOnce.append(value)
            case "exec":
                exec.append(value)
            case "submap":
                submap = (value.lowercased() == "reset") ? "" : value
            case "workspace":
                if let rule = parseWorkspace(value, line: lineNo) { workspaces.append(rule) }
            case "unbind":
                let parts = splitFields(value, max: 2)
                guard parts.count == 2, let mods = Mods.parse(parts[0]), let key = Keys.parse(parts[1]) else {
                    errors.append(ConfigError(line: lineNo, message: "bad unbind: \(value)"))
                    continue
                }
                binds.removeAll { $0.mods == mods && $0.key == key && $0.submap == submap }
            default:
                if lowerKey.hasPrefix("bind") {
                    let flags = String(lowerKey.dropFirst(4))
                    let allowed = Set("lrenmtidso")
                    if !flags.allSatisfy({ allowed.contains($0) }) {
                        errors.append(ConfigError(line: lineNo, message: "unknown bind flags '\(flags)'"))
                        continue
                    }
                    parseBind(value, flags: flags, submap: submap, line: lineNo)
                } else if lowerKey == "monitor" || lowerKey == "windowrule" || lowerKey == "windowrulev2" || lowerKey == "env" || lowerKey == "layerrule" {
                    // Accepted for compatibility with pasted Hyprland configs; macOS handles these itself.
                    continue
                } else {
                    // Top-level dotted settings such as `general:gaps_in = 5` are allowed too.
                    if lowerKey.contains(":") { settings[lowerKey] = value }
                    else { errors.append(ConfigError(line: lineNo, message: "unknown keyword '\(key)'")) }
                }
            }
        }
        if !sections.isEmpty {
            errors.append(ConfigError(line: lines.count, message: "missing } for section '\(sections.last!)'"))
        }
    }

    private func stripComment(_ line: String) -> String {
        // `#` starts a comment; `##` is a literal #. Colors like rgba(...) never contain #.
        var out = ""
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "#" {
                if i + 1 < chars.count && chars[i + 1] == "#" {
                    out.append("#"); i += 2; continue
                }
                break
            }
            out.append(chars[i]); i += 1
        }
        chars.removeAll()
        return out
    }

    func expand(_ value: String) -> String {
        guard value.contains("$") else { return value }
        var result = value
        // Longest names first so $terminal2 is not eaten by $terminal.
        for name in variables.keys.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: "$" + name, with: variables[name]!)
        }
        return result
    }

    private func expandPath(_ value: String, relativeTo file: String) -> String {
        var p = value
        if p.hasPrefix("~/") { p = FileManager.default.homeDirectoryForCurrentUser.path + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = (file as NSString).deletingLastPathComponent + "/" + p }
        return p
    }

    private func splitFields(_ value: String, max: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(value)
        while parts.count < max - 1, let comma = rest.firstIndex(of: ",") {
            parts.append(rest[..<comma].trimmingCharacters(in: .whitespaces))
            rest = rest[rest.index(after: comma)...]
        }
        parts.append(rest.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private func parseBind(_ value: String, flags: String, submap: String, line: Int) {
        let hasDescription = flags.contains("d")
        let fieldCount = hasDescription ? 5 : 4
        var parts = splitFields(value, max: fieldCount)
        if parts.count < fieldCount - 1 {
            errors.append(ConfigError(line: line, message: "bind needs: MODS, key, \(hasDescription ? "description, " : "")dispatcher[, args]"))
            return
        }
        while parts.count < fieldCount { parts.append("") }
        guard let mods = Mods.parse(parts[0]) else {
            errors.append(ConfigError(line: line, message: "unknown modifier in '\(parts[0])'"))
            return
        }
        guard let key = Keys.parse(parts[1]) else {
            errors.append(ConfigError(line: line, message: "unknown key '\(parts[1])'"))
            return
        }
        let description = hasDescription ? parts[2] : ""
        let dispatcher = parts[hasDescription ? 3 : 2].lowercased()
        let arg = parts[hasDescription ? 4 : 3]
        if flags.contains("m") {
            guard case .mouse = key else {
                errors.append(ConfigError(line: line, message: "bindm needs mouse:272 or mouse:273"))
                return
            }
        } else if !Dispatchers.known.contains(dispatcher) {
            errors.append(ConfigError(line: line, message: "unknown dispatcher '\(dispatcher)'"))
            return
        }
        // A later bind for the same chord replaces the earlier one, like Hyprland's last-wins behavior for our purposes.
        binds.removeAll { $0.mods == mods && $0.key == key && $0.submap == submap }
        binds.append(Bind(mods: mods, key: key, dispatcher: dispatcher, arg: arg,
                          repeats: flags.contains("e"), description: description,
                          submap: submap, line: line))
    }

    private func parseWorkspace(_ value: String, line: Int) -> WorkspaceRule? {
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let number = Int(first), number >= 1, number <= 99 else {
            errors.append(ConfigError(line: line, message: "workspace rules need a number from 1 to 99"))
            return nil
        }
        var rule = WorkspaceRule(number: number)
        for part in parts.dropFirst() {
            let kv = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "monitor": rule.monitor = kv[1]
            case "layout": rule.layout = kv[1].lowercased()
            case "name", "defaultname": rule.name = kv[1]
            default: break
            }
        }
        return rule
    }
}
