import SwiftUI
import AVFoundation
import SagaCore

/// One audio player for the whole Voice notes list. A voice note is a sentence, not a
/// background track: starting another one should stop the first, which is the same rule the
/// chat's link player follows.
@MainActor
final class VoiceNotePlayer: ObservableObject {
    @Published private(set) var currentID: Int64?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorID: Int64?

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// Bumped whenever playback is stopped or replaced, so a slow `isPlayable` check from an
    /// old tap cannot start audio after the reader has moved on.
    private var generation = 0

    func toggle(id: Int64, url: URL) {
        if currentID == id, let player {
            if isPlaying { player.pause(); isPlaying = false }
            else { player.play(); isPlaying = true }
            return
        }
        stop()
        errorID = nil
        generation += 1
        let token = generation
        Task { [weak self] in
            let url = MediaFileResolver.materialise(url)   // an online-only copy is fetched on play
            let asset = AVURLAsset(url: url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            guard let self, self.generation == token else { return }
            guard playable else { self.errorID = id; return }

            let p = AVPlayer(url: url)
            self.player = p
            self.currentID = id
            self.progress = 0
            self.duration = seconds.isFinite && seconds > 0 ? seconds : 0
            self.observe(p, id: id)
            p.play()
            self.isPlaying = true
        }
    }

    func stop() {
        generation += 1
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        currentID = nil
        isPlaying = false
        progress = 0
        duration = 0
    }

    private func observe(_ p: AVPlayer, id: Int64) {
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.currentID == id, let p = self.player else { return }
                let itemDuration = p.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.progress = self.duration > 0 ? min(1, max(0, seconds / self.duration)) : 0
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentID == id else { return }
                self.isPlaying = false
                self.progress = 0
                self.player?.seek(to: .zero)
            }
        }
    }
}

/// A voice note as a row, not a tile: a waveform says nothing about who spoke, so the sender
/// is the loudest thing on the card and the conversation sits right under it.
struct VoiceNoteRow: View {
    @Environment(AppModel.self) private var model
    let note: VoiceNote
    let file: URL?
    @ObservedObject var player: VoiceNotePlayer
    let onJump: () -> Void
    let onFetch: () async -> Void

    @State private var assetDuration: Double = 0
    @State private var fetching = false

    private var isCurrent: Bool { player.currentID == note.id }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
    private var progress: Double { isCurrent ? player.progress : 0 }
    private var duration: Double {
        if isCurrent, player.duration > 0 { return player.duration }
        return assetDuration
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            playControl
            VStack(alignment: .leading, spacing: 6) {
                heading
                if let file {
                    waveformRow(file: file)
                } else {
                    missingRow
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(radius: AppTheme.Radius.panel)
        .task(id: file) { await loadDuration() }
    }

    // MARK: identity

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.senderName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(AppTheme.Surface.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: note.isGroup ? "person.2.fill" : "bubble.left")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(note.chatName)
                        .lineLimit(1)
                    if note.isGroup {
                        Text("Group")
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(AppTheme.Glass.fill.opacity(0.09)))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.Surface.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onJump)
            .help("Show this voice note in the conversation")

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(note.ts.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.Surface.textTertiary)
            }
        }
    }

    // MARK: states

    private var playControl: some View {
        Button {
            guard let file else { return }
            player.toggle(id: note.id, url: file)
        } label: {
            ZStack {
                Circle().fill(file == nil ? AppTheme.Glass.fill.opacity(0.05)
                                          : AppTheme.Accent.primaryFill.opacity(isCurrent ? 0.22 : 0.15))
                Image(systemName: file == nil ? "iphone" : isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(file == nil ? AppTheme.Surface.textTertiary
                                                 : AppTheme.Surface.textPrimary)
                    .offset(x: isPlaying ? 0 : 0.7)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .disabled(file == nil)
        .help(file == nil ? "This voice note isn't on this Mac" : isPlaying ? "Pause" : "Play voice note")
        .accessibilityLabel(isPlaying ? "Pause voice note from \(note.senderName)" : "Play voice note from \(note.senderName)")
    }

    @ViewBuilder private func waveformRow(file: URL) -> some View {
        if player.errorID == note.id {
            Label("This file can't be played on this Mac", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .padding(.top, 3)
        } else {
            Button { player.toggle(id: note.id, url: file) } label: {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        WaveformBars(progress: progress, seed: note.id, width: geo.size.width)
                    }
                    .frame(height: 22)
                    if duration > 0 {
                        Text(Self.clock(duration))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Surface.textTertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Pause" : "Play voice note")
        }
    }

    private var missingRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.phone.isConnected ? AppTheme.Accent.primary : AppTheme.Surface.textTertiary.opacity(0.7))
                .frame(width: 5, height: 5)
            Text(model.phone.isConnected ? "Not on this Mac — pull it from your phone"
                                         : "Not on this Mac — connect your phone")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                switch model.phone {
                case .connected:
                    fetching = true
                    Task { await onFetch(); fetching = false }
                case .unauthorised:
                    model.flash("Accept “Allow USB debugging?” on the phone.")
                case .absent:
                    model.flash("Plug the phone in with USB debugging to fetch this voice note.")
                }
            } label: {
                Text(fetching ? "Fetching…" : model.phone.isConnected ? "Fetch" : "Connect")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AppTheme.Glass.fill.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(fetching)
            .help(model.phone.isConnected ? "Copy this one file from the phone" : "USB debugging must be on")
        }
        .padding(.top, 2)
    }

    // MARK: bits

    private func loadDuration() async {
        guard let file else { assetDuration = 0; return }
        let url = file
        let seconds = await Task.detached {
            let asset = AVURLAsset(url: url)
            guard let d = try? await asset.load(.duration) else { return 0.0 }
            let s = CMTimeGetSeconds(d)
            return s.isFinite && s > 0 ? s : 0
        }.value
        assetDuration = seconds
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A rhythm marker, not a claim about the recording: the heights are a stable function of the
/// message id, and the fill is the player's real progress.
private struct WaveformBars: View {
    let progress: Double
    let seed: Int64
    let width: CGFloat

    var body: some View {
        let count = max(20, Int(width / 6))
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Double(i + 1) / Double(count) <= progress
                          ? AppTheme.Accent.primary
                          : AppTheme.Surface.textTertiary.opacity(0.28))
                    .frame(maxWidth: .infinity)
                    .frame(height: height(i))
            }
        }
    }

    private func height(_ i: Int) -> CGFloat {
        let value = Double((seed &* 31) &+ Int64(i) &* 17)
        let wave = abs(sin(value * 0.37)) * 0.65 + 0.25
        return 5 + CGFloat(wave) * 17
    }
}
