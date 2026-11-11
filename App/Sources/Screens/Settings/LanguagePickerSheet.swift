import MurmurCore
import MurmurUI
import SwiftUI

/// Settings › Languages: a searchable list of the languages Murmur recognizes, the ones picked on
/// top, Auto-detect above the rest. Murmur detects which of the picked languages each dictation
/// is in; with none picked, any language. Taps apply at once.
struct LanguagePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let settings = model.settings
        let picked = settings.dictationLanguages.map(DictationLanguage.init(tag:))
        VStack(spacing: 0) {
            SheetHeader("Languages", confirmTitle: "Done") { dismiss() }
            List {
                Group {
                    SearchField(text: $search, prompt: "Search")
                    if search.isEmpty {
                        if !picked.isEmpty {
                            header("Your languages")
                            ForEach(picked) { row($0, isOn: true) }
                        }
                        header("All languages")
                        autoDetectRow(isOn: picked.isEmpty)
                        ForEach(Self.unpicked(picked)) { row($0, isOn: false) }
                        Text(picked.isEmpty
                             ? "\(Brand.name) detects the language you speak. Pick yours so it only chooses among them."
                             : "\(Brand.name) detects which of these you speak. Pick one language to always dictate in it.")
                            .font(.murmur(.footnote))
                            .foregroundStyle(Theme.third)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Hairline() }
                    } else {
                        let matches = Self.matching(search)
                        ForEach(matches) { language in
                            row(language, isOn: picked.contains { $0.languageCode == language.languageCode })
                                .padding(.top, language.id == matches.first?.id ? 12 : 0)
                        }
                        if matches.isEmpty {
                            EmptyState("No languages found", message: "Nothing matches “\(search)”.")
                                .padding(.vertical, 48)
                        }
                    }
                }
                .plainListRow()
            }
            .plainList()
        }
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
    }

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }

    private func row(_ language: DictationLanguage, isOn: Bool) -> some View {
        Button {
            model.settings.toggleDictationLanguage(language.tag)
        } label: {
            choice(isOn: isOn) {
                Text(language.pickerName)
                    .font(.transcript().weight(isOn ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func autoDetectRow(isOn: Bool) -> some View {
        Button {
            model.settings.dictationLanguages = []
        } label: {
            choice(isOn: isOn) {
                Text("Auto-detect")
                    .font(.murmur(.body, weight: isOn ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Detects any language")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// A row that can be chosen: its name, then the mark, with a line above.
    private func choice<Name: View>(isOn: Bool, @ViewBuilder name: () -> Name) -> some View {
        HStack {
            name()
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            SelectionMark(isOn: isOn)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Hairline() }
        .contentShape(.rect)
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
