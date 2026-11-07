import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var configDir: String {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], x.hasPrefix("/") { return x + "/hyprmac" }
        return home + "/.config/hyprmac"
    }
    static var config: String { ProcessInfo.processInfo.environment["HYPRMAC_CONFIG"] ?? configDir + "/hyprland.conf" }
    static let stateDir = home + "/.local/state/hyprmac"
    static let log = stateDir + "/hyprmac.log"
    static let pidFile = stateDir + "/hyprmac.pid"
    static let execOnceStamp = stateDir + "/exec-once.boot"
    static let omniSettings: String = {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], x.hasPrefix("/") { return x + "/omniwm/settings.toml" }
        return home + "/.config/omniwm/settings.toml"
    }()
}

enum Settings {
    /// Which Mac key SUPER means: option (default), command or control.
    static var superIs = "option"
}

enum Log {
    private static let queue = DispatchQueue(label: "hyprmac.log")
    static var echo = false

    static func write(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        if echo { FileHandle.standardError.write(line.data(using: .utf8)!) }
        queue.async {
            try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.log),
               let size = attrs[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(atPath: Paths.log + ".1")
                try? FileManager.default.moveItem(atPath: Paths.log, toPath: Paths.log + ".1")
            }
            if let h = FileHandle(forWritingAtPath: Paths.log) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                FileManager.default.createFile(atPath: Paths.log, contents: line.data(using: .utf8))
            }
        }
    }

    /// A handle child processes may write their output to.
    static func handle() -> FileHandle? {
        try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Paths.log) { FileManager.default.createFile(atPath: Paths.log, contents: nil) }
        let h = FileHandle(forWritingAtPath: Paths.log)
        h?.seekToEndOfFile()
        return h
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

/// Seconds since boot identifier, used to run exec-once lines once per login session rather than per restart.
func bootSessionID() -> String {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &tv, &size, nil, 0)
    return "\(tv.tv_sec)-\(getuid())"
}
