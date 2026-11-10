import SwiftUI
import AppKit

/// A tiny beat runner. Each illustration declares its beats and the phase it
/// should end on; Reduce Motion jumps straight to the end frame.
@MainActor @Observable
final class ArtTimeline {
    private(set) var phase = 0
    private var task: Task<Void, Never>?

    func run(beats: [Double], restingPhase: Int) {
        task?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            phase = restingPhase
            return
        }
        phase = 0
        task = Task { [weak self] in
            for (index, pause) in beats.enumerated() {
                try? await Task.sleep(for: .seconds(pause))
                if Task.isCancelled { return }
                self?.phase = index + 1
            }
        }
    }

    func stop() { task?.cancel(); phase = 0 }

    /// Snap to a phase, for when the real world gets there before the animation does.
    func jump(to value: Int) { task?.cancel(); phase = value }
}

// MARK: - Drawing helpers

private enum Ink {
    static let phone = Color(red: 0.07, green: 0.11, blue: 0.13)
    static let edge = Color(red: 0.22, green: 0.31, blue: 0.35)
    static let row = Color(red: 0.075, green: 0.125, blue: 0.157)
    static let accent = Color(red: 0.145, green: 0.83, blue: 0.4)
    static let mint = Color(red: 0.37, green: 0.85, blue: 0.56)
    static let accentSoft = Color(red: 0.078, green: 0.208, blue: 0.157)
    static let label = Color(red: 0.62, green: 0.7, blue: 0.73)
    static let bright = Color(red: 0.91, green: 0.93, blue: 0.94)
    static let dim = Color(red: 0.2, green: 0.26, blue: 0.29)
}

private func card(_ rect: CGRect, _ radius: CGFloat = 8, fill: Color = Ink.row, stroke: Color = Ink.edge, width: CGFloat = 1) -> Path {
    Path(roundedRect: rect, cornerRadius: radius)
}

// MARK: - Scene 1: developer settings

struct DevSettingsArt: View {
    var phase: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 430)
            context.scaleBy(x: scale, y: scale)

            let phone = CGRect(x: 42, y: 4, width: 216, height: 422)
            context.stroke(card(phone, 30, fill: Ink.phone, stroke: Ink.edge, width: 2), with: .color(Ink.edge), lineWidth: 2)
            context.fill(card(phone.insetBy(dx: 16, dy: 42), 14, fill: Color(red: 0.043, green: 0.078, blue: 0.102)), with: .color(.black))
            drawText("Settings", at: CGPoint(x: 72, y: 72), in: &context, color: Ink.bright, size: 12, weight: .semibold)

            let rows: [(String, CGFloat)] = [
                ("About phone", 84), ("Software information", 118), ("Build number", 152),
                ("Developer options", 186), ("USB debugging", 220)
            ]
            for (index, row) in rows.enumerated() {
                let y = row.1
                let dimmed = (index == 3 && phase < 2) || (index == 4 && phase < 2)
                let hot = (index == 0 && phase == 0) || (index == 2 && phase == 1) || (index == 4 && phase >= 2)
                let fill = hot ? Ink.accentSoft : Ink.row
                let stroke = hot ? Ink.mint : Ink.edge
                context.fill(card(CGRect(x: 70, y: y, width: 160, height: 28), 8, fill: fill), with: .color(fill))
                context.stroke(card(CGRect(x: 70, y: y, width: 160, height: 28), 8), with: .color(stroke), lineWidth: 1)
                drawText(row.0, at: CGPoint(x: 80, y: y + 10), in: &context,
                         color: dimmed ? Ink.label.opacity(0.35) : Ink.bright, size: 11, weight: hot ? .semibold : .regular)
                if index == 2, phase == 1, phaseTaps > 0 {
                    drawText("\(phaseTaps)", at: CGPoint(x: 200, y: y + 10), in: &context, color: Ink.bright, size: 11, weight: .semibold)
                }
            }

            if phase >= 2 {
                let toggle = CGRect(x: 196, y: 228, width: 26, height: 13)
                context.fill(card(toggle, 6.5, fill: Ink.accent), with: .color(Ink.accent))
                context.fill(Path(ellipseIn: CGRect(x: 210, y: 229.5, width: 9.2, height: 9.2)), with: .color(Color(red: 0.016, green: 0.149, blue: 0.102)))
            }

            if phase == 3 {
                let dialog = CGRect(x: 62, y: 140, width: 176, height: 128)
                context.fill(card(dialog, 14, fill: Color(red: 0.086, green: 0.141, blue: 0.165)), with: .color(Color(red: 0.086, green: 0.141, blue: 0.165)))
                context.stroke(card(dialog, 14), with: .color(Ink.edge), lineWidth: 1)
                drawText("Allow USB debugging?", at: CGPoint(x: 76, y: 152), in: &context, color: Ink.bright, size: 11.5, weight: .semibold)
                drawText("The computer's RSA key fingerprint is", at: CGPoint(x: 76, y: 174), in: &context, color: Ink.label, size: 9)
                drawText("4F:2A:9C:11 … 8B:7E", at: CGPoint(x: 76, y: 187), in: &context, color: Ink.label, size: 9)
                drawText("Always allow from this computer", at: CGPoint(x: 76, y: 204), in: &context, color: Ink.label, size: 9)
                context.stroke(card(CGRect(x: 146, y: 232, width: 36, height: 22), 11, fill: .clear), with: .color(Ink.edge), lineWidth: 1)
                drawText("Cancel", at: CGPoint(x: 154, y: 238), in: &context, color: Ink.label, size: 9.5)
                context.fill(card(CGRect(x: 188, y: 232, width: 38, height: 22), 11, fill: Ink.accent), with: .color(Ink.accent))
                drawText("Allow", at: CGPoint(x: 198, y: 238), in: &context, color: Color(red: 0.016, green: 0.149, blue: 0.102), size: 9.5, weight: .semibold)
            }

            if phase >= 4 {
                let chip = CGRect(x: 70, y: 272, width: 160, height: 30)
                context.fill(card(chip, 9, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
                context.stroke(card(chip, 9), with: .color(Ink.mint), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: 81, y: 282, width: 10, height: 10)), with: .color(Ink.accent))
                drawText("Phone connected", at: CGPoint(x: 98, y: 282), in: &context, color: Ink.bright, size: 10.5, weight: .semibold)
            }
        }
        .frame(width: 300, height: 430)
        .animation(.easeOut(duration: 0.28), value: phase)
    }

    /// Seven taps, shown while the animation sits on the build-number beat.
    private var phaseTaps: Int { phase == 1 ? 7 : 0 }
}

