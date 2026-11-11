import MurmurCore
import MurmurUI
import SwiftUI

/// Primary and secondary dictation languages with their download / verification state.
struct LanguagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let languages = model.languages
        List {
            Group {
                SettingPicker("Primary", detail: "The language Murmur listens for unless you switch on the keyboard.",
                              selection: Binding(get: { languages.primary },
                                                 set: { tag in Task { await languages.setPrimary(tag) } }),
                              value: DictationLanguage(tag: languages.primary).localizedFullName) {
                    ForEach(languages.available) { language in
                        Text(language.localizedFullName).tag(language.tag)
                    }
                }
                .settingRow()
                statusRow(languages.primary)
                SettingPicker("Secondary",
                              detail: "Adds a language switch to the keyboard. Each dictation is transcribed in one language.",
                              selection: Binding(get: { languages.secondary ?? "" },
                                                 set: { tag in Task { await languages.setSecondary(tag.isEmpty ? nil : tag) } }),
                              value: languages.secondary.map { DictationLanguage(tag: $0).localizedFullName } ?? "None") {
                    Text("None").tag("")
                    ForEach(languages.available.filter { $0.tag != languages.primary }) { language in
                        Text(language.localizedFullName).tag(language.tag)
                    }
                }
                .settingRow()
                if let secondary = languages.secondary {
                    statusRow(secondary)
                }
                DisclosureGroup("Speech diagnostics") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let diagnostics = languages.diagnostics {
                            Text(diagnostics)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                            Button("Copy") { UIPasteboard.general.string = diagnostics }
                                .buttonStyle(.murmur(.secondary, size: .compact))
                        } else {
                            Button("Load diagnostics") { Task { await languages.loadDiagnostics() } }
                                .buttonStyle(.murmur(.secondary, size: .compact))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                }
                .font(.murmur(.body))
                .foregroundStyle(Theme.ink)
                .settingRow()
            }
            .buttonStyle(.plain)
            .plainListRow()
        }
        .plainList()
        .tint(Theme.ink)
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
        .task { await languages.load() }
    }

    /// The language's download and verification state, with a button to check it again. A
    /// failure is ink and bold: red means the microphone is open.
    private func statusRow(_ tag: String) -> some View {
        let languages = model.languages
        let failed = languages.errors[tag] != nil
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DictationLanguage(tag: tag).localizedName)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.ink)
                Text(languages.statusLine(for: tag))
                    .font(.murmur(.footnote, weight: failed ? .semibold : .regular))
                    .foregroundStyle(failed ? Theme.ink : Theme.third)
            }
            Spacer(minLength: 8)
            Button("Verify") { Task { await languages.verifyNow(tag) } }
                .buttonStyle(.murmur(.secondary, size: .compact))
                .disabled(languages.activity[tag] != nil)
        }
        .padding(.bottom, 12)
    }
}
