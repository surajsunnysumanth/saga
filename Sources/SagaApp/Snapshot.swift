import SwiftUI
import AppKit
import SagaCore

/// Debug aid: `SagaApp --snapshot <dir>` renders the app's own window to PNGs (no screen-recording permission needed), then quits.
private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

@MainActor
enum Snapshot {
    /// `--ai` adds the three on-device AI surfaces to a `--snapshot` run. It is a snapshot-only flag:
    /// without `--snapshot` it does nothing, so a normal launch never opens these windows.
    nonisolated static var aiCaptures: Bool {
        CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--ai")
    }

    /// `--react-detail` pins a reaction chip's "who reacted" card open for the capture. A
    /// snapshot cannot hover, and the card is a popover (its own window), so it needs a door
    /// that does not need a mouse; outside `--snapshot` the flag does nothing.
    nonisolated static var reactionDetailPinned: Bool {
        CommandLine.arguments.contains("--snapshot") && CommandLine.arguments.contains("--react-detail")
    }

    static func runIfRequested(_ model: AppModel) async {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return }
        // A snapshot renders whatever library is loaded. Without --demo that is the real archive,
        // so refuse outright: public screenshots must only ever show the synthetic demo.
        NSApp.setActivationPolicy(.accessory)          // invisible: no Dock icon, never steals focus
        guard AppModel.demoRoot != nil else {
            FileHandle.standardError.write(Data("error: --snapshot requires --demo <folder>; refusing to capture the real library. Run `saga demo --out <new-folder>` first.\n".utf8))
            exit(2)
        }
        if a.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if a.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // Optional: render at an explicit content size, e.g. `--width 900 --height 800`
        // to check the layout at the narrow and wide ends of its range. Applied once the
        // window exists (it isn't visible yet when this task starts).
        let width = a.firstIndex(of: "--width").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil }
        let height = a.firstIndex(of: "--height").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil }
        let dir = URL(fileURLWithPath: a[i + 1]); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shot(_ name: String, sheet: Bool = false, of explicit: NSWindow? = nil) async {
            try? await Task.sleep(for: .seconds(1.2))
            if !sheet && explicit == nil { resize() }
            let window = explicit
                ?? NSApp.windows.first(where: { $0.isVisible && $0.isSheet == sheet })
                ?? NSApp.windows.first(where: { $0.isVisible })
            // park the window off every screen so nothing flashes up while capturing
            if let window, !window.frame.origin.x.isNaN, window.frame.origin.x > -20000 {
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            }
            guard let v = window?.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        /// The SwiftUI content declares a 900pt minimum and the window restores its own
        /// frame before the first capture, so the requested size is applied right before
        /// every shot rather than once at launch.
        func resize() {
            guard let width else { return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
            window.contentMinSize = NSSize(width: 640, height: 480)
            let size = NSSize(width: width, height: height ?? Double(window.contentView?.bounds.height ?? 820))
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            window.setFrame(frame, display: true, animate: false)
            window.contentView?.layoutSubtreeIfNeeded()
            let got = window.contentView?.bounds ?? .zero
            FileHandle.standardError.write(Data("snapshot: frame \(Int(frame.width))x\(Int(frame.height)) content \(Int(got.width))x\(Int(got.height))\n".utf8))
        }
        if let i = a.firstIndex(of: "--place"), i + 1 < a.count,
           let place = Place.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1].lowercased() }) {
            model.go(to: place)
        }
        // Optional: a synthetic release (`--update 1.0.3`) so the Home banner and the Settings row
        // can be photographed without a network call and without touching real preferences.
        let previewUpdate = a.firstIndex(of: "--update").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
        if let previewUpdate { model.previewUpdate(version: previewUpdate) }

        /// Hosts a view that normally lives in a sheet or the Settings window — its own material
        /// never rasterises in a window capture — parked offscreen.
        @MainActor func hostedShot<V: View>(_ view: V, name: String, size: NSSize) async {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            // A hosted view has no window backdrop of its own, so it draws on transparent
            // white; in dark mode that left white text on a white PNG. Give it the window
            // colour the real sheet would sit on.
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFront(nil)          // accessory app: draws offscreen, never becomes active
            try? await Task.sleep(for: .seconds(2.5))
            // A hosting view left to size itself grows to SwiftUI's ideal height (thousands of
            // points for a form), which produced a canvas taller than any window. Pin the
            // capture to the size the caller asked for.
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            window.orderOut(nil)
            window.contentView = nil
        }
        try? await Task.sleep(for: .seconds(1.5))
        resize()
        try? await Task.sleep(for: .seconds(0.6))
        await shot("1-dashboard")
        // Optional: the Home module tiles (`--tiles`). Each capture is taken after the exact
        // call a tile makes, so the picture is the destination that click produces.
        if a.contains("--tiles") {
            model.go(to: .home)
            await shot("h0-home")
            for (id, name) in [("chats", "h1-chats"), ("people", "h2-people"),
                               ("wrapped", "h3-wrapped"), ("music", "h4-music")] {
                model.openModule(id)
                try? await Task.sleep(for: .seconds(1.4))
                await shot(name)
                FileHandle.standardError.write(Data("tiles: \(id) -> pane \(model.pane), section \(model.section), gallery tab \(model.galleryTab ?? "none")\n".utf8))
                model.go(to: .home)
                try? await Task.sleep(for: .milliseconds(700))
            }
            NSApp.terminate(nil)
            return
        }
        // Which conversation to show: the busiest group by default, or an explicit `--open <chat id>`.
        let wantedOpen = a.firstIndex(of: "--open").flatMap { $0 + 1 < a.count ? Int64(a[$0 + 1]) : nil }
        if let wantedOpen, let chat = model.chats.first(where: { $0.id == wantedOpen }) {
            model.openChat(chat)
        } else if let c = model.chats.first(where: { $0.isGroup }) ?? model.chats.first {
            model.openChat(c)
        }
        // `--nav-probe` prints what the chat pane's navigation state actually does, so a
        // navigation rule can be checked by running the app instead of by reading the diff.
        if a.contains("--nav-probe") {
            let first = model.chats.first
            let second = model.chats.dropFirst().first
            print("probe: chats available \(model.chats.count)")
            if let first {
                model.openChat(first)
                model.chatMode = .wrapped
                print("probe: chat A \(first.id) — mode set to \(model.chatMode.rawValue)")
                if let second {
                    model.openChat(second)
                    print("probe: switched to chat B \(second.id) — pane mode is \(model.chatMode.rawValue)")
                }
                model.openChat(first)
                model.chatMode = .media
                print("probe: chat A \(first.id) — mode set to \(model.chatMode.rawValue)")
                model.openChat(first)
                print("probe: re-selected the same chat \(first.id) — pane mode is \(model.chatMode.rawValue)")
                // Bug 2: jump out of a chat into another one, then take the way back.
                if let second, let here = model.messages.last?.id {
                    model.chatMode = .messages
                    if let target = (try? model.store?.messages(chat: second.id, filter: .all))?.last {
                        model.jump(toMessage: target.id, in: second.id)
                        print("probe: jumped to \(target.id) in chat \(second.id) — now pane \(model.pane) chat \(model.selected?.id ?? -1), origin \(String(describing: model.jumpOrigin))")
                        print("probe: bar sentence: \(model.jumpOriginSentence)")
                        model.returnToOrigin()
                        print("probe: after the way back — pane \(model.pane) chat \(model.selected?.id ?? -1) mode \(model.chatMode.rawValue) focus \(model.focusMessage.map(String.init) ?? "none") (left from message \(here)), origin \(String(describing: model.jumpOrigin))")
                        // Dismissing must clear it, not just hide it.
                        model.jump(toMessage: target.id, in: second.id)
                        model.dismissJumpOrigin()
                        print("probe: after dismiss — origin is \(model.jumpOrigin == nil ? "cleared" : "still stored")")
                        // In-chat: a Heartbeat moment in the conversation that is already open.
                        model.openChat(first)
                        model.chatMode = .wrapped
                        if let inChat = (try? model.store?.messages(chat: first.id, filter: .all))?.last {
                            model.jump(toMessage: inChat.id, in: first.id)
                            print("probe: in-chat Heartbeat jump — mode \(model.chatMode.rawValue), bar \"\(model.jumpOriginSentence)\"")
                            model.returnToOrigin()
                            print("probe: in-chat return — mode \(model.chatMode.rawValue), origin \(model.jumpOrigin == nil ? "cleared" : "still stored")")
                        }
                        // A pruned anchor: the chat is here, the message is not.
                        let when = model.messages.last?.ts ?? Date()
                        model.jump(toMessage: target.id, in: second.id,
                                   origin: ChatOrigin(place: .conversation, chatID: first.id,
                                                      messageID: 999_999_999, date: when, mode: .messages))
                        model.returnToOrigin()
                        print("probe: pruned-anchor return — pane \(model.pane), chat \(model.selected?.id ?? -1), mode \(model.chatMode.rawValue), focus \(model.focusMessage.map(String.init) ?? "none"), toast \"\(model.toast ?? "")\"")
                        model.jump(toMessage: target.id, in: second.id,
                                   origin: ChatOrigin(place: .insights, date: Date()))
                        print("probe: story jump — bar \"\(model.jumpOriginSentence)\"")
                        model.returnToOrigin()
                        print("probe: story return — pane \(model.pane), section \(model.section.rawValue), origin \(model.jumpOrigin == nil ? "cleared" : "still stored")")
                    }
                }
            }
            NSApp.terminate(nil)
            return
        }
        if let i = a.firstIndex(of: "--chat-mode"), i + 1 < a.count,
           let mode = ChatMode.allCases.first(where: { $0.rawValue.lowercased() == a[i + 1].lowercased() }) {
            model.chatMode = mode
            if mode == .wrapped { try? await Task.sleep(for: .seconds(6)) }
        }
        await shot("2-chat")
        // Optional: the reaction chips' "who reacted" card (`--react-detail`). The card is a
        // popover, so it is its own window and the main window's capture never contains it —
        // it is photographed on its own, beside the chip shot above.
        if a.contains("--react-detail") {
            try? await Task.sleep(for: .seconds(1.2))
            let classes = NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }
            FileHandle.standardError.write(Data("reaction detail: visible windows \(classes)\n".utf8))
            if let pop = NSApp.windows.first(where: { w in
                w.isVisible && w.contentView != nil && String(describing: type(of: w)).contains("Popover")
            }) {
                await shot("2b-reaction-detail", of: pop)
            } else {
                FileHandle.standardError.write(Data("reaction detail: no popover window; the card did not open\n".utf8))
            }
        }
        // Optional: the way back after a jump (`--return-bar`). It performs the real jump a
        // Wrapped moment makes — out of a conversation's Heartbeat into another chat's message —
        // so the capture is the state the affordance actually sees.
        if a.contains("--return-bar"), let from = model.selected,
           let other = model.chats.first(where: { $0.id != from.id && !$0.isGroup }) ?? model.chats.first(where: { $0.id != from.id }),
           let target = (try? model.store?.messages(chat: other.id, filter: .all))?.last {
            model.chatMode = .wrapped
            try? await Task.sleep(for: .milliseconds(400))
            model.jump(toMessage: target.id, in: other.id)
            try? await Task.sleep(for: .seconds(1.4))
            await shot("2b-return-bar")
            FileHandle.standardError.write(Data("return-bar: origin \(String(describing: model.jumpOrigin)) bar says \"\(model.jumpOriginSentence)\"\n".utf8))
            model.returnToOrigin()
            try? await Task.sleep(for: .seconds(1.2))
            await shot("2c-returned")
            FileHandle.standardError.write(Data("return-bar: after return pane \(model.pane) chat \(model.selected?.id ?? -1) mode \(model.chatMode.rawValue) origin \(String(describing: model.jumpOrigin))\n".utf8))
            NSApp.terminate(nil)
            return
        }
        // Optional: the conversation's own find bar (`--find goa`). Ask arrives in the inspector
        // now, so it is captured with `--ai` rather than as a chat mode.
        if let i = a.firstIndex(of: "--find"), i + 1 < a.count {
            model.findQuery = a[i + 1]
            model.beginFind()
            try? await Task.sleep(for: .seconds(1.6))
            await shot("2-chat-find")
            model.closeFind()
        }
        // Optional: the Ask panel on its own (`--ask-panel`), with the scope chip that says
        // which conversation it will search. The inspector column's material never rasterises
        // in a window capture, so the panel is hosted by itself, as Topics and Reply already are.
        if a.contains("--ask-panel"), let chat = model.selected {
            model.aiPanel.openAsk(model: model)
            model.aiPanel.question = "where did we stay in goa?"
            try? await Task.sleep(for: .seconds(0.8))
            let host = NSHostingView(rootView: AIPanelView().environment(model)
                .frame(width: 400, height: 560, alignment: .topLeading)
                .background(AppTheme.Surface.page))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 560)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("2b-ask-panel-\(chat.id).png"))
            }
            model.aiPanel.open = false
            NSApp.terminate(nil)          // this flag exists only to photograph the panel
            return
        }
        model.query = a.contains("--query") ? a[(a.firstIndex(of: "--query") ?? 0) + 1] : "birthday"
        model.runSearch()
        await shot("3-search")
        model.query = ""; model.section = .people
        if let p = model.people.first { model.selectedPerson = p }
        await shot("4-person")
        // Optional: the Unnamed sheet (`--unnamed`). It lists every chat with no resolved name, so the
        // capture needs a demo archive that genuinely has some, or it photographs the empty state.
        if a.contains("--unnamed") {
            model.section = .people
            model.showUnnamed = true
            await shot("4-unnamed", sheet: true)
            model.showUnnamed = false
            try? await Task.sleep(for: .milliseconds(400))
        }
        // The year story builds off the main thread; `--wrapped-titles` also resolves song
        // titles for the capture without touching the user's preferences.
        model.demoTitles = a.contains("--wrapped-titles")
        model.wrappedTitles = model.demoTitles
        model.section = .wrapped
        await model.waitForWrapped()
        await shot("5-wrapped")
        // On this day: today's date by default (usually an empty state on the demo),
        // or an explicit MM-DD with `--otd-date 02-14` to capture the full sheet.
        var otdDate = Date()
        if let i = a.firstIndex(of: "--otd-date"), i + 1 < a.count {
            let parts = a[i + 1].split(separator: "-").compactMap { Int($0) }
            if parts.count == 2 {
                var comps = DateComponents()
                comps.year = Calendar.current.component(.year, from: Date())
                comps.month = parts[0]; comps.day = parts[1]
                if let d = Calendar.current.date(from: comps) { otdDate = d }
            }
        }
        model.onThisDayDate = otdDate
        model.showOnThisDay = true
        await model.loadOnThisDay(date: otdDate)
        await shot("6-onthisday", sheet: true)
        model.showOnThisDay = false
        try? await Task.sleep(for: .milliseconds(500))
        // Optional: the empty and error surfaces (`--states`), driven through the same
        // model calls the UI uses, so they can be reviewed without touching data.
        if a.contains("--states") {
            model.section = .chats; model.chatQuery = "zzzz"; model.hits = []
            await shot("6-chats-empty")
            model.chatQuery = ""
            model.query = "zzzz"; model.runSearch()
            await shot("7-search-empty")
            model.status = "Search error: the library could not be read"
            model.hits = []
            await shot("8-search-error")
            model.status = ""
            model.section = .people; model.peopleQuery = "zzzz"
            await shot("9-people-empty")
            model.peopleQuery = ""; model.selectedPerson = nil; model.pane = .person
            await shot("10-person-none")
            model.section = .wrapped; model.wrappedYear = "1999"
            await model.waitForWrapped()
            await shot("11-wrapped-empty")
            model.aiPanel.open = true; model.aiPanel.mode = .media
            model.media.open(chat: nil, model: model)
            await shot("12-media-empty")
        }
        // Optional: the native Wrapped story (`--wrapped`). Rendered offscreen at a fixed
        // width so the whole story is reviewable in one image; needs `--demo` like every
        // other capture, so it can never show the real library.
        if a.contains("--wrapped"), let store = model.store {
            @MainActor func png<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) {
                let renderer = ImageRenderer(content: view.frame(width: width, height: height, alignment: .top))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:]) else {
                    FileHandle.standardError.write(Data("snapshot: could not render \(name)\n".utf8)); return
                }
                try? data.write(to: dir.appendingPathComponent(name))
            }
            let wantedChat = a.firstIndex(of: "--wrapped-chat").flatMap { $0 + 1 < a.count ? Int64(a[$0 + 1]) : nil }
            let duoChats: [ChatRow] = wantedChat.flatMap { id in model.chats.first { $0.id == id } }.map { [$0] }
                ?? Array(model.chats.filter { !$0.isGroup }.sorted { $0.count > $1.count }.prefix(1))
            let withTitles = a.contains("--wrapped-titles")
            for chat in duoChats {
                guard let w = try? await DuoWrappedBuilder.build(store: store, chatID: chat.id, me: "You", fetchTitles: withTitles) else { continue }
                await StoryArtwork.preload(w.tracks.compactMap(\.thumbnail))
                let name = wantedChat == nil ? "13-wrapped-duo.png" : "13-wrapped-duo-\(chat.id).png"
                png(DuoWrappedStory(w: w, onJump: { _ in }, onExport: {}, onSavePDF: {}, scrolling: false, showsExportActions: false)
                        .background(AppTheme.Surface.page),
                    width: 760, height: 4600, name: name)
            }
            if wantedChat == nil, let chat = model.chats.filter({ $0.isGroup }).max(by: { $0.count < $1.count }),
               let w = try? await GroupWrappedBuilder.build(store: store, chatID: chat.id, me: "You", fetchTitles: withTitles) {
                await StoryArtwork.preload(w.tracks.compactMap(\.thumbnail))
                png(GroupWrappedStory(w: w, onJump: { _ in }, onExport: {}, onSavePDF: {}, scrolling: false, showsExportActions: false)
                        .background(AppTheme.Surface.page),
                    width: 760, height: 3200, name: "14-wrapped-group.png")
            }
            // The year story, in full. Its height follows the story, so the export path
            // used by the Export menu is the same one this checks (PNG and PDF).
            if let w = model.yearWrapped, let image = await YearStoryExport.image(for: w),
               let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("15-wrapped-year.png"))
                _ = YearStoryExport.writePDF(image, to: dir.appendingPathComponent("15-wrapped-year.pdf"))
            }
        }
        // Optional: the on-device AI surfaces (`--ai`). Ask is captured in the real inspector; Topics
        // and "Might need your reply" are hosted in parked windows so their own onAppear work
        // (saved topics, the reply scan) runs exactly as it does when the sheets are opened.
        if Self.aiCaptures {
            model.section = .chats
            let dm = model.chats.first(where: { !$0.isGroup && $0.name == "Priya Menon" })
                ?? model.chats.first(where: { !$0.isGroup })
            if let dm { model.openChat(dm) }
            model.aiPanel.openAsk(model: model)
            await shot("16-ask")
            model.aiPanel.open = false
            try? await Task.sleep(for: .milliseconds(400))
            if let dm = model.selected {
                await hostedShot(TopicsView(chat: dm).environment(model), name: "17-topics",
                                 size: NSSize(width: 720, height: 620))
            }
            await hostedShot(ReplyResponsibilityView().environment(model), name: "18-reply",
                             size: NSSize(width: 780, height: 640))
            await hostedShot(SettingsView().environment(model), name: "19-settings",
                             size: NSSize(width: 640, height: 520))
            await hostedShot(SettingsView(initialTab: .people).environment(model), name: "19-settings-people",
                             size: NSSize(width: 640, height: 560))
            await hostedShot(SettingsView(initialTab: .home).environment(model), name: "19-settings-home",
                             size: NSSize(width: 640, height: 360))
            await hostedShot(SettingsView(initialTab: .privacy).environment(model), name: "19-settings-privacy",
                             size: NSSize(width: 640, height: 760))
        }
        // Optional: the Settings ▸ Archive pane, which carries the version row and the switch.
        // Captured on its own because the Update row is the only way to see the feature without
        // waiting a day for a real launch check.
        if previewUpdate != nil {
            await hostedShot(SettingsView(initialTab: .archive).environment(model),
                             name: "19-settings-archive", size: NSSize(width: 680, height: 860))
        }
        // Optional: the first-run wizard (`--wizard`). Rendered without a library so the
        // setup flow can be reviewed without touching the real archive.
        if a.contains("--wizard") {
            for (step, name) in [(WizStep.start, "20-wizard-start"), (.connect, "21-wizard-phone"),
                                 (.encrypted, "22-wizard-encrypted"), (.backup, "23-wizard-backup"),
                                 (.key, "24-wizard-key")] {
                let host = NSHostingView(rootView: WizardView(startAt: step).environment(model))
                host.frame = NSRect(x: 0, y: 0, width: 940, height: 620)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                window.orderFront(nil)
                try? await Task.sleep(for: .seconds(3.2))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        NSApp.terminate(nil)
    }
}
