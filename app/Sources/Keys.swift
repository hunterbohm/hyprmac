import Foundation
import CoreGraphics

// Modifiers as written in hyprland.conf. SUPER and ALT are resolved to Mac keys by physical position:
// a PC keyboard reads Ctrl, Super, Alt, Space; a Mac keyboard reads Control, Option, Command, Space.
// So by default SUPER is Option and ALT is Command. OPTION, COMMAND and CONTROL name Mac keys directly.
struct Mods: Hashable {
    var superKey = false
    var alt = false
    var ctrl = false
    var shift = false
    var option = false
    var command = false

    static func parse(_ text: String) -> Mods? {
        var m = Mods()
        let tokens = text.uppercased()
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        for token in tokens {
            switch token {
            case "SUPER", "WIN", "LOGO", "MOD4", "META": m.superKey = true
            case "ALT", "MOD1": m.alt = true
            case "CTRL", "CONTROL": m.ctrl = true
            case "SHIFT": m.shift = true
            case "OPTION", "OPT": m.option = true
            case "COMMAND", "CMD": m.command = true
            case "HYPER": m.ctrl = true; m.option = true; m.command = true; m.shift = true
            default: return nil
            }
        }
        return m
    }

    /// Resolve to Mac modifier flags. `superIs` is "option", "command" or "control".
    func resolve(superIs: String) -> MacMods {
        var r = MacMods()
        if shift { r.insert(.shift) }
        if ctrl { r.insert(.control) }
        if option { r.insert(.option) }
        if command { r.insert(.command) }
        let superFlag: MacMods
        let altFlag: MacMods
        switch superIs {
        case "command": superFlag = .command; altFlag = .option
        case "control": superFlag = .control; altFlag = .option
        default: superFlag = .option; altFlag = .command
        }
        if superKey { r.insert(superFlag) }
        if alt { r.insert(altFlag) }
        return r
    }

    var label: String {
        var parts: [String] = []
        if superKey { parts.append("SUPER") }
        if ctrl { parts.append("CTRL") }
        if alt { parts.append("ALT") }
        if option { parts.append("OPTION") }
        if command { parts.append("COMMAND") }
        if shift { parts.append("SHIFT") }
        return parts.joined(separator: " ")
    }
}

struct MacMods: OptionSet, Hashable {
    let rawValue: UInt8
    static let shift = MacMods(rawValue: 1)
    static let control = MacMods(rawValue: 2)
    static let option = MacMods(rawValue: 4)
    static let command = MacMods(rawValue: 8)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(flags: CGEventFlags) {
        var r = MacMods()
        if flags.contains(.maskShift) { r.insert(.shift) }
        if flags.contains(.maskControl) { r.insert(.control) }
        if flags.contains(.maskAlternate) { r.insert(.option) }
        if flags.contains(.maskCommand) { r.insert(.command) }
        self = r
    }

    var cgFlags: CGEventFlags {
        var f = CGEventFlags()
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

enum Keys {
    // macOS virtual key codes (ANSI layout positions).
    static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
        "minus": 27, "8": 28, "0": 29, "bracketright": 30, "o": 31, "u": 32, "bracketleft": 33,
        "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "apostrophe": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46,
        "period": 47, "tab": 48, "space": 49, "grave": 50, "backspace": 51, "escape": 53,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105,
        "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113, "insert": 114, "home": 115,
        "prior": 116, "delete": 117, "f4": 118, "end": 119, "f2": 120, "next": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126, "kp_enter": 76,
    ]

    static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "page_up": "prior", "pageup": "prior",
        "page_down": "next", "pagedown": "next", "plus": "equal", "quote": "apostrophe",
        "backtick": "grave", "dead_grave": "grave", "print": "f13", "forwarddelete": "delete",
        "bracket_left": "bracketleft", "bracket_right": "bracketright",
        "leftbracket": "bracketleft", "rightbracket": "bracketright",
        "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
    ]

    // xkb keycodes (code:N in Hyprland) for the keys Hyprland configs actually use.
    static let xkb: [Int: String] = [
        9: "escape", 10: "1", 11: "2", 12: "3", 13: "4", 14: "5", 15: "6", 16: "7", 17: "8", 18: "9", 19: "0",
        20: "minus", 21: "equal", 22: "backspace", 23: "tab", 24: "q", 25: "w", 26: "e", 27: "r", 28: "t",
        29: "y", 30: "u", 31: "i", 32: "o", 33: "p", 34: "bracketleft", 35: "bracketright", 36: "return",
        38: "a", 39: "s", 40: "d", 41: "f", 42: "g", 43: "h", 44: "j", 45: "k", 46: "l", 47: "semicolon",
        48: "apostrophe", 49: "grave", 51: "backslash", 52: "z", 53: "x", 54: "c", 55: "v", 56: "b",
        57: "n", 58: "m", 59: "comma", 60: "period", 61: "slash", 65: "space",
    ]

    static func parse(_ text: String) -> KeySpec? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "mouse_down" { return .scrollDown }
        if t == "mouse_up" { return .scrollUp }
        if t.hasPrefix("mouse:"), let b = Int(t.dropFirst(6)) { return .mouse(b) }
        if t.hasPrefix("code:"), let n = Int(t.dropFirst(5)), let name = xkb[n], let c = table[name] { return .code(c) }
        let name = aliases[t] ?? t
        if let c = table[name] { return .code(c) }
        return nil
    }

    static func name(for code: UInt16) -> String {
        if let entry = table.first(where: { $0.value == code }) {
            let n = entry.key
            return n.count == 1 ? n.uppercased() : n
        }
        return "code \(code)"
    }
}
