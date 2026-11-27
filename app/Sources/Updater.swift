import Foundation
import Security

/// Updates for the downloaded, signed app. A build from source is signed by a local certificate that has no Apple team,
/// so it never offers or installs one. The only trust anchor is the signature: an update installs only when its code
/// signature is a Developer ID of the same Apple team as the running app, for the same bundle id, Apple notarized, and a
/// newer version. See docs/RELEASING.md.
enum Updater {
    static let repo = "hunterbohm/hyprmac"
    static let bundleID = "com.hunterbohm.hyprmac"
    static let availableFile = Paths.stateDir + "/update-available"
    static let notifiedFile = Paths.stateDir + "/update-notified"
    private static let maxArchiveBytes: Int64 = 200 << 20

    // MARK: Versions

    struct Version: Comparable, Equatable {
        let parts: [Int]
        /// "0.2.0" or "v0.2.0": three numbers, nothing else.
        init?(_ text: String) {
            let body = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count == 3 else { return nil }
            var numbers: [Int] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(piece) else { return nil }
                numbers.append(n)
            }
            parts = numbers
        }
        var text: String { parts.map(String.init).joined(separator: ".") }
        var tag: String { "v" + text }
        static func < (a: Version, b: Version) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    }

    /// The download is always built from the tag, never from a URL the feed supplies.
    struct Release {
        let version: Version
        var zipURL: URL {
            URL(string: "https://github.com/\(repo)/releases/download/\(version.tag)/HyprMac-\(version.tag).zip")!
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case network(String)
        case feed
        case archive(String)
        case identity(String)
        case version(String)
        case signature(String)
        case gatekeeper(String)
        case installer(Int32)

        var description: String {
            switch self {
            case .network(let why): "could not reach GitHub: \(why)"
            case .feed: "GitHub's latest release did not name a version"
            case .archive(let why): "the download is not a usable app: \(why)"
            case .identity(let id): "the downloaded app is \(id), not HyprMac"
            case .version(let why): why
            case .signature(let why): "the downloaded app is not signed by this app's developer: \(why)"
            case .gatekeeper(let why): "macOS would not open the downloaded app (not notarized?): \(why)"
            case .installer(let code): "the installer inside the update stopped with exit code \(code)"
            }
        }
    }

    // MARK: Who this copy is

    static var currentVersion: Version? { Version(hyprmacVersion) }

    /// The Apple team this copy is signed by, only when it is a Developer ID signature for HyprMac. Nil for a source
    /// build (local certificate, no team) or an unsigned one: those do not update themselves.
    static func ownTeamID() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, isTeamID(team) else { return nil }
        guard (try? check(code, team: team)) != nil else { return nil }
        return team
    }

    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Issued through Apple's Developer ID chain, to this team, for this bundle id. macOS keys the Accessibility switch
    /// to the same requirement, so an update that meets it keeps the switch.
    static func requirement(team: String) -> String {
        "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }

    private static func check(_ code: SecStaticCode, team: String) throws {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(Self.requirement(team: team) as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure.signature("the requirement did not compile")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        if status != errSecSuccess {
            let why = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "status \(status)"
            throw Failure.signature(why)
        }
    }

    // MARK: Looking for an update

    /// The newest release GitHub lists, or nil when it is not newer than this copy.
    static func newer() throws -> Release? {
        guard let current = currentVersion else { throw Failure.version("this copy has no version") }
        let latest = try latestRelease()
        return latest.version > current ? latest : nil
    }

    static func latestRelease() throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("HyprMac/\(hyprmacVersion)", forHTTPHeaderField: "User-Agent")
        let data = try fetch(request)
        guard data.count < 1 << 20,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["draft"] as? Bool) != true, (object["prerelease"] as? Bool) != true,
              let tag = object["tag_name"] as? String, tag.hasPrefix("v"), let version = Version(tag) else { throw Failure.feed }
        return Release(version: version)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ request: URLRequest) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Failure> = .failure(.network("no answer"))
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(.network(error.localizedDescription)) }
            else if (response as? HTTPURLResponse)?.statusCode == 200, let data { result = .success(data) }
            else { result = .failure(.network("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private static func download(_ url: URL, to file: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Failure> = .failure(.network("no answer"))
        session.downloadTask(with: url) { temporary, response, error in
            defer { done.signal() }
            if let error { result = .failure(.network(error.localizedDescription)); return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let temporary else {
                result = .failure(.network("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")); return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
            guard size > 0, size <= maxArchiveBytes else { result = .failure(.archive("it is \(size) bytes")); return }
            do { try FileManager.default.moveItem(at: temporary, to: file); result = .success(()) }
            catch { result = .failure(.archive(error.localizedDescription)) }
        }.resume()
        done.wait()
        try result.get()
    }

    // MARK: Checking and installing a download

    /// Unzips `archive` into `folder` and returns the app inside only if every check passes: it is HyprMac at exactly
    /// `expected`, newer than `minimum` when one is given, signed by `team` through Apple's Developer ID chain, and accepted
    /// by Gatekeeper as notarized.
    @discardableResult
    static func verify(archive: URL, in folder: URL, team: String, expected: Version, newerThan minimum: Version?) throws -> URL {
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) { code, _ in Failure.archive("unzip stopped with exit code \(code)") }
        let app = folder.appendingPathComponent("HyprMac.app")
        let installer = app.appendingPathComponent("Contents/Resources/install.sh")
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/hyprmac").path),
              FileManager.default.fileExists(atPath: installer.path) else { throw Failure.archive("HyprMac.app or its installer is missing") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let id = info?["CFBundleIdentifier"] as? String, id == bundleID else {
            throw Failure.identity((info?["CFBundleIdentifier"] as? String) ?? "something else")
        }
        guard let versionText = info?["CFBundleShortVersionString"] as? String, let version = Version(versionText), version == expected else {
            throw Failure.version("the downloaded app says it is \((info?["CFBundleShortVersionString"] as? String) ?? "unversioned"), not \(expected.text)")
        }
        if let minimum, version <= minimum { throw Failure.version("\(version.text) is not newer than \(minimum.text)") }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.signature("unreadable signature") }
        try check(code, team: team)
        let (status, output) = capture("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        guard status == 0, output.contains("Notarized Developer ID") else {
            throw Failure.gatekeeper(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return app
    }

    /// `hyprctl update`: look, download, verify, install. `checkOnly` stops after looking.
    static func command(checkOnly: Bool) -> Int32 {
        guard let team = ownTeamID() else {
            print("This copy of HyprMac was built from source, so it does not update itself. Pull the repo and run ./install.sh,")
            print("or install a signed release from https://github.com/\(repo)/releases.")
            return 0
        }
        guard let current = currentVersion else { print("This copy has no version number."); return 1 }
        do {
            let latest = try latestRelease()
            guard latest.version > current else {
                try? FileManager.default.removeItem(atPath: availableFile)
                print("HyprMac \(current.text) is the latest.")
                return 0
            }
            if checkOnly {
                print("HyprMac \(latest.version.text) is available (you have \(current.text)). Run: hyprctl update")
                return 0
            }
            print("Downloading HyprMac \(latest.version.text)…")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let archive = folder.appendingPathComponent("update.zip")
            try download(latest.zipURL, to: archive)
            let extracted = folder.appendingPathComponent("app")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
            let app = try verify(archive: archive, in: extracted, team: team, expected: latest.version, newerThan: current)
            print("Signed by your copy's developer and notarized. Installing…")
            let status = try runInherited("/bin/bash", [app.appendingPathComponent("Contents/Resources/install.sh").path, "--no-wait"])
            guard status == 0 else { throw Failure.installer(status) }
            try? FileManager.default.removeItem(atPath: availableFile)
            Log.write("updated HyprMac \(current.text) -> \(latest.version.text)")
            print("HyprMac \(latest.version.text) is installed.")
            return 0
        } catch {
            print("Update not installed: \(error)")
            Log.write("update failed: \(error)")
            return 1
        }
    }

    /// `hyprmac update --verify ZIP vX.Y.Z`: runs a release zip through the same checks, without installing. The release
    /// script uses it so no zip ships that this app would refuse.
    static func verifyCommand(zip: String, tag: String) -> Int32 {
        guard let team = ownTeamID() else { print("This copy is not a Developer ID build."); return 1 }
        guard let expected = Version(tag) else { print("Not a version: \(tag)"); return 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hyprmac-verify-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            try verify(archive: URL(fileURLWithPath: zip), in: folder, team: team, expected: expected, newerThan: nil)
            print("ok: \(zip) passes the update checks for team \(team)")
            return 0
        } catch {
            print("refused: \(error)")
            return 1
        }
    }

    // MARK: Daemon: look once a day

    private static var timer: DispatchSourceTimer?

    /// Checks about a minute after launch and then daily. `enabled` is asked each time, so the config can switch it off;
    /// `notify` runs once per new version.
    static func startChecking(enabled: @escaping () -> Bool, notify: @escaping (Version) -> Void) {
        guard ownTeamID() != nil else { Log.write("updates: off (built from source)"); return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hyprmac.update", qos: .utility))
        source.schedule(deadline: .now() + 60, repeating: .seconds(24 * 60 * 60), leeway: .seconds(5 * 60))
        source.setEventHandler {
            guard enabled() else { return }
            do {
                guard let release = try newer() else { try? FileManager.default.removeItem(atPath: availableFile); return }
                try? release.version.text.write(toFile: availableFile, atomically: true, encoding: .utf8)
                let told = try? String(contentsOfFile: notifiedFile, encoding: .utf8)
                guard told != release.version.text else { return }
                try? release.version.text.write(toFile: notifiedFile, atomically: true, encoding: .utf8)
                Log.write("update available: HyprMac \(release.version.text)")
                notify(release.version)
            } catch {
                Log.write("update check failed: \(error)")
            }
        }
        source.resume()
        timer = source
    }

    /// For `hyprctl status`: the version the daemon last found, if it is still newer than this copy.
    static func pending() -> Version? {
        guard let text = try? String(contentsOfFile: availableFile, encoding: .utf8), let found = Version(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let current = currentVersion, found > current else { return nil }
        return found
    }

    // MARK: Processes

    private static func run(_ path: String, _ arguments: [String], failure: (Int32, String) -> Failure) throws {
        let (status, output) = capture(path, arguments)
        if status != 0 { throw failure(status, output) }
    }

    private static func capture(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func runInherited(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
