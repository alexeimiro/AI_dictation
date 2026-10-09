import MurmurCore
import MurmurUI
import Speech
import SwiftUI

/// Phase 1 control panel: session, keyboard setup, a test field and per-dictation metrics.
/// Replaced by onboarding + Home in Phase 3–4 (kept as a Debug screen).
struct DebugHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var testText = ""
    @State private var disableAfter = SharedSettings.shared.disableAfter
    @State private var engine = TranscriberEngine.current
    @State private var sounds = SharedSettings.shared.interactionSounds
    @State private var layout = SharedSettings.shared.keyboardLayout
    @State private var localeID = SharedSettings.shared.dictationLocale ?? ""
    @State private var supportedLocales: [Locale] = []

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                setupSection
                trySection
                resultsSection
            }
            .navigationTitle("Murmur")
            .refreshable { model.setup.refresh() }
        }
        .tint(Palette.ink)
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText).font(.ui(17, .medium))
                Spacer()
                if model.session.phase == .starting { ProgressView() }
            }
            Toggle("Murmur is on", isOn: Binding(
                get: { model.session.isLive },
                set: { isOn in
                    if isOn { Task { await model.session.start() } } else { model.session.stop() }
                }))
            Picker("Disable after", selection: $disableAfter) {
                ForEach(DisableAfter.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: disableAfter) { _, value in SharedSettings.shared.disableAfter = value }
            Picker("Recognizer", selection: $engine) {
                ForEach(TranscriberEngine.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: engine) { _, value in SharedSettings.shared.transcriberEngine = value.rawValue }
            Picker("Language", selection: $localeID) {
                Text("Device language").tag("")
                ForEach(supportedLocales, id: \.identifier) { locale in
                    Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                        .tag(locale.identifier)
                }
            }
            .onChange(of: localeID) { _, value in
                SharedSettings.shared.dictationLocale = value.isEmpty ? nil : value
            }
            .task(id: engine) { supportedLocales = await Self.locales(for: engine) }
            Picker("Keyboard layout", selection: $layout) {
                Text("Numbers first").tag(KeyboardLayoutPreference.numbers)
                Text("QWERTY").tag(KeyboardLayoutPreference.qwerty)
            }
            .onChange(of: layout) { _, value in SharedSettings.shared.keyboardLayout = value }
            Toggle("Interaction sounds", isOn: $sounds)
                .onChange(of: sounds) { _, value in SharedSettings.shared.interactionSounds = value }
        } header: {
            Text("Session")
        } footer: {
            Text("Recognizer changes apply the next time the session starts. Running: \(model.session.engineName.isEmpty ? "—" : model.session.engineName)")
        }
    }

    private var setupSection: some View {
        Section("Keyboard setup") {
            checkRow("Keyboard added", ok: model.setup.keyboardAdded)
            checkRow("Allow Full Access", ok: model.setup.fullAccessConfirmed)
            checkRow("Microphone", ok: model.setup.microphone == .granted)
            if model.setup.microphone == .undetermined {
                Button("Allow microphone") { Task { await model.setup.requestMicrophone() } }
            }
            Button("Open Settings › Murmur › Keyboards") { model.setup.openSettings() }
        }
    }

    private var trySection: some View {
        Section {
            TextField("Tap here, switch to the Murmur keyboard, and dictate", text: $testText, axis: .vertical)
                .lineLimit(3...8)
            if !testText.isEmpty {
                Button("Clear", role: .destructive) { testText = "" }
            }
        } header: {
            Text("Try it")
        } footer: {
            Text("Then try Notes or Messages: the first dictation opens Murmur once; swipe back and keep talking.")
        }
    }

    private var resultsSection: some View {
        Section("Recent dictations") {
            if model.session.recentResults.isEmpty {
                Text("No dictations yet").foregroundStyle(.secondary)
            }
            ForEach(model.session.recentResults, id: \.requestId) { result in
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.text.isEmpty ? (result.message ?? result.status.rawValue) : result.text)
                        .font(.ui(16))
                    if let metrics = result.metrics {
                        Text(metricsLine(metrics, status: result.status))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Helpers

    private static func locales(for engine: TranscriberEngine) async -> [Locale] {
        let locales: [Locale] = switch engine {
        case .dictationTranscriber: await DictationTranscriber.supportedLocales
        default: await SpeechTranscriber.supportedLocales
        }
        return locales.sorted {
            (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
        }
    }

    private func checkRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Palette.toggleGreen : Palette.lockGray)
        }
    }

    private func metricsLine(_ metrics: DictationMetrics, status: ResultStatus) -> String {
        var parts = [String(format: "%.1fs audio", metrics.audioSeconds), "\(metrics.words) words"]
        if let ms = metrics.stopToTranscriptMs { parts.append("ASR \(ms) ms") }
        if let ms = metrics.cleanupMs { parts.append("cleanup \(ms) ms") }
        if let ms = metrics.stopToResultMs { parts.append("total \(ms) ms") }
        parts.append(status.rawValue)
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch model.session.phase {
        case .off: "Off"
        case .starting: "Starting…"
        case .ready: "On — ready"
        case .recording: "Recording"
        case .processing: "Processing"
        case .needsReconnect: "Needs reconnect (open the app)"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch model.session.phase {
        case .ready: Palette.toggleGreen
        case .recording: .red
        case .processing, .starting: Palette.accent
        case .failed, .needsReconnect: Palette.danger
        case .off: Palette.lockGray
        }
    }
}
