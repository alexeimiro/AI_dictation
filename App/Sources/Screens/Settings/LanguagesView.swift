import MurmurCore
import MurmurUI
import SwiftUI

/// Primary and secondary dictation languages with their download / verification state.
struct LanguagesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let languages = model.languages
        Form {
            Section {
                Picker("Primary", selection: Binding(
                    get: { languages.primary },
                    set: { tag in Task { await languages.setPrimary(tag) } })) {
                    ForEach(languages.available) { language in
                        Text(language.localizedFullName).tag(language.tag)
                    }
                }
                statusRow(languages.primary)
            } footer: {
                Text("The language Murmur listens for unless you switch on the keyboard.")
            }
            Section {
                Picker("Secondary", selection: Binding(
                    get: { languages.secondary ?? "" },
                    set: { tag in Task { await languages.setSecondary(tag.isEmpty ? nil : tag) } })) {
                    Text("None").tag("")
                    ForEach(languages.available.filter { $0.tag != languages.primary }) { language in
                        Text(language.localizedFullName).tag(language.tag)
                    }
                }
                if let secondary = languages.secondary {
                    statusRow(secondary)
                }
            } footer: {
                Text("Adds a language switch to the keyboard. Recognition runs on the device in one language at a time.")
            }
            Section {
                DisclosureGroup("Speech diagnostics") {
                    if let diagnostics = languages.diagnostics {
                        Text(diagnostics)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Copy") { UIPasteboard.general.string = diagnostics }
                    } else {
                        Button("Load diagnostics") { Task { await languages.loadDiagnostics() } }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
        .task { await languages.load() }
    }

    private func statusRow(_ tag: String) -> some View {
        let languages = model.languages
        return HStack(alignment: .firstTextBaseline) {
            Text(DictationLanguage(tag: tag).localizedName)
            Spacer()
            Text(languages.statusLine(for: tag))
                .font(.caption)
                .foregroundStyle(languages.errors[tag] == nil ? Color.secondary : Palette.danger)
                .multilineTextAlignment(.trailing)
            Button("Verify") { Task { await languages.verifyNow(tag) } }
                .buttonStyle(.borderless)
                .disabled(languages.activity[tag] != nil)
        }
    }
}
