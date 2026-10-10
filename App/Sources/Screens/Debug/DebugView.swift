import MurmurCore
import MurmurUI
import SwiftUI

/// Engine override, a test field, latency percentiles and housekeeping.
struct DebugView: View {
    @Environment(AppModel.self) private var model
    @State private var testText = ""
    @State private var memory = ""
    @State private var confirmClear = false

    var body: some View {
        @Bindable var settings = model.settings
        let _ = model.history.revision
        let summary = model.history.metricsSummary()
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
            Section("Housekeeping") {
                Button("Reconcile insertions") {
                    model.history.reconcileInsertions(payloads: model.transport.payloads)
                }
                Button("Prune IPC files") {
                    model.transport.payloads.prune(olderThan: 0)
                }
                Button("Forget verified engines") {
                    SharedSettings.shared.verifiedEngines = [:]
                }
                Button("Clear history", role: .destructive) { confirmClear = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete every transcript?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { model.history.deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            while !Task.isCancelled {
                memory = "\(os_proc_available_memory() / 1_048_576) MB free"
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func metricsRow(_ title: String, _ summary: MetricsSummary) -> some View {
        LabeledContent(title) {
            Text(summary.median.map { "\($0) ms / \(summary.p95 ?? $0) ms" } ?? "—")
                .monospacedDigit()
        }
    }
}
