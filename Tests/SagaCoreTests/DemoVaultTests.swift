import XCTest
import ImageIO
import CryptoKit
import CoreGraphics
import UniformTypeIdentifiers
@testable import SagaCore

final class DemoVaultTests: XCTestCase {
    func testDemoLaunchRequiresExplicitSyntheticFixtureAndNeverFallsBack() throws {
        XCTAssertNil(try DemoVault.launchDirectory(arguments: []))
        XCTAssertThrowsError(try DemoVault.launchDirectory(arguments: ["--demo"]))
        XCTAssertThrowsError(try DemoVault.launchDirectory(arguments: ["--demo", "--snapshot"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try DemoVault.launchDirectory(arguments: ["--demo", root.path]))
        try DemoVault.generate(at: root)
        XCTAssertEqual(try DemoVault.launchDirectory(arguments: ["--demo", root.path]), root.standardizedFileURL)
    }

    func testDemoIndexIsRecognizedSoArtifactsNeverEmbedTheMacAccountName() throws {
        XCTAssertFalse(DemoVault.isSyntheticDemo(indexURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope.db")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-synth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoVault.generate(at: root)
        XCTAssertTrue(DemoVault.isSyntheticDemo(indexURL: root.appendingPathComponent("vault_index.db")))
    }

    /// The archive Wrapped, Music and On This Day need: enough volume, enough people, enough
    /// years, and the features those screens read (laughs, quotes, links, media, merges).
    func testDemoBuildsRichBrowsableRebuildableSyntheticArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let result = try DemoVault.generate(at: root)
        let elapsed = Date().timeIntervalSince(started)

        // Roughly 20k messages over three years, 15 chat records, 14 conversations after a merge.
        XCTAssertEqual(result.messages, 20_600)
        XCTAssertEqual(result.chats, 15)
        XCTAssertEqual(result.namedPeople, 22)
        XCTAssertGreaterThan(elapsed, 0)
        // A wall-clock budget on shared CI hardware measures the runner, not the code: this test
        // failed at 10.4 s on GitHub's VM while passing in 2 s here. Keep a generous ceiling that
        // still catches a real regression (an order of magnitude), not machine speed.
        XCTAssertLessThan(elapsed, 60, "generating the demo must not regress by an order of magnitude")

        let vault = try Vault(url: root.appendingPathComponent("vault"), create: false)
        XCTAssertEqual(vault.segmentFiles().count, 1)
        let index = try SQLiteDB(path: root.appendingPathComponent("vault_index.db").path, readOnly: true)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM messages"), 20_600)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM chats"), 14)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM chats WHERE is_group=1"), 10)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM chats WHERE is_group=0"), 4)

        // One group carries about a third of everything.
        let busiest = try index.scalarInt("SELECT max(n) FROM chat_stats")
        XCTAssertGreaterThan(busiest, 5_500)
        XCTAssertLessThan(Double(busiest) / 20_600.0, 0.35)

        // Three years, a quiet year, a quiet month, and a real silence inside the main chat.
        let firstTs = try index.scalarInt("SELECT min(ts) FROM messages")
        let lastTs = try index.scalarInt("SELECT max(ts) FROM messages")
        let spanDays = Int((lastTs - firstTs) / 86_400_000)
        XCTAssertGreaterThan(spanDays, 1_050)
        XCTAssertLessThan(spanDays, 1_150)
        let quietYear = try index.scalarInt("SELECT count(*) FROM messages WHERE ts >= 1704067200000 AND ts < 1735689600000")
        XCTAssertLessThan(quietYear, 2_200, "2024 is deliberately the quiet year")
        let quietMonth = try index.scalarInt("SELECT count(*) FROM messages WHERE strftime('%Y-%m', ts/1000, 'unixepoch') = '2026-06'")
        XCTAssertLessThan(quietMonth, 300, "June 2026 is deliberately quiet")

        // Music and video: real public links the app parses, spread across services.
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM messages WHERE text LIKE '%open.spotify.com/%'"), 25)
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM messages WHERE text LIKE '%youtu%'"), 25)
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM messages WHERE text LIKE '%music.apple.com/%'"), 8)
        for url in DemoLinks.all {
            let parsed = try XCTUnwrap(MediaLinks.classify(url), "link does not classify: \(url)")
            // Short youtu.be shares are normalised to a watch URL, which is the point of `clean`.
            XCTAssertTrue(parsed.clean.hasPrefix("https://"), "links must stay https: \(url)")
            XCTAssertFalse(parsed.embed.isEmpty, "a shared link must be playable: \(url)")
            XCTAssertEqual(parsed.key, MediaLinks.classify(parsed.clean)?.key, "cleaning changed the identity: \(url)")
        }
        XCTAssertGreaterThanOrEqual(DemoLinks.all.count, 60)

