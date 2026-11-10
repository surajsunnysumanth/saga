import Foundation

/// What the USB cable currently offers.
public enum PhoneStatus: Sendable, Equatable {
    case absent
    case unauthorised          // plugged in, but "Allow USB debugging?" was never accepted
    case connected(model: String, android: String)

    public var isConnected: Bool { if case .connected = self { return true }; return false }
    public var summary: String {
        switch self {
        case .absent: return "Disconnected"
        case .unauthorised: return "Blocked"
        case .connected: return "Connected"
        }
    }
}

/// ADB is the only route that works on a Mac without extra drivers, so the phone-facing
/// features all go through it: detection, pulling a fresh backup, and copying the media tree
/// so the archive can show pictures that live only on the device.
public enum PhoneLink {
    /// Where adb lives on a normal install, plus Homebrew's two prefixes.
    static var adbPath: String? {
        // The app-managed copy comes first. Setup downloads platform-tools into Application
        // Support, so a Mac with no Homebrew adb — a fresh install — has a working adb that this
        // list used to miss, which is why the phone read as absent and live pulls never ran.
        let candidates = [Adb.toolPath,
                          "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb",
                          (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/Library/Android/sdk/platform-tools/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    /// Quotes a path for the device's shell. `adb shell a b c` is reassembled into one command
    /// line on the phone, so an unquoted "WhatsApp Images" splits into two arguments and every
    /// lookup fails — which is exactly what happened before this.
    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func run(_ args: [String], timeout: TimeInterval = 10) -> (code: Int32, out: String) {
        guard let adb = adbPath else { return (127, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (126, "") }
        // Drain while it runs. A plain `adb shell ls` of the media tree exceeds the 64 KB pipe
        // buffer, and reading only after the wait deadlocks the child — which then looks like a
        // timeout and a bogus exit code.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    /// "device", "unauthorized", "offline" — one line from `adb devices`.
    public static func detect() -> PhoneStatus {
        guard adbPath != nil else { return .absent }
        let list = run(["devices"])
        let states = list.out.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2 else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        if states.contains("unauthorized") { return .unauthorised }
        guard states.contains("device") else { return .absent }

        let model = run(["shell", "getprop", "ro.product.model"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let android = run(["shell", "getprop", "ro.build.version.release"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .connected(model: model.isEmpty ? "Android phone" : model, android: android)
    }

    /// The memory card paths WhatsApp writes to on modern Android, newest first.
    static let mediaCandidates = [
        "/sdcard/Android/media/com.whatsapp/WhatsApp/Media",
        "/sdcard/WhatsApp/Media",
    ]

    /// Copies the phone's media tree into the app's support folder so the existing resolver
    /// can treat it as an ordinary local source. Files already present are skipped by size.
    public static func copyMedia(to destination: URL, progress: @Sendable (String) -> Void = { _ in }) throws -> Int {
        guard adbPath != nil else { throw PhoneError.noADB }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let source = mediaCandidates.first(where: { run(["shell", "ls " + quote($0)]).code == 0 }) else {
            throw PhoneError.noMedia
        }
        let before = fileCount(destination)
        progress("Copying photos and videos from the phone…")
        let result = run(["pull", source, destination.path], timeout: 60 * 60)
        guard result.code == 0 else { throw PhoneError.pullFailed(result.out) }
        let after = fileCount(destination)
        return max(0, after - before)
    }

    static func fileCount(_ url: URL) -> Int {
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var n = 0
        for case let f as URL in walk where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        return n
    }

    public enum PhoneError: LocalizedError {
        case noADB, noMedia, pullFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noADB: return "ADB isn't installed, so the phone can't be read over USB."
            case .noMedia: return "No WhatsApp media folder was found on the phone."
            case let .pullFailed(msg): return "The copy stopped: \(msg.split(separator: "\n").last ?? "unknown error")"
            }
        }
    }
}

extension PhoneLink {
    /// Set by the app's USB poll, so a media lookup can decide in a microsecond whether
    /// asking the phone is even possible.
    public nonisolated(unsafe) static var mediaFallbackEnabled = false
    private static let missingLock = NSLock()
    nonisolated(unsafe) private static var missing: Set<String> = []

    static let mediaSubfolders = ["WhatsApp Images", "WhatsApp Images/Sent",
                                  "WhatsApp Video", "WhatsApp Video/Sent",
                                  "WhatsApp Documents", "WhatsApp Documents/Sent",
                                  "WhatsApp Voice Notes", "WhatsApp Audio", "WhatsApp Animated Gifs",
                                  "WhatsApp Stickers"]

    /// New media usually exists only on the phone: Drive uploads lag, and the newest chats
    /// have not been backed up yet. Rather than copy gigabytes, fetch the one file the view
    /// asked for into a cache and hand back its local URL.
    public static func fetchMedia(named name: String, into cache: URL) -> URL? {
        guard mediaFallbackEnabled, adbPath != nil, !name.isEmpty else { return nil }
        missingLock.lock(); let knownMissing = missing.contains(name); missingLock.unlock()
        if knownMissing { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let target = cache.appendingPathComponent(safe)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        guard let root = mediaCandidates.first(where: { run(["shell", "ls " + quote($0)], timeout: 4).code == 0 }) else { return nil }
        for sub in mediaSubfolders {
            let remote = "\(root)/\(sub)/\(name)"
            guard run(["shell", "test -f " + quote(remote)], timeout: 4).code == 0 else { continue }
            let p = Process()
            guard let adb = adbPath else { return nil }
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = ["exec-out", "cat " + quote(remote)]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, !data.isEmpty else { continue }
            do { try data.write(to: target) } catch { return nil }
            return target
        }
        missingLock.lock(); missing.insert(name); missingLock.unlock()
        return nil
    }

    public static var mediaCache: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saga/phone-media-cache")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
