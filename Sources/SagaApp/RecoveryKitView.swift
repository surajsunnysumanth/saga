import SwiftUI
import AppKit
import SagaCore

/// One printable page: title, kit version, archive ID, full code in groups, restore steps.
/// Contains no message data, paths, passphrase or keys.
struct RecoveryKitPage: View {
    let material: RecoveryKitMaterial

    /// Groups of 4 for legibility, wrapped onto lines of 4 groups. Display only.
    static func groupedLines(_ code: String) -> [String] {
        let chars = Array(code)
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        return stride(from: 0, to: groups.count, by: 4).map { groups[$0..<min($0 + 4, groups.count)].joined(separator: "  ") }
    }

    var body: some View {
        let page = RecoveryKit.pageText(for: material)
        VStack(alignment: .leading, spacing: 18) {
            Text(page.header[0]).font(.system(size: 28, weight: .bold))
            Text(page.header[1]).font(.callout).foregroundStyle(.secondary)
            Text(page.header[2]).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Divider()
            Text("Recovery code").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.groupedLines(page.code).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.4)))
            Divider()
            Text(page.body).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(48)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(Color.white)
    }
}

enum RecoveryKitExporter {
    /// Renders the page in memory (no temp files).
    @MainActor static func pdfData(_ material: RecoveryKitMaterial) -> Data? {
        let renderer = ImageRenderer(content: RecoveryKitPage(material: material))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        var ok = false
        renderer.render { size, draw in
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = size.width > 0
        }
        return ok ? data as Data : nil
    }

    /// Clearly inside a synced/cloud location, where the plaintext kit would be uploaded.
    static func isCloudLocation(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return ["/Library/CloudStorage/", "/Library/Mobile Documents/", "/Dropbox", "/OneDrive", "/Google Drive"]
            .contains { p.contains($0) }
    }
}

struct RecoveryKitView: View {
    let material: RecoveryKitMaterial
    let onConfirm: (String) throws -> Void
    let onCancel: () -> Void

    @State private var state = RecoveryKitConfirmation()
    @State private var message: String?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save your Recovery Kit").font(.title2.bold())
            Text("This code is the only way back in if you forget your passphrase. Save or print the kit and keep it private and separate from the archive. Anyone with the kit and the encrypted archive can read it.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save PDF…", action: savePDF)
                Button("Print…", action: printKit)
                if state.hasExported { Label("Kit saved or printed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            if let warning { Text(warning).font(.callout).foregroundStyle(AppTheme.Feedback.warning) }
            Divider()
            Text("Type the full recovery code from your kit to confirm you have it:")
            TextField("Recovery code", text: $state.typedCode)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
            Toggle("I have stored this Recovery Kit somewhere safe", isOn: $state.hasSavedCopy)
                .disabled(!state.hasExported)
            if let message { Text(message).font(.callout).foregroundStyle(AppTheme.Feedback.error).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { state.clear(); onCancel() }.keyboardShortcut(.cancelAction)
                Button("Confirm") { confirm() }
                    .keyboardShortcut(.defaultAction).disabled(!state.canConfirm)
            }
        }
        .padding(24).frame(width: 520)
        .onDisappear { state.clear() }
    }

    private func confirm() {
        do { try state.confirm(onConfirm); message = nil }
        catch let e as RecoveryKitConfirmationError {
            switch e {
            case .notSaved: message = "Save or print the kit first, then try again."
            case .notAcknowledged: message = "Tick the box once the kit is stored safely."
            case .emptyCode: message = "Type the full recovery code from your kit."
            }
        } catch {
            // Core rejected the typed code or failed: nothing was enabled. Never echo the input.
            message = "That code does not match this kit. Check it against your saved copy and try again. Nothing has been changed."
        }
    }

    private func savePDF() {
        warning = nil
        guard let data = RecoveryKitExporter.pdfData(material) else {
            state.recordExport(.failed); message = "Could not create the PDF. Try again or use Print."; return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Saga Recovery Kit.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose a private location away from your archive."
        guard panel.runModal() == .OK, let url = panel.url else {
            state.recordExport(.cancelled); message = "Not saved. Save or print the kit to continue."; return
        }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            state.recordExport(.saved); message = nil
            if RecoveryKitExporter.isCloudLocation(url) {
                warning = "That folder looks synced to the cloud, so the code will be uploaded there. Consider moving it to a private place."
            }
        } catch {
            state.recordExport(.failed); message = "Could not write the file (\(error.localizedDescription)). Choose another location and retry."
        }
    }

    private func printKit() {
        warning = nil
        let host = NSHostingView(rootView: RecoveryKitPage(material: material))
        host.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        let op = NSPrintOperation(view: host, printInfo: info)
        // A completed job doesn't prove paper exists; the acknowledgement toggle still gates confirm.
        if op.run() { state.recordExport(.saved); message = nil }
        else { state.recordExport(.cancelled); message = "Printing did not complete. Retry, or save a PDF." }
    }
}