        // Attachments: hundreds of rows, files on disk, and a real decodable image.
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM media"), 380)
        XCTAssertLessThan(try index.scalarInt("SELECT count(*) FROM media"), 480)
        let kinds = try index.scalarInt("SELECT count(DISTINCT kind) FROM media")
        XCTAssertGreaterThanOrEqual(kinds, 4)
        var sampleImage: ChatMedia?
        try index.query("""
            SELECT m.uid, md.kind, md.file_path, md.size, md.mime, md.file_hash, md.caption
            FROM media md JOIN messages m ON m.id = md.msg_id WHERE md.kind='image' LIMIT 1
            """) { row in
            sampleImage = ChatMedia(uid: row.text(0) ?? "", kind: row.text(1) ?? "", filePath: row.text(2),
                                    size: row.int(3), mime: row.text(4), fileHash: row.text(5), caption: row.text(6))
        }
        let image = try XCTUnwrap(sampleImage)
        let sources = try MediaSources.load(in: vault)
        XCTAssertEqual(sources.count, 1)
        let resolved = MediaFileResolver().resolve(image, sources: sources, driveRoots: [])
        let file = try XCTUnwrap(resolved, "media file must resolve for a demo vault")
        XCTAssertTrue(file.path.contains("media/Media/WhatsApp Images/"))
        let source = CGImageSourceCreateWithURL(file as CFURL, nil)
        XCTAssertNotNil(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "thumbnail source must decode")

        // Stickers are real WebP files in WhatsApp's own folder, not photos with a new label.
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM messages WHERE type=20"), 20)
        var stickerPath: String?
        try index.query("SELECT file_path FROM media WHERE kind='sticker' LIMIT 1") { stickerPath = $0.text(0) }
        let sticker = sources[0].appendingPathComponent(try XCTUnwrap(stickerPath))
        XCTAssertTrue(sticker.path.contains("media/Media/WhatsApp Stickers/"))
        let stickerSource = CGImageSourceCreateWithURL(sticker as CFURL, nil)
        XCTAssertNotNil(stickerSource.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "a demo sticker must decode as an image")

        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM media WHERE kind='video'"), 20)
        var videoPath: String?
        try index.query("SELECT file_path FROM media WHERE kind='video' LIMIT 1") { videoPath = $0.text(0) }
        let video = sources[0].appendingPathComponent(try XCTUnwrap(videoPath))
        XCTAssertGreaterThan((try? Data(contentsOf: video).count) ?? 0, 200, "video placeholders must be real clips")

