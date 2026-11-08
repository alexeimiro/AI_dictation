import MurmurCore
import MurmurUI
import SwiftUI

/// Engine override, a test field, latency percentiles and housekeeping.
struct DebugView: View {
    @Environment(AppModel.self) private var model
    @State private var testText = ""
    @State private var memory = ""
    @State private var confirmClear = false
    @State private var latencyKind = DictationTimings.Kind.translation
    @State private var tokenSigning = "—"
    @State private var keyboardPeak = 0

    var body: some View {
        @Bindable var settings = model.settings
        let _ = model.history.revision
        let _ = model.timingsLog.revision
        let summary = model.history.metricsSummary()
        let cloud = model.timingsLog.summary(latencyKind)
        Form {
            Section {
                Picker("Recognizer", selection: $settings.transcriberEngine) {
                    ForEach(TranscriberEngine.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Running", value: model.session.engineName.isEmpty ? "—" : model.session.engineName)
                LabeledContent("Memory", value: memory)
            } header: {
                Text("Engine")
            } footer: {
                Text("Recognizer changes apply the next time the session starts.")
            }
            Section {
                Toggle("Return to the app automatically", isOn: $settings.autoReturn)
                    .tint(Palette.toggleGreen)
                LabeledContent("Last time", value: model.hostReturn.lastOutcome
                    ?? (model.hostReturn.isAvailable ? "—" : "Not available on this iOS"))
            } header: {
                Text("After the keyboard opens Murmur")
            } footer: {
                Text("Murmur learns which app you were typing in from a part of iOS that isn't public, and reopens it. Turn this off to always swipe back yourself.")
            }
            Section {
                TextField("Tap here, switch to the Murmur keyboard, and dictate", text: $testText, axis: .vertical)
                    .lineLimit(3...8)
                if !testText.isEmpty {
                    Button("Clear", role: .destructive) { testText = "" }
                }
            } header: {
                Text("Try it")
            }
            Section("Latency, last \(summary.total.count) dictations (median / p95)") {
                metricsRow("Recognition", summary.asr)
                metricsRow("Cleanup", summary.cleanup)
                metricsRow("Total", summary.total)
            }
            Section {
                Picker("Kind", selection: $latencyKind) {
                    Text("Translations").tag(DictationTimings.Kind.translation)
                    Text("Dictations").tag(DictationTimings.Kind.dictation)
                }
                .pickerStyle(.segmented)
                shareRow("Cloud transcript", cloud.cloudTranscripts)
                metricsRow("Stop → result", cloud.stopToResult)
                metricsRow("Tap → stop", cloud.tapToStop)
                metricsRow("Encode", cloud.encode)
                metricsRow("Token at stop", cloud.token)
                metricsRow("Upload", cloud.upload)
                metricsRow("Server wait", cloud.wait)
                metricsRow("Server auth", cloud.serverAuth)
                metricsRow("Server preflight", cloud.serverPreflight)
                metricsRow("Server transcribe", cloud.serverTranscribe)
                metricsRow("Server model", cloud.serverModel)
                metricsRow("Result → insert", cloud.resultToInsert)
                metricsRow("Tap → insert", cloud.tapToInsert)
                shareRow("Reused connection", cloud.reused)
                shareRow("Cold worker", cloud.cold)
                LabeledContent("Regions") {
                    Text(verbatim: Self.describe(cloud.regions)).monospacedDigit()
                }
                LabeledContent("Token signing") {
                    Text(verbatim: tokenSigning)
                }
                #if DEBUG
                if let export = model.timingsLog.exportURL {
                    ShareLink("Export timings", item: export)
                }
                LabeledContent("Keyboard peak") {
                    HStack {
                        Text(verbatim: keyboardPeak > 0 ? Self.megabytes(keyboardPeak) : "—").monospacedDigit()
                        Button("Reset") {
                            SharedSettings.shared.debugKeyboardPeakFootprint = 0
                            keyboardPeak = 0
                        }
                        .buttonStyle(.borderless)
                    }
                }
                #endif
            } header: {
                Text("Cloud latency, last \(cloud.count) (median / p95)")
            } footer: {
                Text("Only dictations with a cloud transcript count, not the on-device fallback or failures. Upload, wait and the server rows add up a dictation's requests (transcribe, then cleanup). Inserts more than 10 s after the result are left out, from the tap too: those are taps on Insert last dictation.")
            }
            Section("Housekeeping") {
                Button("Reconcile insertions") {
                    model.history.reconcileInsertions(payloads: model.transport.payloads)
                }
                Button("Prune IPC files") {
                    model.timingsLog.recordClaims(from: model.transport.payloads)
                    model.transport.payloads.prune(olderThan: 0)
                }
                Button("Forget verified engines") {
                    SharedSettings.shared.verifiedEngines = [:]
                }
                Button("Replay onboarding") {
                    model.router.popToRoot()
                    model.onboarding.restart()
                }
                Button("Clear history", role: .destructive) { confirmClear = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete every transcript?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.deleteAllHistory() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            tokenSigning = model.tokenSigning ?? "—"
            while !Task.isCancelled {
                model.timingsLog.recordClaims(from: model.transport.payloads)
                memory = "\(os_proc_available_memory() / 1_048_576) MB free"
                keyboardPeak = SharedSettings.shared.debugKeyboardPeakFootprint
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func metricsRow(_ title: String, _ summary: MetricsSummary) -> some View {
        LabeledContent(title) {
            Text(verbatim: summary.median.map { "\($0) ms / \(summary.p95 ?? $0) ms" } ?? "—")
                .monospacedDigit()
        }
    }

    private func shareRow(_ title: String, _ share: TimingsSummary.Share) -> some View {
        LabeledContent(title) {
            Text(verbatim: share.fraction.map { "\(Int(($0 * 100).rounded()))% (\(share.count) of \(share.total))" } ?? "—")
                .monospacedDigit()
        }
    }

    /// Most requests first, e.g. "eu-central-1 ×18, us-east-1 ×2".
    private static func describe(_ regions: [String: Int]) -> String {
        guard !regions.isEmpty else { return "—" }
        return regions.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