// MARK: - Scene 2: backup and copy

struct BackupCopyArt: View {
    /// 0 idle · 1 backing up · 2 file found · 3 copying · 4 done
    var phase: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 330, size.height / 430)
            context.scaleBy(x: scale, y: scale)

            let phone = CGRect(x: 14, y: 96, width: 150, height: 270)
            context.stroke(card(phone, 24, fill: Ink.phone, stroke: Ink.edge, width: 2), with: .color(Ink.edge), lineWidth: 2)
            context.fill(card(phone.insetBy(dx: 12, dy: 32), 12, fill: Color(red: 0.043, green: 0.078, blue: 0.102)), with: .color(.black))
            drawText("Chat backup", at: CGPoint(x: 38, y: 142), in: &context, color: Ink.bright, size: 10.5, weight: .semibold)

            let button = CGRect(x: 36, y: 158, width: 106, height: 26)
            context.fill(card(button, 8, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
            context.stroke(card(button, 8), with: .color(Ink.mint), lineWidth: 1)
            drawText("Back up now", at: CGPoint(x: 44, y: 165), in: &context, color: Ink.bright, size: 9.5, weight: .semibold)

            if phase >= 1 {
                drawText(phase >= 2 ? "Last backup: just now" : "Backing up…", at: CGPoint(x: 38, y: 196),
                         in: &context, color: Ink.label, size: 9)
                let track = CGRect(x: 36, y: 214, width: 106, height: 4)
                context.fill(card(track, 2, fill: Ink.dim), with: .color(Ink.dim))
                let pct: CGFloat = phase >= 2 ? 1 : 0.55
                context.fill(card(CGRect(x: 36, y: 214, width: 106 * pct, height: 4), 2, fill: Ink.accent), with: .color(Ink.accent))
            }

            if phase >= 2 {
                var cable = Path()
                cable.move(to: CGPoint(x: 168, y: 216))
                cable.addQuadCurve(to: CGPoint(x: 228, y: 216), control: CGPoint(x: 198, y: 206))
                context.stroke(cable, with: .color(Ink.mint.opacity(0.75)), style: StrokeStyle(lineWidth: 2, dash: [5, 6]))
                let chip = CGRect(x: 170, y: 198, width: 38, height: 32)
                context.fill(card(chip, 6, fill: Color(red: 0.12, green: 0.17, blue: 0.2)), with: .color(Color(red: 0.12, green: 0.17, blue: 0.2)))
                context.stroke(card(chip, 6), with: .color(Ink.mint), lineWidth: 1)
                for (i, w) in [20.0, 14.0, 8.0].enumerated() {
                    context.fill(Path(CGRect(x: 178, y: 207 + Double(i) * 8, width: w, height: 2)),
                                 with: .color(Ink.mint.opacity(0.8)))
                }
            }

            let panel = CGRect(x: 228, y: 122, width: 88, height: 188)
            context.fill(card(panel, 10, fill: Color(red: 0.067, green: 0.106, blue: 0.129)), with: .color(Color(red: 0.067, green: 0.106, blue: 0.129)))
            context.stroke(card(panel, 10), with: .color(Ink.edge), lineWidth: 1)
            drawText("Saga", at: CGPoint(x: 238, y: 148), in: &context, color: Ink.label, size: 9)
            drawText(phase >= 4 ? "Done" : "Copying…", at: CGPoint(x: 238, y: 164), in: &context, color: Ink.label, size: 9)

            if phase >= 3 {
                let track = CGRect(x: 238, y: 182, width: 68, height: 4)
                context.fill(card(track, 2, fill: Ink.dim), with: .color(Ink.dim))
                let pct: CGFloat = phase >= 4 ? 1 : 0.6
                context.fill(card(CGRect(x: 238, y: 182, width: 68 * pct, height: 4), 2, fill: Ink.accent), with: .color(Ink.accent))
            }
            if phase >= 4 {
                var tick = Path()
                tick.move(to: CGPoint(x: 262, y: 232)); tick.addLine(to: CGPoint(x: 271, y: 241)); tick.addLine(to: CGPoint(x: 288, y: 222))
                context.stroke(tick, with: .color(Ink.mint), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                drawText("176 MB copied", at: CGPoint(x: 238, y: 258), in: &context, color: Ink.bright, size: 9, weight: .semibold)
            }

            drawText("No folders, no file paths, no terminal.", at: CGPoint(x: 14, y: 388), in: &context, color: Ink.label, size: 9)
        }
        .frame(width: 330, height: 430)
        .animation(.easeOut(duration: 0.28), value: phase)
    }
}

