import Foundation

public enum ExportFormat: String, CaseIterable, Sendable { case text = "Plain text (.txt)", html = "Web page (.html, printable)" }

/// Writes one chat to a file. Paged so large chats don't load into memory.
public enum ChatExporter {
    public static func export(store: VaultStore, chat: ChatRow, format: ExportFormat, to url: URL) throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url); defer { try? fh.close() }
        func w(_ s: String) { fh.write(Data(s.utf8)) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let dayF = DateFormatter(); dayF.dateStyle = .full
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        if format == .html {
            w("""
            <!doctype html><meta charset="utf-8"><title>\(esc(chat.name))</title>
            <style>body{font:15px -apple-system,Helvetica,sans-serif;max-width:720px;margin:24px auto;padding:0 16px;color:#111}
            h1{font-size:22px}.d{text-align:center;color:#777;margin:18px 0 6px;font-size:12px}
            .m{margin:3px 0;padding:6px 10px;border-radius:12px;max-width:80%;background:#eee;white-space:pre-wrap;word-wrap:break-word;break-inside:avoid}
            .me{margin-left:auto;background:#d6f5e6}.n{font-size:11px;font-weight:600;color:#0a7}.t{font-size:10px;color:#888;float:right;margin-left:10px}
            .x{color:#777;font-style:italic}@media print{.m{max-width:100%}}</style>
            <h1>\(esc(chat.name))</h1><p>\(chat.count) messages · exported from Saga</p>

            """)
        } else { w("Chat with \(chat.name)\nExported from Saga\n\n") }
        var lastDay = "", count = 0, afterTs: Int64 = -1, afterId: Int64 = -1
        while true {
            let page = try store.exportPage(chat: chat.id, afterTs: afterTs, afterId: afterId, limit: 5000)
            if page.isEmpty { break }
            for m in page.rows {
                let day = dayF.string(from: m.ts)
                let who = m.fromMe ? "Me" : m.sender
                let media = m.mediaKind.map { "[\($0)]" } ?? ""
                if format == .html {
                    if day != lastDay { w("<div class=\"d\">\(esc(day))</div>\n"); lastDay = day }
                    w("<div class=\"m\(m.fromMe ? " me" : "")\">")
                    if !m.fromMe && chat.isGroup { w("<div class=\"n\">\(esc(who))</div>") }
                    if !media.isEmpty { w("<span class=\"x\">\(esc(media))</span> ") }
                    w("\(esc(m.text))<span class=\"t\">\(esc(df.string(from: m.ts).suffix(5).description))</span></div>\n")
                } else {
                    if day != lastDay { w("\n--- \(day) ---\n"); lastDay = day }
                    w("[\(df.string(from: m.ts))] \(who): \([media, m.text].filter { !$0.isEmpty }.joined(separator: " "))\n")
                }
                count += 1
            }
            afterTs = page.lastTs; afterId = page.lastId
        }
        return count
    }
}
