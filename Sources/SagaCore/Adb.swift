import Foundation

public enum AdbState: Equatable, Sendable {
    case noTool, noDevice, unauthorized, ready(model: String)
}

public struct BackupInfo: Equatable, Sendable {
    public let package: String, path: String, lastBackup: String?   // lastBackup: device-local "yyyy-MM-dd HH:mm"
}

/// Talks to a USB-connected Android phone through `adb`. Downloads Google's platform-tools on first use if adb isn't installed.
public enum Adb {
    public static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Saga")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var toolPath: String { supportDir.appendingPathComponent("platform-tools/adb").path }

    public static func locate() -> String? {
        let fm = FileManager.default
        for p in [toolPath, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"] where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Run a process off the main thread; returns (exit code, stdout).
    @discardableResult
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 600) async -> (Int32, String) {
        await Task.detached { () -> (Int32, String) in
            // stdout goes to a temp file, not a pipe: `adb start-server` forks a daemon that would hold a pipe open forever
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-\(UUID().uuidString).out")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let fh = try? FileHandle(forWritingTo: tmp) else { return (-1, "") }
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            p.standardOutput = fh; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, "") }
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            try? fh.close()
            return (p.terminationStatus, (try? String(contentsOf: tmp, encoding: .utf8)) ?? "")
        }.value
    }

    /// Download Google's platform-tools (~15 MB) into Application Support.
    public static func downloadTools() async throws {
        let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw SQLiteError.open("download failed") }
        let zip = supportDir.appendingPathComponent("platform-tools.zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: tmp, to: zip)
        let (code, _) = await run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", supportDir.path])
        try? FileManager.default.removeItem(at: zip)
        guard code == 0, locate() != nil else { throw SQLiteError.open("could not unpack platform-tools") }
    }

    public static func state() async -> AdbState {
        guard let adb = locate() else { return .noTool }
        _ = await run(adb, ["start-server"], timeout: 20)
        let (_, out) = await run(adb, ["devices", "-l"], timeout: 20)
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 2 else { continue }
            if f[1] == "unauthorized" { return .unauthorized }
            if f[1] == "device" {
                let model = f.first(where: { $0.hasPrefix("model:") })?.dropFirst(6).replacingOccurrences(of: "_", with: " ") ?? "Android phone"
                return .ready(model: model)
            }
        }
        return .noDevice
    }

    /// Finds WhatsApp (or WhatsApp Business) backup data on the phone.
    public static func backupInfo() async -> BackupInfo? {
        guard let adb = locate() else { return nil }
        for pkg in ["com.whatsapp", "com.whatsapp.w4b"] {
            let folder = pkg == "com.whatsapp" ? "WhatsApp" : "WhatsApp Business"
            let dir = "/sdcard/Android/media/\(pkg)/\(folder)/Databases"
            let (_, out) = await run(adb, ["shell", "ls", "-l", "'\(dir)'"], timeout: 30)
            for line in out.split(separator: "\n") where line.hasSuffix(" msgstore.db.crypt15") {
                let f = line.split(separator: " ").map(String.init)
                // -rw-rw---- 1 u0_a330 media_rw 183757082 2026-11-03 05:18 msgstore.db.crypt15
                let date = f.count >= 8 ? "\(f[f.count - 3]) \(f[f.count - 2])" : nil
                return BackupInfo(package: pkg, path: dir, lastBackup: date)
            }
        }
        return nil
    }

    public static func pullDatabases(from info: BackupInfo, to dest: URL) async -> Bool {
        guard let adb = locate() else { return false }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let (code, _) = await run(adb, ["pull", info.path + "/.", dest.path], timeout: 900)
        return code == 0 && FileManager.default.fileExists(atPath: dest.appendingPathComponent("msgstore.db.crypt15").path)
    }

    /// Contact names stored on the phone (no root needed): [normalised phone: name].
    public static func phoneContacts() async -> [String: String] {
        guard let adb = locate() else { return [:] }
        let (_, out) = await run(adb, ["shell", "content", "query", "--uri", "content://com.android.contacts/data/phones",
                                       "--projection", "display_name:data1"], timeout: 120)
        var names: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let a = line.range(of: " display_name="), let b = line.range(of: ", data1=", options: .backwards), a.upperBound <= b.lowerBound else { continue }
            let name = String(line[a.upperBound..<b.lowerBound]), n = normalizePhone(String(line[b.upperBound...]))
            if !name.isEmpty, !n.isEmpty, names[n] == nil { names[n] = name }
        }
        return names
    }
}