// MARK: - Scene 3: the key

struct KeyArt: View {
    /// 0 empty · 1..8 filled blocks · 9 complete
    var filledBlocks: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 330, size.height / 430)
            context.scaleBy(x: scale, y: scale)

            let cardRect = CGRect(x: 26, y: 86, width: 278, height: 196)
            context.fill(card(cardRect, 16, fill: Color(red: 0.067, green: 0.106, blue: 0.129)), with: .color(Color(red: 0.067, green: 0.106, blue: 0.129)))
            context.stroke(card(cardRect, 16), with: .color(Ink.edge), lineWidth: 1)
            drawText("Your 64-digit key", at: CGPoint(x: 46, y: 106), in: &context, color: Ink.bright, size: 12.5, weight: .semibold)

            // Masked, never a plausible key: the real one is in the field beside this.
            let blocks = Array(repeating: "•••• ••••", count: 8)
            for (index, block) in blocks.enumerated() {
                let column = index % 2
                let row = index / 2
                let point = CGPoint(x: 46 + CGFloat(column) * 124, y: 138 + CGFloat(row) * 26)
                let shown = filledBlocks > index
                drawText(shown ? block : "···· ····", at: point, in: &context,
                         color: shown ? Ink.mint.opacity(0.9) : Ink.label.opacity(0.3),
                         size: 12, design: .monospaced)
            }

            let track = CGRect(x: 46, y: 246, width: 238, height: 3)
            context.fill(card(track, 1.5, fill: Ink.dim), with: .color(Ink.dim))
            let fraction = CGFloat(min(filledBlocks, 8)) / 8
            if fraction > 0 {
                context.fill(card(CGRect(x: 46, y: 246, width: 238 * fraction, height: 3), 1.5, fill: Ink.accent), with: .color(Ink.accent))
            }
            drawText("\(filledBlocks * 8) / 64 characters", at: CGPoint(x: 46, y: 256), in: &context, color: Ink.label, size: 9)

            if filledBlocks >= 8 {
                var tick = Path()
                tick.move(to: CGPoint(x: 244, y: 258)); tick.addLine(to: CGPoint(x: 252, y: 266)); tick.addLine(to: CGPoint(x: 267, y: 249))
                context.stroke(tick, with: .color(Ink.mint), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                let remember = CGRect(x: 46, y: 286, width: 16, height: 16)
                context.fill(card(remember, 4, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
                context.stroke(card(remember, 4), with: .color(Ink.mint), lineWidth: 1)
                drawText("Keep it in this Mac's Keychain", at: CGPoint(x: 72, y: 288), in: &context, color: Ink.label, size: 10)
            }
        }
        .frame(width: 330, height: 430)
        .animation(.easeOut(duration: 0.18), value: filledBlocks)
    }
}

// MARK: - Text drawing

