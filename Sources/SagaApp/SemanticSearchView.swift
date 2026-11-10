import SwiftUI
import SagaCore

/// The opt-in controls for meaning search, shown inside Ask.
///
/// Nothing happens until the person ticks the box: no model is probed, no message is read, no index is built. When they
/// do, this view offers the local embedding models that are actually installed, says how much of the archive is covered,
/// and runs an explicit Build with visible progress and Stop. Everything is on this Mac.
struct SemanticSearchControls: View {
    @Environment(AppModel.self) private var model
    @Bindable var panel: AIPanel

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Toggle("Also match meaning", isOn: $panel.semanticOn)
                .toggleStyle(.checkbox)
                .help("Find messages that mean the same thing even without the same words. Uses a local index; off by default.")
                .onChange(of: panel.semanticOn) { _, on in panel.semanticToggled(on, model: model) }
            if panel.semanticOn { detail }
        }
    }

    @ViewBuilder private var detail: some View {
        if panel.semanticDetecting {
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Looking for an embedding model on this Mac…")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Surface.textSecondary)
            }
        } else if panel.semanticProviders.isEmpty {
            StatusBanner(level: .warning, message: "No on-device embedding model found, so Ask will keep using keywords. Apple's sentence embeddings need macOS 14 or later; Ollama models with “embed” in the name are picked up when Ollama is running.",
                         retryTitle: "Look again", retry: { panel.refreshSemantic(model: model) })
        } else {
            if panel.semanticProviders.count > 1 {
                Picker("Embedding model", selection: $panel.semanticChoiceTag) {
                    ForEach(panel.semanticProviders, id: \.choice.tag) { provider in
                        Text(provider.title).tag(provider.choice.tag)
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: panel.semanticChoiceTag) { _, _ in panel.semanticProviderChanged(model: model) }
            }
            state
        }
    }

    @ViewBuilder private var state: some View {
        if panel.semanticBuilding {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(buildLine).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
                    Spacer(minLength: 0)
                    Button("Stop") { panel.stopSemanticBuild() }.buttonStyle(.link)
                }
            }
        } else if let coverage = panel.semanticCoverage {
            switch coverage {
            case .empty:
                Text("There are no text messages to index yet.")
                    .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
            case .missing:
                buildRow("Meaning search needs a one-time local index of your messages. Nothing leaves this Mac.", title: "Build index")
            case .partial(let indexed, let total):
                buildRow("Indexed \(indexed.formatted()) of \(total.formatted()) messages. Build again to finish.", title: "Continue")
            case .stale(let indexed, let total):
                buildRow("Your archive changed since this index was built (\(indexed.formatted()) of \(total.formatted()) messages ready). Build again to update.", title: "Update index")
            case .current(let total):
                Label("Ready · \(total.formatted()) messages indexed on this Mac", systemImage: "checkmark.circle")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.Feedback.success)
            }
        } else {
            Text("Couldn't read the local index. Rebuild your library, then try again.")
                .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.Surface.textSecondary)
        }
        if !panel.semanticMessage.isEmpty {
            StatusBanner(level: panel.semanticMessage.hasPrefix("Couldn't") ? .error : .warning, message: panel.semanticMessage)
        }
    }

    private func buildRow(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.Surface.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(title) { panel.buildSemanticIndex(model: model) }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    private var progress: SemanticIndexProgress {
        panel.semanticBuildProgress ?? SemanticIndexProgress(completed: 0, total: 0, reused: 0)
    }
    private var buildLine: String {
        let p = progress
        var line = "Indexed \(p.completed.formatted()) of \(p.total.formatted())"
        if p.reused > 0 { line += " · \(p.reused.formatted()) already saved" }
        if p.skipped > 0 { line += " · \(p.skipped.formatted()) skipped" }
        return line
    }
}
