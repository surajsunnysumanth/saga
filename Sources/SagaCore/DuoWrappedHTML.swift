import Foundation

/// Renders a DuoWrapped as one self-contained HTML page (no external files).
///
/// This is the *export* of the story shown natively in the app: the same stats, the
/// same `WrappedCopy` sentences, the same WhatsApp palette (`docs/DESIGN.md`), so a
/// saved page looks like the thing that was on screen. `interactive` adds
/// jump-to-message buttons that only work inside Saga; the exported copy omits them.
/// Players load from Spotify/YouTube/Apple only when someone presses play.
public enum DuoWrappedHTML {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func date(_ d: Date, _ f: String = "d MMM yyyy") -> String { WrappedCopy.date(d, f) }
    static func month(_ k: String) -> String { WrappedCopy.month(k) }
    static func dur(_ s: Double?) -> String { WrappedCopy.duration(s) }

    /// "Your typical reply", not "You's typical reply".
    static func possessive(_ name: String) -> String {
        name.lowercased() == "you" ? "Your" : "\(name)'s"
    }
    static func n(_ i: Int) -> String { WrappedCopy.n(i) }
    static func pct(_ a: Int, _ b: Int) -> Int { WrappedCopy.pct(a, of: b) }
    static let weekdays = ["", "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
    static func hour(_ h: Int) -> String { WrappedCopy.hour(h) }

    // MARK: - Building blocks

    static func jump(_ id: Int64, interactive: Bool) -> String {
        interactive && id > 0
            ? "<button class=\"jump\" onclick=\"window.webkit.messageHandlers.jump.postMessage(\(id))\">See it in the chat ↪</button>"
            : ""
    }

    static func vs(_ title: String, _ a: String, _ av: Int, _ b: String, _ bv: Int, unit: String = "") -> String {
        let t = max(av + bv, 1), ap = pct(av, t)
        return """
        <div class="vs"><div class="vs-t">\(esc(title))</div>
        <div class="bar"><span class="a" style="width:\(ap)%"></span><span class="b" style="width:\(100 - ap)%"></span></div>
        <div class="vs-l"><span>\(esc(a)) <b>\(n(av))\(unit)</b></span><span><b>\(n(bv))\(unit)</b> \(esc(b))</span></div></div>
        """
    }

    static func stats(_ items: [(String, String)]) -> String {
        "<div class=\"chips\">" + items.map { "<div class=\"chip\"><b>\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined() + "</div>"
    }

    static func chart(_ m: [(month: String, count: Int)]) -> String {
        guard !m.isEmpty else { return "" }
        let mx = max(m.map(\.count).max() ?? 1, 1), bw = 100.0 / Double(m.count)
        var bars = ""
        for (i, x) in m.enumerated() {
            let h = max(1.0, 60.0 * Double(x.count) / Double(mx))
            bars += "<rect x=\"\(String(format: "%.2f", Double(i) * bw))\" y=\"\(String(format: "%.1f", 62 - h))\" width=\"\(String(format: "%.2f", max(bw - 0.25, 0.2)))\" height=\"\(String(format: "%.1f", h))\" rx=\"0.4\"><title>\(esc(month(x.month))): \(x.count)</title></rect>"
        }
        let marks = m.count > 2 ? [m.first!.month, m[m.count / 2].month, m.last!.month] : [m.first!.month, m.last!.month]
        let axis = marks.map { "<span>\(esc(month($0)))</span>" }.joined()
        return "<svg class=\"chart\" viewBox=\"0 0 100 64\" preserveAspectRatio=\"none\">\(bars)</svg><div class=\"axis\">\(axis)</div>"
    }

    static func bubble(author: String, text: String, mine: Bool, compact: Bool = false) -> String {
        "<div class=\"bubble \(mine ? "me" : "them")\(compact ? " sm" : "")\"><b>\(esc(author))</b>\(esc(WrappedCopy.quote(text)))</div>"
    }

    // MARK: - Page

    public static func render(_ w: DuoWrapped, interactive: Bool) -> String {
        var body = ""

        // Cover
        let pace = w.bestYear.flatMap { WrappedCopy.pace(count: $0.count, year: $0.year, activeDays: $0.activeDays) }
        let sub = [WrappedCopy.opening(total: w.total),
                   WrappedCopy.span(spanDays: w.spanDays, activeDays: w.activeDays, first: w.first),
                   pace].compactMap { $0 }.joined(separator: " ")
        body += """
        <section class="cover"><div class="eyebrow">Heartbeat</div>
        <h1>\(esc(w.me)) <span class="amp">&amp;</span> \(esc(w.them))</h1>
        <p class="lead">\(date(w.first, "MMMM yyyy")) – \(date(w.last, "MMMM yyyy"))</p>
        <div class="big">\(n(w.total))</div><p class="sub">\(esc(sub))</p>
        <div class="pill">Built on this Mac. Nothing left it.</div></section>
        """

        // How it started
        if let f = w.firstText {
            body += """
            <section class="reveal"><div class="eyebrow">The first message</div><h2>How it started</h2>
            <p class="muted">\(date(f.date, "EEEE, d MMMM yyyy"))</p>
            \(bubble(author: f.author, text: f.text, mine: f.author == w.me))
            <p class="muted">\(esc(WrappedCopy.firstKicker(text: f.text)))</p></section>
            """
        }

        // Balance
        let balance = WrappedCopy.balance(me: w.me, them: w.them, mine: w.mine, theirs: w.theirs)
        var split = vs("Messages sent", w.me, w.mine, w.them, w.theirs)
        split += vs("Words typed", w.me, w.wordsMine, w.them, w.wordsTheirs)
        split += vs("Conversations started", w.me, w.startsMine, w.them, w.startsTheirs)
        let race = WrappedCopy.replyRace(me: w.me, them: w.them, mine: w.medianReplyMine, theirs: w.medianReplyTheirs,
                                         mineSamples: w.replyCountMine, theirsSamples: w.replyCountTheirs,
                                         mineSlow: w.slowReplyMine, theirsSlow: w.slowReplyTheirs)
        body += """
        <section class="reveal"><div class="eyebrow">Who carries it</div><h2>The split</h2>
        \(balance.map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
        \(split)
        <div class="chips">
        <div class="chip"><b>\(dur(w.medianReplyMine))</b><span>your typical reply</span></div>
        <div class="chip"><b>\(dur(w.medianReplyTheirs))</b><span>\(esc(possessive(w.them))) typical reply</span></div>
        </div>
        \(race.map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")</section>
        """

        // Laughs
        if w.funniest.count > 0 || w.madeThemLaugh + w.madeMeLaugh > 0 {
            var moments = ""
            for m in w.funniest {
                let mine = m.author == w.me
                let count = m.reactors > 0 ? "  (\(m.reactors) \(m.reactors == 1 ? "react" : "reacts"))" : ""
                let replies = m.quoted.map { q in
                    bubble(author: q.author, text: q.text, mine: q.fromMe, compact: true)
                }.joined()
                moments += """
                <div class="moment"><div class="when">\(date(m.date, "EEEE, d MMMM yyyy"))</div>
                \(bubble(author: m.author, text: m.text + count, mine: mine))
                \(m.reactionSummary.isEmpty ? "" : "<div class=\"muted\" style=\"font-size:12px\">\(esc(m.reactionSummary))</div>")
                \(replies.isEmpty ? "" : "<div style=\"margin-left:18px;display:flex;flex-direction:column;gap:6px\">\(replies)</div>")
                \(jump(m.messageID, interactive: interactive))</div>
                """
            }
            let copy = WrappedCopy.laughs(me: w.me, them: w.them, madeThemLaugh: w.madeThemLaugh,
                                          madeMeLaugh: w.madeMeLaugh, peakMonth: w.laughMonth.map { (month: $0.month, count: $0.count) })
            body += """
            <section class="reveal"><div class="eyebrow">The laugh track</div><h2>What landed</h2>
            <p class="muted">\(esc(copy))</p>
            \(w.madeThemLaugh + w.madeMeLaugh > 0 ? vs("Laughs earned from the other one", w.me, w.madeThemLaugh, w.them, w.madeMeLaugh, unit: "×") : "")
            \(moments.isEmpty ? "" : "<h3>The most hilarious moments</h3>\(moments)")</section>
            """
        }

        // Hearts
        if w.heartsMine + w.heartsTheirs > 0 {
            let copy = WrappedCopy.hearts(me: w.me, them: w.them, mine: w.heartsMine, theirs: w.heartsTheirs) ?? ""
            let loved = w.loved.map { l -> String in
                let mine = l.author == w.me
                return """
                <div class="moment"><div class="when">\(date(l.date, "EEEE, d MMMM yyyy"))</div>
                \(bubble(author: l.author, text: l.text, mine: mine))
                \(bubble(author: l.by, text: "❤️" + (l.count > 1 ? " ×\(n(l.count))" : ""), mine: l.by == w.me, compact: true))
                \(jump(l.messageID, interactive: interactive))</div>
                """
            } ?? ""
            body += """
            <section class="reveal"><div class="eyebrow">The heart track</div><h2>What you loved</h2>
            <p class="muted">\(esc(copy))</p>
            \(vs("Messages that earned a heart", w.me, w.heartsMine, w.them, w.heartsTheirs, unit: "❤"))
            \(loved)</section>
            """
        }

        // Soundtrack
        if w.hasMusic {
            var cards = ""
            for (i, t) in w.tracks.enumerated() {
                let title = t.title ?? "\(t.service.rawValue) \(t.kind)"
                let h = t.service == .spotify ? (t.kind == "track" || t.kind == "episode" ? 152 : 352)
                    : t.service == .appleMusic ? (t.kind == "track" ? 175 : 450)
                    : t.service == .soundCloud ? (t.kind == "playlist" ? 450 : 166) : 215
                let art = t.thumbnail.map { "<img src=\"\(esc($0))\" alt=\"\" loading=\"lazy\">" } ?? "<div class=\"ph\">♪</div>"
                cards += """
                <div class="track"><div class="role">\(esc(t.role))</div>
                <div class="trow">\(art)
                <div class="tmeta"><div class="ttitle">\(esc(title))</div>\(t.author.map { "<div class=\"tby\">\(esc($0))</div>" } ?? "")
                <div class="tsub">\(esc(t.service.rawValue)) · \(esc(WrappedCopy.trackDetail(by: t.firstBy, date: t.firstDate, times: t.times)))</div></div></div>
                \(t.reaction.isEmpty ? "" : bubble(author: t.reactionBy, text: t.reaction, mine: t.reactionBy == w.me, compact: true))
                <div id="p\(i)" class="player">\(t.embed.isEmpty ? "" : "<button class=\"play\" onclick=\"play('p\(i)','\(esc(t.embed))',\(h))\">▶ Play here</button> ")<a class="open" href="\(esc(t.url))" target="_blank" rel="noopener">Open in \(esc(t.service.rawValue))</a> \(jump(t.messageID, interactive: interactive))</div></div>
                """
            }
            let dj = w.linksMine >= w.linksTheirs ? w.me : w.them
            let copy = WrappedCopy.soundtrack(me: w.me, them: w.them, total: w.linksTotal,
                                              mine: w.linksMine, theirs: w.linksTheirs, twins: w.twinTracks)
            body += """
            <section class="reveal"><div class="eyebrow">Your soundtrack</div><h2>What you sent each other</h2>
            \(copy.map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
            \(stats([(n(w.linksTotal), "songs & videos shared"), (dj, "shared most of them")] + (w.twinTracks > 0 ? [(n(w.twinTracks), "sent by both of you")] : [])))
            \(vs("Shared", w.me, w.linksMine, w.them, w.linksTheirs))
            <div class="tracks">\(cards)</div></section>
            """
        }

        // Stickers — counted, never quoted
        if !w.stickers.isEmpty {
            let s = w.stickers
            let copy = WrappedCopy.stickers(total: s.total, distinct: s.distinct, topCount: s.topCount) ?? ""
            let top = s.top.first.map { t in
                "<p class=\"muted\">The busiest one is the same file every time; its SHA-256 is <code>\(esc(t.hash))</code>.</p>"
            } ?? ""
            body += """
            <section class="reveal"><div class="eyebrow">Stickers</div><h2>What did the talking</h2>
            <p class="muted">\(esc(copy))</p>
            \(stats([(n(s.total), "stickers sent"), (n(s.distinct), "different ones"), (n(s.topCount) + "×", "the busiest one")]))
            \(top)</section>
            """
        }

        // Inside jokes
        if !w.insideJokes.isEmpty || !w.myWords.isEmpty || !w.theirWords.isEmpty {
            let jokes = w.insideJokes.map { "<span class=\"tag\">\(esc($0.text))<i>\(n($0.count))×</i></span>" }.joined()
            func words(_ p: [DuoWrapped.Phrase]) -> String {
                p.map { "<span class=\"tag small\">\(esc($0.text))<i>\(n($0.count))</i></span>" }.joined()
            }
            let copy = WrappedCopy.jokes(count: w.insideJokes.count, top: w.insideJokes.first?.text, topCount: w.insideJokes.first?.count ?? 0)
            body += """
            <section class="reveal"><div class="eyebrow">Inside jokes</div><h2>Words that only mean something here</h2>
            \(copy.map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
            <div class="tags">\(jokes.isEmpty ? "<span class=\"muted\">No obvious catchphrases. Suspiciously normal.</span>" : jokes)</div>
            \(w.myWords.isEmpty && w.theirWords.isEmpty ? "" : "<h3>Signature words</h3><div class=\"two\"><div><div class=\"who\">\(esc(w.me))</div><div class=\"tags\">\(words(w.myWords))</div></div><div><div class=\"who\">\(esc(w.them))</div><div class=\"tags\">\(words(w.theirWords))</div></div></div>")</section>
            """
        }

        // Emoji
        if !w.emojiTogether.isEmpty {
            func row(_ p: [DuoWrapped.Phrase]) -> String {
                p.map { "<span class=\"emo\">\(esc($0.text))<i>\(n($0.count))</i></span>" }.joined()
            }
            let pair = w.emojiPair
            let big = pair.map { $0.a + $0.b } ?? w.emojiTogether[0].text
            let line = pair.map { WrappedCopy.emojiPair(a: $0.a, b: $0.b, count: $0.count) }
                ?? WrappedCopy.emojiLeaders(me: w.me, them: w.them, mine: w.emojiMine.first?.text, theirs: w.emojiTheirs.first?.text)
            body += """
            <section class="reveal"><div class="eyebrow">Emoji</div><h2>\(pair == nil ? "Your favourites" : "Your pair")</h2>
            <div class="emoji-big">\(esc(big))</div>
            \(line.map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
            <div class="two"><div><div class="who">\(esc(w.me))</div>\(row(w.emojiMine))</div><div><div class="who">\(esc(w.them))</div>\(row(w.emojiTheirs))</div></div></section>
            """
        }

        // Years
        var yearNotes = ""
        if let q = w.quietestYear {
            let next = w.byYear.first { $0.year == q.year + 1 }
            if let line = WrappedCopy.quietYear(year: q.year, count: q.count, nextYear: next?.year, nextCount: next?.count) {
                yearNotes += "<div class=\"quote\"><b>Quiet year</b>\(esc(line))</div>"
            }
        }
        if let owl = w.nightOwl {
            yearNotes += """
            <div class="quote"><b>\(esc(WrappedCopy.nightOwlLead(author: owl.author, hour: owl.hour, minute: owl.minute, on: owl.date)))</b>
            \(esc(WrappedCopy.quote(owl.text)))\(jump(owl.messageID, interactive: interactive))</div>
            """
        }
        body += """
        <section class="reveal"><div class="eyebrow">\(w.spanDays < 400 ? "Over the months" : "Over the years")</div><h2>The shape of it</h2>
        \(chart(w.monthly))
        \(WrappedCopy.peakMonth(month: w.peakMonth?.month ?? "", count: w.peakMonth?.count ?? 0, total: w.total).map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
        \(stats([(hour(w.busiestHour), "your favourite hour"), (weekdays[w.busiestWeekday], "busiest day of the week"),
                 (w.busiestDay.map { n($0.count) } ?? "—", w.busiestDay.map { "messages on \(date($0.date, "d MMM yyyy"))" } ?? "busiest day"),
                 ("\(n(w.longestStreak)) days", "longest daily streak")]))
        \(WrappedCopy.night(me: w.me, them: w.them, mine: w.nightMine, theirs: w.nightTheirs).map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
        \(yearNotes)
        \(WrappedCopy.gap(days: w.longestGapDays, from: w.gapFrom, to: w.gapTo, brokenBy: w.gapBrokenBy).map { "<p class=\"muted\">\(esc($0))</p>" } ?? "")
        </section>
        """

        // Superlatives
        let essay = (w.longestMine?.text.count ?? 0) >= (w.longestTheirs?.text.count ?? 0)
        let longest = essay ? w.longestMine : w.longestTheirs
        let longestWho = essay ? w.me : w.them
        var sup = WrappedCopy.longestMessage(me: w.me, them: w.them,
                                             mine: w.longestMine?.text.count ?? 0, theirs: w.longestTheirs?.text.count ?? 0)
            .map { "<p class=\"muted\">\(esc($0))</p>" } ?? ""
        if let l = longest {
            sup += "<h3>The longest one — \(esc(longestWho)), \(date(l.date))</h3>\(bubble(author: longestWho, text: l.text, mine: essay))\(jump(l.messageID, interactive: interactive))"
        }
        let mediaItems = [(w.photos.mine + w.photos.theirs, "photos"), (w.videos.mine + w.videos.theirs, "videos"),
                          (w.voice.mine + w.voice.theirs, "voice notes"), (w.docs.mine + w.docs.theirs, "documents")].filter { $0.0 > 0 }
        body += """
        <section class="reveal"><div class="eyebrow">Little superlatives</div><h2>For the record</h2>
        \(mediaItems.isEmpty ? "" : stats(mediaItems.map { (n($0.0), $0.1) }))\(sup)</section>
        <section class="outro reveal"><div class="big small">\(n(w.total))</div><p class="sub">messages and still going.</p><p class="muted">Made with Saga, entirely on one Mac.</p></section>
        """

        return page(title: "\(w.me) & \(w.them): Wrapped", body: body)
    }

    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(esc(title))</title><style>\(css)</style></head><body>
        <main>\(body)</main>
        <script>\(js)</script></body></html>
        """
    }

    // MARK: - Scripts and styles

    static let js = """
    function play(id, src, h) {
      if (!src) { return; }                                     // unresolved share links have no embed
      var el = document.getElementById(id); if (!el) { return; }
      var old = el.querySelector('iframe'); if (old) { old.remove(); return; }
      document.querySelectorAll('.player iframe').forEach(function(f) { f.remove(); });   // one player at a time
      var f = document.createElement('iframe');
      f.src = src; f.width = '100%'; f.height = h; f.setAttribute('frameborder', '0');
      f.allow = 'autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture'; f.allowFullscreen = true;
      f.setAttribute('referrerpolicy', 'strict-origin-when-cross-origin'); f.style.borderRadius = '12px'; f.style.marginTop = '10px'; f.style.display = 'block';
      el.appendChild(f);
    }
    var io = new IntersectionObserver(function(es) { es.forEach(function(e) { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }); }, { threshold: 0.12 });
    document.querySelectorAll('.reveal').forEach(function(el) { io.observe(el); });
    """

    /// The app's palette, as CSS: WhatsApp teal, one green accent, paper, hairlines.
    static let css = """
    :root { --teal:#075E54; --teal-deep:#054C44; --green:#25D366; --green-soft:#DCF8C6; --green-ink:#128C7E;
            --ink:#0B141A; --ink-soft:#54656F; --line:#E9EDEF; --paper:#F7F8F6; --surface:#fff; --field:#F1F3F1; --fern:#2E8E7D; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--paper); color:var(--ink);
           font:16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
           -webkit-font-smoothing:antialiased; }
    main { max-width:740px; margin:0 auto; padding:28px 20px 64px; display:flex; flex-direction:column; gap:18px; }
    section { background:var(--surface); border:1px solid var(--line); border-radius:20px; padding:32px 24px;
              display:flex; flex-direction:column; gap:12px; box-shadow:0 1px 2px rgba(11,20,26,.05), 0 12px 32px rgba(11,20,26,.06); }
    section.cover { background:linear-gradient(135deg, var(--teal) 0%, var(--fern) 100%); border:0; color:#fff;
                    padding:40px 28px; gap:8px; }
    section.outro { text-align:center; align-items:center; }
    .eyebrow { letter-spacing:.14em; text-transform:uppercase; font-size:11px; font-weight:600; color:var(--ink-soft); }
    .cover .eyebrow { color:rgba(255,255,255,.72); }
    h1 { font-size:clamp(32px,7vw,46px); line-height:1.08; margin:0; letter-spacing:-.02em; font-weight:700; }
    .amp { color:var(--green); }
    h2 { font-size:clamp(22px,4.6vw,28px); margin:0; letter-spacing:-.01em; }
    h3 { margin:16px 0 2px; font-size:14px; color:var(--ink-soft); font-weight:600; text-transform:uppercase; letter-spacing:.08em; }
    .lead { color:rgba(255,255,255,.72); font-size:14px; margin:0; }
    .big { font-size:clamp(56px,15vw,92px); font-weight:800; letter-spacing:-.045em; line-height:1; margin-top:18px;
           color:#fff; font-variant-numeric:tabular-nums; }
    .big.small { font-size:64px; color:var(--ink); }
    .sub { font-size:15px; color:rgba(255,255,255,.88); margin:0; max-width:52ch; }
    .outro .sub { color:var(--ink-soft); }
    .muted { color:var(--ink-soft); margin:0; }
    .pill { align-self:flex-start; margin-top:10px; font-size:11px; letter-spacing:.04em;
            background:rgba(255,255,255,.14); border-radius:99px; padding:5px 12px; color:rgba(255,255,255,.92); }
    .bubble { max-width:86%; padding:9px 13px; border-radius:15px; font-size:14.5px; white-space:pre-wrap; word-wrap:break-word; }
    .bubble b { display:block; font-size:9px; letter-spacing:.07em; text-transform:uppercase; opacity:.65; margin-bottom:2px; }
    .bubble.me { align-self:flex-end; background:var(--green-soft); color:var(--ink); border-bottom-right-radius:5px; }
    .bubble.them { align-self:flex-start; background:var(--field); color:var(--ink); border:1px solid var(--line); border-bottom-left-radius:5px; }
    .bubble.sm { font-size:13px; }
    .vs { margin:6px 0; }
    .vs-t { font-size:12px; color:var(--ink-soft); margin-bottom:5px; }
    .bar { display:flex; height:9px; border-radius:99px; overflow:hidden; gap:2px; background:var(--line); }
    .bar .a { background:var(--green-ink); } .bar .b { background:var(--fern); opacity:.9; }
    .vs-l { display:flex; justify-content:space-between; font-size:12px; margin-top:5px; color:var(--ink-soft); }
    .vs-l b { font-size:14px; color:var(--ink); font-variant-numeric:tabular-nums; }
    .chips { display:flex; flex-wrap:wrap; gap:8px; margin:2px 0; }
    .chip { background:var(--field); border-radius:12px; padding:11px 13px; min-width:126px; flex:1; }
    .chip b { display:block; font-size:20px; letter-spacing:-.01em; font-variant-numeric:tabular-nums; }
    .chip span { font-size:12px; color:var(--ink-soft); }
    .moment { display:flex; flex-direction:column; gap:6px; margin:12px 0 20px; }
    .when { font-size:12px; color:var(--ink-soft); }
    .quote { background:rgba(46,142,125,.07); border-left:3px solid var(--fern); border-radius:10px;
             padding:12px 14px; display:flex; flex-direction:column; gap:4px; }
    .quote b { font-size:12px; color:var(--ink-soft); font-weight:600; }
    .tracks { display:flex; flex-direction:column; gap:10px; margin-top:4px; }
    .track { background:var(--field); border:1px solid var(--line); border-radius:16px; padding:13px; display:flex; flex-direction:column; gap:9px; }
    .role { align-self:flex-start; font-size:9px; letter-spacing:.08em; text-transform:uppercase; font-weight:700;
            color:var(--green-ink); background:var(--green-soft); padding:3px 9px; border-radius:99px; }
    .trow { display:flex; gap:12px; align-items:center; }
    .trow img, .ph { width:56px; height:56px; border-radius:9px; object-fit:cover; background:var(--surface);
                    display:flex; align-items:center; justify-content:center; font-size:22px; flex:none; }
    .ttitle { font-weight:650; line-height:1.3; } .tby { color:var(--ink-soft); font-size:13px; }
    .tsub { font-size:11.5px; color:var(--ink-soft); margin-top:2px; }
    .play, .jump { cursor:pointer; border:0; border-radius:99px; padding:6px 12px; font:inherit; font-size:12px;
                   background:var(--green-soft); color:var(--teal-deep); font-weight:600; }
    .jump { background:transparent; color:var(--green-ink); padding:4px 0; }
    .open { color:var(--green-ink); font-size:13px; text-decoration:none; }
    .player { display:flex; flex-wrap:wrap; align-items:center; gap:10px; }
    .tags { display:flex; flex-wrap:wrap; gap:7px; margin:4px 0; }
    .tag { background:var(--green-soft); border-radius:99px; padding:6px 12px; font-size:15px; color:var(--teal-deep); }
    .tag.small { font-size:13px; padding:4px 10px; }
    .tag i { font-style:normal; font-size:11px; color:var(--ink-soft); margin-left:6px; }
    .two { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
    .who { font-size:10px; text-transform:uppercase; letter-spacing:.08em; color:var(--ink-soft); margin-bottom:3px; }
    .emoji-big { font-size:84px; text-align:center; line-height:1.15; }
    .emo { display:inline-block; font-size:26px; margin-right:10px; }
    .emo i { font-style:normal; font-size:11px; color:var(--ink-soft); margin-left:3px; }
    .chart { width:100%; height:150px; fill:var(--green-ink); }
    .axis { display:flex; justify-content:space-between; font-size:11px; color:var(--ink-soft); }
    .reveal { opacity:0; transform:translateY(16px); transition:opacity .6s ease, transform .6s ease; }
    .reveal.in { opacity:1; transform:none; }
    @media (prefers-reduced-motion: reduce) { .reveal { opacity:1; transform:none; transition:none; } }
    @media print { .reveal { opacity:1 !important; transform:none !important; } .play, .jump { display:none; }
                   main { gap:0; padding:0; } section { break-inside:avoid; border-radius:0; box-shadow:none; } }
    @media (max-width:460px) { .two { grid-template-columns:1fr; } }
    """
}