        // Deleted-on-the-phone rows, quoted replies and the security-code notice.
        XCTAssertGreaterThanOrEqual(try index.scalarInt("SELECT count(*) FROM gone"), 10)
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM message_replies"), 300)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM messages WHERE type=7"), 1)
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM messages WHERE type=7 AND text LIKE 'Security code%'"), 0)

        // The merged pair: one conversation, one person, two numbers.
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM chats WHERE name='Nikhil Rao'"), 1)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM merge_members WHERE person='lid:demo-nikhil'"), 2)
        XCTAssertEqual(try index.scalarInt("SELECT count(*) FROM messages WHERE person='lid:demo-nikhil-old'"), 0,
                       "a merged identity must never appear as its own person")

        // Search still works on generated text.
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM msg_fts WHERE msg_fts MATCH 'blue'"), 0)
        XCTAssertGreaterThan(try index.scalarInt("SELECT count(*) FROM msg_fts WHERE msg_fts MATCH 'biryani'"), 0)

        let rebuilt = try VaultIndexer.build(vault: vault, out: root.appendingPathComponent("rebuilt.db").path)
        XCTAssertEqual(rebuilt.messages, result.messages)
        XCTAssertEqual(rebuilt.chats, result.chats)
        var records = 0
        var maxTs: Int64 = 0
        var digest = 0
        try vault.readAll { record in
            if record["k"] as? String == "m" {
                records += 1
                XCTAssertTrue((record["kid"] as? String)?.hasPrefix("saga-demo-") == true)
                maxTs = max(maxTs, (record["ts"] as? NSNumber)?.int64Value ?? 0)
                digest &+= (record["u"] as? String)?.count ?? 0
            }
        }
        XCTAssertEqual(records, 20_600)
        XCTAssertGreaterThan(digest, 0)
        XCTAssertEqual(maxTs, lastTs)
    }

    /// The website's Gallery capture needs photographs, not drawings. A folder passed as
    /// `--photos` must replace every image attachment, cycle through the folder deterministically,
    /// and leave the archive's shape untouched.
    func testDemoUsesAPhotoFolderForEveryImageAndCyclesItDeterministically() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("saga-demo-photos-\(UUID().uuidString)")
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-photo-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-photo-b-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeImage(to: folder.appendingPathComponent("a-red.png"), r: 0.82, g: 0.20, b: 0.18)
        try writeImage(to: folder.appendingPathComponent("b-green.png"), r: 0.18, g: 0.62, b: 0.30)
        try writeImage(to: folder.appendingPathComponent("c-blue.png"), r: 0.20, g: 0.30, b: 0.78)
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("notes.txt"))  // ignored by extension

        let first = try DemoVault.generate(at: a, photos: folder)
        let second = try DemoVault.generate(at: b, photos: folder)
        XCTAssertEqual(first.messages, second.messages)
        XCTAssertEqual(first.media, second.media)

        func images(in root: URL) throws -> [String] {
            let vault = try Vault(url: root.appendingPathComponent("vault"), create: false)
            let sources = try MediaSources.load(in: vault)
            let index = try SQLiteDB(path: root.appendingPathComponent("vault_index.db").path, readOnly: true)
            var out: [String] = []
            try index.query("SELECT file_path FROM media WHERE kind='image' ORDER BY file_path") { row in
                let rel = row.text(0) ?? ""
                let file = sources[0].appendingPathComponent(rel)
                let data = (try? Data(contentsOf: file)) ?? Data()
                let source = CGImageSourceCreateWithData(data as CFData, nil)
                let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                out.append("\(rel)|\(SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined())|\(image?.width ?? 0)x\(image?.height ?? 0)")
            }
            return out
        }

        let rows = try images(in: a)
        XCTAssertGreaterThan(rows.count, 100, "the demo should still carry hundreds of images")
        XCTAssertEqual(try images(in: b), rows, "cycling a photo folder must be deterministic")
        XCTAssertEqual(Set(rows.map { $0.split(separator: "|")[1] }).count, 3,
                       "every image must be one of the three photographs, cycled — not a drawn scene")
        for row in rows {
            XCTAssertTrue(row.hasSuffix("|640x640"), "a photo must be cropped square and re-encoded: \(row)")
        }
    }

    /// With no folder, nothing changes: the same drawn scenes as before, at their old size.
    func testDemoWithoutPhotosKeepsTheDrawnScenes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-drawn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoVault.generate(at: root)
        let vault = try Vault(url: root.appendingPathComponent("vault"), create: false)
        let sources = try MediaSources.load(in: vault)
        let index = try SQLiteDB(path: root.appendingPathComponent("vault_index.db").path, readOnly: true)
        var hashes = Set<String>()
        var size = (0, 0)
        try index.query("SELECT file_path FROM media WHERE kind='image'") { row in
            let file = sources[0].appendingPathComponent(row.text(0) ?? "")
            let data = (try? Data(contentsOf: file)) ?? Data()
            hashes.insert(SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined())
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                size = (image.width, image.height)
            }
        }
        XCTAssertEqual(size.0, 480)
        XCTAssertEqual(size.1, 360)
        XCTAssertGreaterThan(hashes.count, 5, "drawn scenes still vary per picture")
    }

    func testDemoRejectsABadPhotoFolderBeforeWritingTheDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-bad-photos-\(UUID().uuidString)")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-empty-photos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: empty) }
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DemoVault.generate(at: root, photos: empty)) { error in
            guard case DemoVault.GenerationError.photosFolderEmpty = error else {
                return XCTFail("expected a photosFolderEmpty error, got \(error)")
            }
        }
        XCTAssertThrowsError(try DemoVault.generate(at: root, photos: empty.appendingPathComponent("missing"))) { error in
            guard case DemoVault.GenerationError.photosFolderMissing = error else {
                return XCTFail("expected a photosFolderMissing error, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "a rejected photo folder must not leave a half-made demo behind")
    }

    /// A small solid-colour PNG, enough to prove a real image file went through the pipeline.
    private func writeImage(to url: URL, r: CGFloat, g: CGFloat, b: CGFloat) throws {
        let width = 120, height = 90
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// Same seed, same archive: the fixture must not drift between runs, or screenshots and the
    /// hosted demo page stop matching the generator.
    func testDemoIsDeterministicAcrossRuns() throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-det-a-\(UUID().uuidString)")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-det-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try DemoVault.generate(at: a)
        let second = try DemoVault.generate(at: b)
        XCTAssertEqual(first.messages, second.messages)
        XCTAssertEqual(first.media, second.media)
        XCTAssertEqual(first.people, second.people)

        func fingerprint(_ root: URL) throws -> [String] {
            let index = try SQLiteDB(path: root.appendingPathComponent("vault_index.db").path, readOnly: true)
            var rows: [String] = []
            try index.query("SELECT uid, chat_id, ts, from_me, COALESCE(text,'') FROM messages ORDER BY id") {
                rows.append("\($0.text(0) ?? "")|\($0.int(1))|\($0.int(2))|\($0.int(3))|\($0.text(4) ?? "")")
            }
            return rows
        }
        XCTAssertEqual(try fingerprint(a), try fingerprint(b))
    }

    /// The reason the fixture exists: a per-person Wrapped from it must be full, not empty.
    func testDemoWrappedIsPopulatedFromTheFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saga-demo-wrapped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try DemoVault.generate(at: root)
        let store = try VaultStore(path: root.appendingPathComponent("vault_index.db").path)
        let meera = try XCTUnwrap(try store.chats(kind: .all, sort: .recent, limit: 50).first { $0.name == "Meera Nair" })
        let w = try await DuoWrappedBuilder.build(store: store, chatID: meera.id, me: "You", fetchTitles: false)
        XCTAssertGreaterThan(w.total, 2_000)
        XCTAssertGreaterThan(w.activeDays, 500)
        XCTAssertGreaterThan(w.longestStreak, 30)
        XCTAssertGreaterThan(w.longestGapDays, 14)
        XCTAssertGreaterThan(w.laughsTheirs + w.laughsMine, 100)
        XCTAssertGreaterThan(w.heartsMine + w.heartsTheirs, 0, "the fixture must carry hearts too")
        XCTAssertNotNil(w.loved)
        XCTAssertFalse(w.funniest.isEmpty, "laugh triggers must fire")
        XCTAssertFalse(w.insideJokes.isEmpty, "inside jokes must be found")
        XCTAssertEqual(w.insideJokes.first?.text, "blue kettle")
        XCTAssertFalse(w.stickers.isEmpty, "the fixture must carry stickers")
        XCTAssertGreaterThan(w.stickers.total, 0)
        XCTAssertLessThanOrEqual(w.stickers.distinct, w.stickers.total)
        XCTAssertNotNil(w.emojiPair)
        XCTAssertGreaterThan(w.linksTotal, 30)
        XCTAssertFalse(w.tracks.isEmpty, "a soundtrack must exist")
        XCTAssertGreaterThan(w.tracks.filter { $0.landed > 0 }.count, 2)
        XCTAssertNotNil(w.quietestYear)
        XCTAssertNotNil(w.nightOwl)
        XCTAssertNotNil(w.firstText)
        XCTAssertNotNil(w.busiestDay)

        let group = try XCTUnwrap(try store.chats(kind: .groups, sort: .recent, limit: 50).max(by: { $0.count < $1.count }))
        let g = try await GroupWrappedBuilder.build(store: store, chatID: group.id, me: "You", fetchTitles: false)
        XCTAssertGreaterThan(g.contributors.count, 5)
        XCTAssertFalse(g.funniest.isEmpty)
        XCTAssertFalse(g.tracks.isEmpty)
        XCTAssertGreaterThan(g.heartsByReaction, 0, "group hearts must not be folded into laughs")
        XCTAssertNotNil(g.loved)
        XCTAssertFalse(g.stickers.isEmpty)

        // The year story has the same beats, from the whole archive.
        let y = try await YearWrappedBuilder.build(store: store, year: "2026")
        XCTAssertGreaterThan(y.total, 5_000)
        XCTAssertEqual(y.chatCount, 14)
        XCTAssertTrue(y.isPartial, "the fixture ends in October 2026")
        XCTAssertEqual(y.months, 10)
        XCTAssertFalse(y.people.isEmpty, "named LID people must not be dropped")
        XCTAssertNotNil(y.laughMoment)
        XCTAssertGreaterThan(y.hearts, 0)
        XCTAssertNotNil(y.heartMoment)
        XCTAssertGreaterThan(y.stickers.total, 0)
        XCTAssertGreaterThan(y.linksTotal, 5)
        XCTAssertFalse(y.tracks.isEmpty)
        XCTAssertNotNil(y.longest)
        XCTAssertGreaterThan(y.media.photos, 50)

        let day = try OnThisDayBuilder.build(store: store, month: 11, day: 28)
        XCTAssertGreaterThan(day.years.count, 1)
        XCTAssertGreaterThan(day.total, 20)
    }
}
