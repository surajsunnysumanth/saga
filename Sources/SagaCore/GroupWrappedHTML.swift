import Foundation

/// Self-contained, escaped HTML for a group Wrapped: the export of the native story,
/// with the same copy helpers and the same palette as the duo page.
public enum GroupWrappedHTML {
    public static func render(_ w: GroupWrapped, interactive: Bool) -> String {
        typealias H = DuoWrappedHTML
        func jump(_ id: Int64) -> String { H.jump(id, interactive: interactive) }
        func bars(_ rows: [GroupWrapped.Contributor], of total: Int) -> String {
            let mx = max(rows.map(\.messages).max() ?? 1, 1)
            return rows.map { c in
                "<div class=\"vs\"><div class=\"vs-l\"><span>\(H.esc(c.name))</span><span><b>\(H.n(c.messages))</b> · \(H.pct(c.messages, total))%</span></div><div class=\"bar\"><span class=\"a\" style=\"width:\(H.pct(c.messages, mx))%\"></span></div></div>"
            }.joined()
        }
        let span = w.spanDays
        let range = (w.first.map { H.date($0, "MMMM yyyy") } ?? "") + " – " + (w.last.map { H.date($0, "MMMM yyyy") } ?? "")

        var body = """
        <section class="cover"><div class="eyebrow">Heartbeat</div>
        <h1>\(H.esc(w.name))</h1>
        <p class="lead">\(H.esc(range))</p>
        <div class="big">\(H.n(w.total))</div>
        <p class="sub">\(H.esc(WrappedCopy.groupOpening(name: w.name, total: w.total, contributors: w.contributors.count, spanDays: span, activeDays: w.activeDays)))</p>
        <div class="pill">\(H.esc(WrappedCopy.people(w.contributors.count))) · built on this Mac</div></section>
        """

        let voices = WrappedCopy.groupVoices(top: w.contributors.first?.name, topCount: w.contributors.first?.messages ?? 0,
                                             funniest: w.funniest.first?.name, laughs: w.funniest.first?.laughsEarned ?? 0,
                                             of: w.funniest.first?.messages ?? 0,
                                             runnerUpRate: w.witRunnerUpRate, roomRate: w.laughRate)
        body += """
        <section class="reveal"><div class="eyebrow">Who talks</div><h2>The room</h2>
        \(voices.map { "<p class=\"muted\">\(H.esc($0))</p>" } ?? "")
        \(bars(Array(w.contributors.prefix(10)), of: w.total))</section>
        """

        if !w.moments.isEmpty || !w.funniest.isEmpty {
            var moments = ""
            for m in w.moments {
                let count = m.reactors > 0 ? "  (\(m.reactors) \(m.reactors == 1 ? "react" : "reacts"))" : ""
                let replies = m.quoted.map { q in
                    H.bubble(author: q.author, text: q.text, mine: q.fromMe, compact: true)
                }.joined()
                moments += """
                <div class="moment"><div class="when">\(H.date(m.date, "EEEE, d MMMM yyyy"))</div>
                \(H.bubble(author: m.author, text: m.text + count, mine: false))
                \(m.reactionSummary.isEmpty ? "" : "<div class=\"muted\" style=\"font-size:12px\">\(H.esc(m.reactionSummary))</div>")
                \(replies.isEmpty ? "" : "<div style=\"margin-left:18px;display:flex;flex-direction:column;gap:6px\">\(replies)</div>")\(jump(m.messageID))</div>
                """
            }
            let rows = w.funniest.prefix(6).map { "<span class=\"tag\">\(H.esc($0.name))<i>\(H.n($0.laughsEarned))×</i></span>" }.joined()
            body += """
            <section class="reveal"><div class="eyebrow">The laugh track</div><h2>Who gets the laughs</h2>
            \(w.funniest.first.map { "<p class=\"muted\">\(H.esc($0.name)) drew \(H.esc(WrappedCopy.plural($0.laughsEarned, "laugh"))) from the room.</p>" } ?? "")
            <div class="tags">\(rows)</div>
            \(moments.isEmpty ? "" : "<h3>The most hilarious moments</h3>\(moments)")</section>
            """
        }

        if w.heartsByReaction > 0 {
            let loved = w.loved.map { m in
                """
                <div class="moment"><div class="when">\(H.date(m.date, "EEEE, d MMMM yyyy"))</div>
                \(H.bubble(author: m.author, text: m.text, mine: false))
                \(H.bubble(author: m.replyBy, text: "❤️", mine: true, compact: true))\(jump(m.messageID))</div>
                """
            } ?? ""
            body += """
            <section class="reveal"><div class="eyebrow">The heart track</div><h2>What the room loved</h2>
            <p class="muted">\(H.esc(WrappedCopy.plural(w.heartsByReaction, "message"))) earned a heart from someone else.</p>
            \(loved)</section>
            """
        }

        if !w.stickers.isEmpty {
            let s = w.stickers
            let copy = WrappedCopy.stickers(total: s.total, distinct: s.distinct, topCount: s.topCount) ?? ""
            let top = s.top.first.map { t in
                "<p class=\"muted\">The busiest one is the same file every time; its SHA-256 is <code>\(H.esc(t.hash))</code>.</p>"
            } ?? ""
            body += """
            <section class="reveal"><div class="eyebrow">Stickers</div><h2>What did the talking</h2>
            <p class="muted">\(H.esc(copy))</p>
            \(H.stats([(H.n(s.total), "stickers sent"), (H.n(s.distinct), "different ones"), (H.n(s.topCount) + "×", "the busiest one")]))
            \(top)</section>
            """
        }

        if w.hasMusic {
            var cards = ""
            for (i, t) in w.tracks.enumerated() {
                let title = t.title ?? "\(t.service.rawValue) \(t.kind)"
                let h = t.service == .spotify ? (t.kind == "track" || t.kind == "episode" ? 152 : 352)
                    : t.service == .appleMusic ? (t.kind == "track" ? 175 : 450)
                    : t.service == .soundCloud ? (t.kind == "playlist" ? 450 : 166) : 215
                let art = t.thumbnail.map { "<img src=\"\(H.esc($0))\" alt=\"\" loading=\"lazy\">" } ?? "<div class=\"ph\">♪</div>"
                cards += """
                <div class="track"><div class="trow">\(art)<div class="tmeta"><div class="ttitle">\(H.esc(title))</div>\(t.author.map { "<div class=\"tby\">\(H.esc($0))</div>" } ?? "")
                <div class="tsub">\(H.esc(t.service.rawValue)) · \(H.esc(WrappedCopy.trackDetail(by: t.firstBy, date: t.firstDate, times: t.times)))</div></div></div>
                <div id="p\(i)" class="player">\(t.embed.isEmpty ? "" : "<button class=\"play\" onclick=\"play('p\(i)','\(H.esc(t.embed))',\(h))\">▶ Play here</button> ")<a class="open" href="\(H.esc(t.url))" target="_blank" rel="noopener">Open in \(H.esc(t.service.rawValue))</a> \(jump(t.messageID))</div></div>
                """
            }
            let top = w.linkSharers.first
            let copy = WrappedCopy.groupSoundtrack(total: w.linksTotal, sharers: w.linkSharers.count,
                                                   top: top?.name, topCount: top?.messages ?? 0)
            body += """
            <section class="reveal"><div class="eyebrow">The soundtrack</div><h2>What the room was playing</h2>
            \(copy.map { "<p class=\"muted\">\(H.esc($0))</p>" } ?? "")
            <div class="tracks">\(cards)</div></section>
            """
        }

        if !w.insideJokes.isEmpty {
            let jokes = w.insideJokes.map { "<span class=\"tag\">\(H.esc($0.text))<i>\(H.n($0.count))×</i></span>" }.joined()
            body += """
            <section class="reveal"><div class="eyebrow">Inside jokes</div><h2>The group's own language</h2>
            \(WrappedCopy.jokes(count: w.insideJokes.count, top: w.insideJokes.first?.text, topCount: w.insideJokes.first?.count ?? 0).map { "<p class=\"muted\">\(H.esc($0))</p>" } ?? "")
            <div class="tags">\(jokes)</div></section>
            """
        }

        if !w.emoji.isEmpty {
            let pair = w.emojiPair
            let big = pair.map { $0.a + $0.b } ?? w.emoji[0].text
            let line = pair.map { WrappedCopy.emojiPair(a: $0.a, b: $0.b, count: $0.count) } ?? "The emoji this group actually types."
            let row = w.emoji.map { "<span class=\"emo\">\(H.esc($0.text))<i>\(H.n($0.count))</i></span>" }.joined()
            body += """
            <section class="reveal"><div class="eyebrow">Emoji</div><h2>\(pair == nil ? "Favourites" : "The group's pair")</h2>
            <div class="emoji-big">\(H.esc(big))</div><p class="muted">\(H.esc(line))</p><div>\(row)</div></section>
            """
        }

        body += """
        <section class="reveal"><div class="eyebrow">\(span < 400 ? "Over the months" : "Over the years")</div><h2>The shape of it</h2>
        \(H.chart(w.monthly))
        \(w.peakMonth.map { "<p class=\"muted\">\(H.esc(H.month($0.month))) was the loudest: <b>\(H.esc(WrappedCopy.plural($0.count, "message")))</b>.</p>" } ?? "")
        \(H.stats([(H.n(w.activeDays), H.esc(WrappedCopy.noun(w.activeDays, "day")) + " with a message"),
                   (H.n(w.contributors.count), H.esc(WrappedCopy.noun(w.contributors.count, "person", "people")) + " who took part")]))</section>
        <section class="outro reveal"><div class="big small">\(H.n(w.total))</div>
        <p class="sub">messages from \(H.esc(WrappedCopy.people(w.contributors.count))).</p>
        <p class="muted">Made with Saga, entirely on one Mac.</p></section>
        """

        return H.page(title: "\(w.name): Heartbeat", body: body)
    }
}