private func drawText(_ string: String, at point: CGPoint, in context: inout GraphicsContext,
                      color: Color, size: CGFloat, weight: Font.Weight = .regular,
                      design: Font.Design = .default) {
    let text = Text(string)
        .font(.system(size: size, weight: weight, design: design))
        .foregroundStyle(color)
    context.draw(text, at: CGPoint(x: point.x, y: point.y), anchor: .topLeading)
}


// MARK: - Scene 4: turning on encrypted backup (the no-key path)

struct KeySetupArt: View {
    /// 0 find the setting · 1 choose the key option · 2 the key is shown · 3 back up now
    var phase: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 430)
            context.scaleBy(x: scale, y: scale)

            let phone = CGRect(x: 40, y: 4, width: 216, height: 422)
            context.stroke(card(phone, 30, fill: Ink.phone, stroke: Ink.edge, width: 2), with: .color(Ink.edge), lineWidth: 2)
            context.fill(card(phone.insetBy(dx: 16, dy: 42), 14, fill: Color(red: 0.043, green: 0.078, blue: 0.102)), with: .color(.black))
            drawText("Chat backup", at: CGPoint(x: 70, y: 66), in: &context, color: Ink.bright, size: 12, weight: .semibold)

            // the setting row
            let settingRect = CGRect(x: 70, y: 84, width: 160, height: 34)
            context.fill(card(settingRect, 8, fill: phase == 0 ? Ink.accentSoft : Ink.row), with: .color(phase == 0 ? Ink.accentSoft : Ink.row))
            context.stroke(card(settingRect, 8), with: .color(phase == 0 ? Ink.mint : Ink.edge), lineWidth: 1)
            drawText("End-to-end encrypted", at: CGPoint(x: 78, y: 92), in: &context, color: Ink.bright, size: 9.5, weight: .semibold)
            drawText("backup", at: CGPoint(x: 78, y: 103), in: &context, color: Ink.bright, size: 9.5, weight: .semibold)

            // the two choices
            if phase >= 1 {
                let password = CGRect(x: 70, y: 128, width: 160, height: 26)
                context.fill(card(password, 7, fill: Ink.row.opacity(0.5)), with: .color(Ink.row.opacity(0.5)))
                context.stroke(card(password, 7), with: .color(Ink.edge.opacity(0.6)), lineWidth: 1)
                drawText("Use a password", at: CGPoint(x: 78, y: 135), in: &context, color: Ink.label.opacity(0.6), size: 9.5)
                drawText("(Saga cannot open this)", at: CGPoint(x: 160, y: 136), in: &context, color: Ink.label.opacity(0.45), size: 7.5)

                let keyOption = CGRect(x: 70, y: 160, width: 160, height: 26)
                context.fill(card(keyOption, 7, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
                context.stroke(card(keyOption, 7), with: .color(Ink.mint), lineWidth: 1)
                drawText("Use 64-digit key", at: CGPoint(x: 78, y: 167), in: &context, color: Ink.bright, size: 9.5, weight: .semibold)
            }

            // create, then the key card
            if phase >= 2 {
                let create = CGRect(x: 70, y: 194, width: 160, height: 26)
                context.fill(card(create, 7, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
                context.stroke(card(create, 7), with: .color(Ink.mint), lineWidth: 1)
                drawText("Create", at: CGPoint(x: 78, y: 201), in: &context, color: Ink.bright, size: 9.5, weight: .semibold)

                let keyCard = CGRect(x: 70, y: 228, width: 160, height: 92)
                context.fill(card(keyCard, 10, fill: Ink.accentSoft.opacity(0.55)), with: .color(Ink.accentSoft.opacity(0.55)))
                context.stroke(card(keyCard, 10), with: .color(Ink.mint.opacity(0.8)), lineWidth: 1)
                drawText("Your key — copy it now", at: CGPoint(x: 78, y: 236), in: &context, color: Ink.bright, size: 9, weight: .semibold)
                for row in 0..<4 {
                    for column in 0..<2 {
                        drawText("•••••", at: CGPoint(x: 78 + CGFloat(column) * 76, y: 254 + CGFloat(row) * 15),
                                 in: &context, color: Ink.mint.opacity(0.9), size: 9.5, design: .monospaced)
                    }
                }
            }

            // fresh backup
            if phase >= 3 {
                let backUp = CGRect(x: 70, y: 334, width: 160, height: 30)
                context.fill(card(backUp, 8, fill: Ink.accentSoft), with: .color(Ink.accentSoft))
                context.stroke(card(backUp, 8), with: .color(Ink.mint), lineWidth: 1)
                drawText("Back up now", at: CGPoint(x: 78, y: 341), in: &context, color: Ink.bright, size: 10, weight: .semibold)
            }
        }
        .frame(width: 300, height: 430)
        .animation(.easeOut(duration: 0.28), value: phase)
    }
}
