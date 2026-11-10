import Foundation
import SagaCore

// saga decrypt --key <keyfile-or-64hex> --in msgstore.db.crypt15 --out msgstore.db
let args = Array(CommandLine.arguments.dropFirst())
let opt: (String) -> String? = { name in
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
if args.first == "phone" {   // saga phone : check ADB connection, backup freshness and phone contacts
    let sem = DispatchSemaphore(value: 0)
    Task.detached {  // detached: top-level code is main-actor isolated and sem.wait() blocks it
        let st = await Adb.state(); print("state: \(st)")
        if case .ready = st {
            if let b = await Adb.backupInfo() { print("backup: \(b.package) last=\(b.lastBackup ?? "?")") } else { print("backup: not found") }
            print("contacts on phone: \(await Adb.phoneContacts().count)")
        }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "update" {   // saga update --key <keyfile|64hex> --support <dir> [--vcf f] [--force]
    guard let keyArg = opt("--key"), let sup = opt("--support") else { print("usage: saga update --key <keyfile|64hex> --support <app-support-dir> [--vault dir] [--vcf f] [--force]"); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    let vcfArg = opt("--vcf"), forceArg = args.contains("--force"), vaultArg = opt("--vault")
    Task.detached {
        do {
            let key = (try? String(contentsOfFile: keyArg, encoding: .utf8)) ?? keyArg
            let support = URL(fileURLWithPath: sup)
            let vault = try Vault.open(url: vaultArg.map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("vault"))
            let s = try await Updater.run(support: support, vault: vault, indexOut: support.appendingPathComponent("vault_index.db"), keyHex: key,
                                          vcfPath: vcfArg, force: forceArg, progress: { print("… \($0)") })
            print("done: messages=\(s.messages) merged=\(s.mergedMessages) chats=\(s.chats)")
        } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)) }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "compact" {   // saga compact --support <dir> : fold older archives into small retained files (originals go to the Trash)
    guard let sup = opt("--support") else { print("usage: saga compact --support <app-support-dir>"); exit(2) }
    do {
        let support = URL(fileURLWithPath: sup)
        let r = try Compactor.run(archive: Updater.archiveDir(support), scratch: FileManager.default.temporaryDirectory)
        let mb = { (b: Int64) in String(format: "%.0f MB", Double(b) / 1_048_576) }
        print("folded \(r.folded) archive(s), kept \(r.kept) unique messages; \(mb(r.bytesBefore)) -> \(mb(r.bytesAfter))")
        exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
}
if args.first == "export" {   // saga export --index vault_index.db --chat <id> --out file.(txt|html)
    guard let idx = opt("--index"), let cid = opt("--chat").flatMap(Int64.init), let out = opt("--out") else { print("usage: saga export --index <vault_index.db> --chat <id> --out <file.txt|file.html>"); exit(2) }
    do {
        let store = try VaultStore(path: idx)
        guard let chat = try store.chats(limit: 100000).first(where: { $0.id == cid }) else { print("chat not found"); exit(1) }
        let n = try ChatExporter.export(store: store, chat: chat, format: out.hasSuffix(".html") ? .html : .text, to: URL(fileURLWithPath: out))
        print("exported \(n) messages from \(chat.name)"); exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
}
if args.first == "demo" {   // saga demo --out <new-folder> [--photos <folder>] : synthetic, offline, public-safe sample vault
    guard let out = opt("--out") else { print("usage: saga demo --out <new-folder> [--photos <folder>]\n  --photos swaps the drawn gallery scenes for a folder of real photographs (read in filename order, cycled).\n  then: Saga.app/Contents/MacOS/Saga --demo <new-folder>   |   saga duo --index <new-folder>/vault_index.db --chat <id>"); exit(2) }
    do {
        let dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        let photos = opt("--photos").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        let s = try DemoVault.generate(at: dir, photos: photos)
        print("demo vault: \(dir.path)/vault\nindex:      \(dir.path)/vault_index.db\nmessages=\(s.messages) chats=\(s.chats) people=\(s.people) named=\(s.namedPeople)")
        if let photos { print("photos:     \(photos.path) (gallery media uses these instead of drawn scenes)") }
        // Stable --chat ids so scripts (website, launch cards, screenshots) need no sqlite query.
        for c in try VaultStore(path: dir.appendingPathComponent("vault_index.db").path).chats(kind: .all, sort: .recent, limit: 100).sorted(by: { $0.id < $1.id }) {
            print("  --chat \(c.id)\(c.isGroup ? " (group)" : ""): \(c.name)")
        }
        exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(1) }
}
if args.first == "vault" {   // saga vault ingest|index ... see usage
    let sub = args.dropFirst().first ?? ""
    func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
    guard let dir = opt("--vault") else { print("usage: saga vault ingest --vault <dir> --db <msgstore.db> [--label name] [--partial]\n       saga vault index --vault <dir> --out <vault_index.db> [--vcf f] [--overrides f]"); exit(2) }
    do {
        let vault = try Vault.open(url: URL(fileURLWithPath: dir))
        let t0 = Date(); let secs = { String(format: "%.1fs", Date().timeIntervalSince(t0)) }
        if sub == "ingest" {
            guard let db = opt("--db") else { fail("--db required") }
            let r = try vault.ingest(msgstore: db, label: opt("--label") ?? "mac", fullSnapshot: !args.contains("--partial"))
            print("added=\(r.added) skipped=\(r.skipped) gone=\(r.gone) paths=\(r.pathsUpdated) reactions=\(r.reactionsAdded) segment=\(r.segment ?? "-") in \(secs())")
        } else if sub == "index" {
            guard let out = opt("--out") else { fail("--out required") }
            let s = try VaultIndexer.build(vault: vault, out: out, vcfPath: opt("--vcf"), overridesPath: opt("--overrides"))
            print("messages=\(s.messages) chats=\(s.chats) people=\(s.people) named=\(s.namedPeople) media=\(s.media) reactions=\(s.reactions) gone=\(s.mergedMessages) in \(secs())")
        } else { fail("unknown vault command") }
        exit(0)
    } catch { fail("error: \(error)") }
}
if args.first == "foldin" {   // saga foldin scan --src dir | saga foldin run --src dir --vault dir [--key keyfile] [--dry-run]
    let sub = args.dropFirst().first ?? ""
    guard let src = opt("--src") else { print("usage: saga foldin scan --src <folder>\n       saga foldin run --src <folder> --vault <dir> [--key keyfile|64hex] [--dry-run]"); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    let vaultArg = opt("--vault"), keyArg = opt("--key"), dry = args.contains("--dry-run")
    Task.detached {
        let mb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        let rep = FoldIn.scan(root: URL(fileURLWithPath: src), progress: { FileHandle.standardError.write(Data("scanned \($0) files\r".utf8)) })
        print("\nFolder: \(src)\nFiles: \(rep.totalFiles.formatted())   empty folders: \(rep.emptyFolders)   duplicates: \(rep.duplicateFiles)")
        print("\nDatabases (\(rep.databases.count)):")
        for d in rep.databases { print("  \(d.usable ? "✓" : "✗") \(d.url.lastPathComponent)  [\(d.format.rawValue)]  \(String(format: "%.0f MB", Double(d.size) / 1_048_576))") }
        print("\nMedia:"); for c in rep.media { print("  \(c.name): \(c.files.formatted()) files, \(mb(c.bytes))") }
        if let a = rep.oldestMedia, let b = rep.newestMedia { print("  dated \(a.formatted(date: .abbreviated, time: .omitted)) to \(b.formatted(date: .abbreviated, time: .omitted))") }
        if !rep.quirks.isEmpty { print("\nNotes:"); rep.quirks.forEach { print("  • \($0)") } }
        if sub == "run", let v = vaultArg {
            do {
                let vault = try Vault.open(url: URL(fileURLWithPath: v))
                let key = keyArg.map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? $0 }
                print("\n\(dry ? "Dry run" : "Folding in"):")
                for o in await FoldIn.run(report: rep, vault: vault, keyHex: key, dryRun: dry, progress: { _ in }) { print("  \(o.file): \(o.status)") }
                if !dry { FoldIn.recordMediaSource(URL(fileURLWithPath: src), in: vault) }
            } catch { print("error: \(error)") }
        }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "models" {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let d = await LocalAI.detect()
        for m in d.models { print("\(m.id)\t\(m.detail): \(m.name)") }
        d.hints.forEach { print("hint: \($0)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "summarize" || args.first == "ask" {   // saga summarize --index f --chat id [--days N] [--model id] | saga ask --index f "question" [--chat id] [--model id]
    guard let ix = opt("--index") else { print("usage: saga summarize --index vault_index.db --chat <id> [--days 30] [--model id]\n       saga ask --index vault_index.db \"question\" [--chat id] [--model id]"); exit(2) }
    let isAsk = args.first == "ask"
    let sem = DispatchSemaphore(value: 0)
    let fullArg = args.contains("--full"); let modelArg = opt("--model"), chatArg = opt("--chat").flatMap { Int64($0) }, daysArg = opt("--days").flatMap { Int($0) } ?? 30
    let question = args.dropFirst().first { !$0.hasPrefix("--") && $0 != opt("--index") && $0 != opt("--chat") && $0 != opt("--model") && $0 != opt("--days") } ?? ""
    Task.detached {
        do {
            let st = try VaultStore(path: ix)
            let det = await LocalAI.detect()
            let model = modelArg.flatMap { id in det.models.first { $0.id == id || $0.name == id } } ?? det.models.first
            guard let model else { print(det.hints.first ?? "No AI model available."); sem.signal(); return }
            print("model: \(model.detail) \(model.name)")
            let t0 = Date()
            if isAsk {
                let r = try await LocalAI.ask(question, store: st, chat: chatArg, model: model)
                print("(searched \(r.searched) messages)")
                for p in r.points { print("- \(p.text)   → \(p.sources.map { "\($0.chatID):\($0.messageID)" })") }
                if r.points.contains(where: \.unstructured) { print("(plain-text answer: citations may be missing)") }
            } else {
                guard let cid = chatArg else { print("--chat required"); sem.signal(); return }
                let days = daysArg
                guard let chat = try st.chats(matching: "", kind: .all, sort: .recent, minMessages: 1, limit: 100000).first(where: { $0.id == cid }) else { print("no such chat"); sem.signal(); return }
                let rows = try st.messages(chat: cid, from: chat.last.addingTimeInterval(-Double(days) * 86400), filter: .all, limit: 5000)
                print("\(chat.name): \(rows.count) messages in the last \(days) days before \(chat.last.formatted(date: .abbreviated, time: .omitted))")
                let summarized = try await LocalAI.summarize(rows, chatID: cid, chatName: chat.name, isGroup: chat.isGroup, model: model, detail: fullArg ? .full : .quick, cache: try? AICache(path: NSString(string: "~/.hermes/cache/scratch/ai_cache_test.db").expandingTildeInPath), progress: { FileHandle.standardError.write(Data("part \($0.done)/\($0.total) cached \($0.fromCache)\r".utf8)) })
                for p in summarized { print("- \(p.text)   → \(p.sources.map { $0.messageID })") }
                if summarized.contains(where: \.unstructured) { print("(plain-text answer: citations may be missing)") }
            }
            print("(\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
        } catch { print("error: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "duo" {   // saga duo --index f --chat id [--me Name] [--out file.html] [--titles] [--summary]
    guard let ix = opt("--index"), let cid = opt("--chat").flatMap({ Int64($0) }) else { print("usage: saga duo --index vault_index.db --chat <dm chat id> [--me Name] [--out wrapped.html] [--titles]"); exit(2) }
    // Demo indexes never embed the Mac account name in (public) artifacts: default to a fictional name instead.
    let meName: String = {
        if let given = opt("--me") { return given }
        if DemoVault.isSyntheticDemo(indexURL: URL(fileURLWithPath: ix)) { return "You" }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    }()
    let outPath = opt("--out"), titles = args.contains("--titles"), summaryOnly = args.contains("--summary")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let t0 = Date()
            let w = try await DuoWrappedBuilder.build(store: try VaultStore(path: ix), chatID: cid, me: meName, fetchTitles: titles)
            if summaryOnly {   // numbers only: nothing from the conversation is printed
                print("messages \(w.total) (\(w.mine)/\(w.theirs)), days \(w.activeDays), streak \(w.longestStreak), gap \(w.longestGapDays)d")
                print("laughs sent \(w.laughsMine)/\(w.laughsTheirs), made laugh \(w.madeThemLaugh)/\(w.madeMeLaugh), funny moments \(w.funniest.count)")
                print("hearts \(w.heartsMine)/\(w.heartsTheirs) (mine/theirs), loved \(w.loved == nil ? "none" : "found")")
                print("stickers \(w.stickers.total) sent, \(w.stickers.distinct) distinct, busiest \(w.stickers.topCount)×")
                print("inside jokes \(w.insideJokes.count), my words \(w.myWords.count), their words \(w.theirWords.count), emoji \(w.emojiTogether.count)")
                print("years \(w.byYear.count), best \(w.bestYear?.year.description ?? "-"), quiet \(w.quietestYear?.year.description ?? "-"), night message \(w.nightOwl == nil ? "none" : "found"), emoji pair \(w.emojiPair == nil ? "none" : "found")")
                print("links \(w.linksTotal), tracks featured \(w.tracks.count) \(Dictionary(grouping: w.tracks, by: \.role).mapValues(\.count)), twins \(w.twinTracks)")
            }
            if let outPath { try DuoWrappedHTML.render(w, interactive: false).write(toFile: outPath, atomically: true, encoding: .utf8); print("wrote \(outPath)") }
            print(String(format: "(%.1fs)", Date().timeIntervalSince(t0)))
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "group" {   // saga group --index f --chat id [--out file.html]
    guard let ix = opt("--index"), let cid = opt("--chat").flatMap({ Int64($0) }) else { print("usage: saga group --index vault_index.db --chat <group chat id> [--out wrapped.html]"); exit(2) }
    let meName = DemoVault.isSyntheticDemo(indexURL: URL(fileURLWithPath: ix)) ? "You" : (NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me")
    let outPath = opt("--out")
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let w = try await GroupWrappedBuilder.build(store: try VaultStore(path: ix), chatID: cid, me: meName, fetchTitles: false)
            print("messages \(w.total), contributors \(w.contributors.count), days \(w.activeDays)")
            print("laughs by reaction \(w.laughsByReaction), funny people \(w.funniest.count)")
            print("hearts \(w.heartsByReaction), loved \(w.loved == nil ? "none" : "found")")
            print("stickers \(w.stickers.total) sent, \(w.stickers.distinct) distinct, busiest \(w.stickers.topCount)×")
            print("inside jokes \(w.insideJokes.map(\.text))")
            if let outPath { try GroupWrappedHTML.render(w, interactive: false).write(toFile: outPath, atomically: true, encoding: .utf8); print("wrote \(outPath)") }
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "year" {   // saga year --index f --year 2026 : the year story's numbers, as text
    guard let ix = opt("--index"), let year = opt("--year") else { print("usage: saga year --index vault_index.db --year 2026"); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let w = try await YearWrappedBuilder.build(store: try VaultStore(path: ix), year: year, fetchTitles: false)
            print("year \(w.year): messages \(w.total) across \(w.chatCount) conversations")
            print("laughs \(w.laughs) — \(WrappedCopy.yearLaughs(count: w.laughs))")
            if let line = WrappedCopy.yearHearts(count: w.hearts) { print("hearts \(w.hearts) — \(line)") }
            if let m = w.heartMoment { print("heart moment: \(m.author) in \(m.chatName), \(WrappedCopy.date(m.date))") }
            if let line = WrappedCopy.stickers(total: w.stickers.total, distinct: w.stickers.distinct, topCount: w.stickers.topCount) { print("stickers — \(line)") }
            print("photos \(w.media.photos), videos \(w.media.videos), voice \(w.media.voice), docs \(w.media.docs)")
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "ios" {   // saga ios scan --backup dir | saga ios import --backup dir --vault dir [--label x] | saga ios device
    let sub = args.dropFirst().first ?? ""
    let backupArg = opt("--backup"), vaultArg = opt("--vault"), labelArg = opt("--label") ?? "iphone"
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            if sub == "device" {
                switch await Idevice.state() {
                case .missingTools: print("libimobiledevice not installed (brew install libimobiledevice)")
                case .noPhone: print("no iPhone found (plug in, unlock, tap Trust)")
                case .ready(let u): let i = await Idevice.info(u); print("iPhone ready: \(i?.name ?? "?") iOS \(i?.version ?? "?") [\(u)]")
                }
            } else if let b = backupArg {
                let found = try IOSBackup.locate(URL(fileURLWithPath: b))
                print("backup: \(found.deviceName), iOS \(found.iosVersion), \(found.lastBackup?.formatted() ?? "?"), encrypted=\(found.encrypted)")
                let cs = try IOSBackup.chatStorage(found)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("saga-ios-\(UUID().uuidString).db")
                defer { try? FileManager.default.removeItem(at: tmp) }
                let r = try IOSBackup.convert(chatStorage: cs.path, to: tmp.path)
                print("converted: \(r.chats) chats, \(r.messages) messages, \(r.media) media rows, \(r.pushNames) push names")
                if sub == "import", let v = vaultArg {
                    let vault = try Vault.open(url: URL(fileURLWithPath: v))
                    let res = try vault.ingest(msgstore: tmp.path, label: labelArg, source: "ios-backup", fullSnapshot: false, dryRun: args.contains("--dry-run"))
                    print("vault: added \(res.added), already there \(res.skipped)\(args.contains("--dry-run") ? " (dry run)" : "")")
                }
            } else { print("usage: saga ios device | saga ios scan --backup <dir> | saga ios import --backup <dir> --vault <dir> [--dry-run]") }
        } catch { print("error: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if args.first == "links" {   // saga links --index f [--chat id]
    guard let ix = opt("--index") else { print("usage: saga links --index vault_index.db [--chat id]"); exit(2) }
    do {
        let items = try VaultStore(path: ix).sharedLinks(chat: opt("--chat").flatMap { Int64($0) })
        var by: [String: Int] = [:]; for i in items { by[i.link.service.rawValue, default: 0] += 1 }
        print("\(items.count) distinct items: \(by.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        if args.contains("--meta") {
            let sem = DispatchSemaphore(value: 0)
            let sample = Array(items.filter { $0.link.service == .spotify }.suffix(3) + items.filter { $0.link.service == .youtube }.suffix(3))
            Task.detached {
                for i in sample { let m = await MediaLinks.fetchMeta(i.link); print("  \(i.link.service.rawValue): \(m?.title ?? "(no title)") | \(m?.author ?? "") | thumb \(m?.thumbnail != nil)") }
                sem.signal()
            }
            sem.wait()
        }
        for i in items.prefix(5) { print("  \(i.link.ts.formatted(date: .abbreviated, time: .omitted)) \(i.link.service.rawValue) \(i.link.kind) \(i.link.url)\(i.times > 1 ? " x\(i.times)" : "")") }
    } catch { print("error: \(error)") }
    exit(0)
}
if args.first == "prune-scan" {   // saga prune-scan --index f [--min 300]
    guard let ix = opt("--index") else { print("usage: saga prune-scan --index vault_index.db [--min 300]"); exit(2) }
    do {
        let st = try VaultStore(path: ix)
        print("name | msgs | mine | media% | link% | repeat% | strangers% | suggestion | would hide")
        for c in try PruneScan.scan(store: st, minMessages: opt("--min").flatMap { Int($0) } ?? 300).prefix(25) {
            guard let r = c.suggestion else { continue }
            print("\(c.name.prefix(28)) | \(c.messages) | \(c.mine) | \(c.mediaPct) | \(c.linkPct) | \(c.repeatPct) | \(c.strangerPct) | \(r.summary) | \(c.estimate(r))")
        }
    } catch { print("error: \(error)") }
    exit(0)
}
if args.first == "onthisday" {   // saga onthisday --index vault_index.db --date 11-07 [--count-only]
    guard let ix = opt("--index"), let raw = opt("--date") else {
        print("usage: saga onthisday --index vault_index.db --date MM-DD [--count-only]")
        exit(2)
    }
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 2 else { print("--date must look like 11-07"); exit(2) }
    do {
        let store = try VaultStore(path: ix)
        let d = try OnThisDayBuilder.build(store: store, month: parts[0], day: parts[1])
        print("On this day: \(String(format: "%02d-%02d", d.month, d.day)) — \(d.total.formatted()) messages across \(d.years.count) year\(d.years.count == 1 ? "" : "s")")
        for y in d.years.sorted(by: { $0.year < $1.year }) {
            print("  \(y.year): \(y.count.formatted()) messages, \(y.chatCount) chats, \(y.mediaCount) photos/videos, \(y.links.count) links")
            if !args.contains("--count-only") {
                if let f = y.first { print("    first \(f.ts.formatted(date: .omitted, time: .shortened)) — \(f.sender): \(OnThisDay.clip(f.text, 60))") }
                if let h = y.highlight, let r = h.reaction { print("    funniest: \(OnThisDay.clip(h.text, 60))  ← \(r)") }
            }
        }
        if !args.contains("--count-only"), let first = d.firstEver {
            print("  first ever on this date: \(first.ts.formatted(date: .abbreviated, time: .omitted)) — \(first.sender): \(OnThisDay.clip(first.text, 60))")
        }
        if !d.quietYears.isEmpty { print("  quiet: \(d.quietYears.map(String.init).joined(separator: ", "))") }
        exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
}
if args.first == "import" {
    guard let db = opt("--db"), let out = opt("--out") else { print("usage: saga import --db <msgstore.db> --out <vault_index.db> [--vcf f] [--overrides f] [--also older-msgstore.db ...]"); exit(2) }
    do {
        let t0 = Date()
        let also = args.enumerated().filter { $0.element == "--also" && $0.offset + 1 < args.count }.map { args[$0.offset + 1] }
        let s = try Importer.run(ImportOptions(sourceDB: db, outputDB: out, vcfPath: opt("--vcf"), overridesPath: opt("--overrides"), additionalSources: also))
        print("merged=\(s.mergedMessages) messages=\(s.messages) chats=\(s.chats) people=\(s.people) named=\(s.namedPeople) media=\(s.media) reactions=\(s.reactions) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
}
guard args.first == "decrypt", let keyArg = opt("--key"), let inp = opt("--in"), let out = opt("--out") else {
    print("usage: saga decrypt --key <keyfile|64hex> --in <file.crypt15> --out <msgstore.db>")
    exit(2)
}
do {
    let keyText = (try? String(contentsOfFile: keyArg, encoding: .utf8)) ?? keyArg
    let data = try Data(contentsOf: URL(fileURLWithPath: inp), options: .mappedIfSafe)
    let plain = try Crypt15.decrypt(file: data, rootKeyHex: keyText)
    try plain.write(to: URL(fileURLWithPath: out))
    print("ok: wrote \(plain.count) bytes to \(out)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
