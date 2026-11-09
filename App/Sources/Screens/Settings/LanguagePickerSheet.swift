import MurmurCore
import MurmurUI
import SwiftUI

/// Settings › Languages, as in Wispr Flow: a searchable list of the languages Murmur recognizes,
/// the ones picked on top, Auto-detect above the rest. Murmur detects which of the picked
/// languages each dictation is in; with none picked, any language. Taps apply at once.
struct LanguagePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let settings = model.settings
        let picked = settings.dictationLanguages.map(DictationLanguage.init(tag:))
        NavigationStack {
            List {
                if search.isEmpty {
                    if !picked.isEmpty {
                        Section {
                            ForEach(picked) { row($0, isOn: true) }
                        }
                    }
                    Section {
                        autoDetectRow(isOn: picked.isEmpty)
                        ForEach(Self.unpicked(picked)) { row($0, isOn: false) }
                    } footer: {
                        Text(picked.isEmpty
                             ? "\(Brand.name) detects the language you speak. Pick yours so it only chooses among them."
                             : "\(Brand.name) detects which of these you speak. Pick one language to always dictate in it.")
                    }
                } else {
                    let matches = Self.matching(search)
                    ForEach(matches) { language in
                        row(language, isOn: picked.contains { $0.languageCode == language.languageCode })
                    }
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: search)
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ language: DictationLanguage, isOn: Bool) -> some View {
        Button {
            model.settings.toggleDictationLanguage(language.tag)
        } label: {
            HStack {
                Text(language.pickerName)
                    .font(.transcript())
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 12)
                check(isOn)
            }
            .contentShape(.rect)
        }
        .listRowBackground(isOn ? Palette.lavender.opacity(0.55) : Palette.paper)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func autoDetectRow(isOn: Bool) -> some View {
        Button {
            model.settings.dictationLanguages = []
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Auto-detect")
                    .font(.ui(17))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 12)
                check(isOn)
            }
            .contentShape(.rect)
        }
        .listRowBackground(isOn ? Palette.lavender.opacity(0.55) : Palette.paper)
        .accessibilityHint("Detects any language")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func check(_ isOn: Bool) -> some View {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21))
            .foregroundStyle(isOn ? Palette.tabSelectedLabel : Palette.cardBorder)
            .accessibilityHidden(true)
    }

    /// Every language not picked, by name.
    static func unpicked(_ picked: [DictationLanguage]) -> [DictationLanguage] {
        let codes = Set(picked.map(\.languageCode))
        return DictationLanguage.cloudLanguagesByName.filter { !codes.contains($0.languageCode) }
    }

    /// Languages whose name, in the UI language or their own, contains `query`.
    static func matching(_ query: String) -> [DictationLanguage] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return DictationLanguage.cloudLanguagesByName }
        return DictationLanguage.cloudLanguagesByName.filter { $0.pickerName.localizedStandardContains(query) }
    }

    /// What the Settings row shows: "Auto-detect", "Russian", "English, Russian", "English, Russian +1".
    static func summary(_ tags: [String]) -> String {
        guard !tags.isEmpty else { return "Auto-detect" }
        let names = tags.map { DictationLanguage(tag: $0).localizedName }
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
}
