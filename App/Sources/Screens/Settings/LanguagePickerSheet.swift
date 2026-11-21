import MurmurCore
import MurmurUI
import SwiftUI

/// Settings › Languages: a searchable list of the languages Murmur recognizes, the ones picked on
/// top, Auto-detect above the rest. Murmur detects which of the picked languages each dictation
/// is in; with none picked, any language. Taps apply at once. At most
/// `DictationLanguage.maxSpokenLanguages` can be picked: the recognizer is told at most that many.
/// Languages Murmur can only type in (translation targets) aren't here: they can't be spoken.
struct LanguagePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let settings = model.settings
        let picked = settings.dictationLanguages.map(DictationLanguage.init(tag:))
        let isFull = picked.count >= DictationLanguage.maxSpokenLanguages
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
                        ForEach(Self.unpicked(picked)) { row($0, isOn: false, isEnabled: !isFull) }
                        Text(Self.footer(pickedCount: picked.count))
                            .font(.murmur(.footnote))
                            .foregroundStyle(Theme.third)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .top) { Hairline() }
                    } else {
                        let matches = Self.matching(search)
                        ForEach(matches) { language in
                            let isOn = picked.contains { $0.languageCode == language.languageCode }
                            row(language, isOn: isOn, isEnabled: isOn || !isFull)
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
        // The picked languages' on-device models are brought once the session hears of them.
        .onDisappear { model.session.languagesDidChange() }
    }

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.top, 22)
            .padding(.bottom, 6)
    }

    private func row(_ language: DictationLanguage, isOn: Bool, isEnabled: Bool = true) -> some View {
        Button {
            model.settings.toggleDictationLanguage(language.tag)
        } label: {
            choice(isOn: isOn) {
                Text(language.pickerName)
                    .font(.transcript().weight(isOn ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
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
        return DictationLanguage.speechLanguagesByName.filter { !codes.contains($0.languageCode) }
    }

    /// The languages `query` finds by name (in English, the UI language or their own), another
    /// name ("Farsi") or code ("pt"), best first: `DictationLanguage.search`.
    static func matching(_ query: String) -> [DictationLanguage] {
        DictationLanguage.search(query, in: DictationLanguage.speechLanguagesByName)
    }

    /// Under the list: what picking does, and the limit once it is reached.
    static func footer(pickedCount: Int) -> String {
        if pickedCount == 0 {
            return "\(Brand.name) detects the language you speak. Pick yours so it only chooses among them."
        }
        if pickedCount >= DictationLanguage.maxSpokenLanguages {
            return "\(Brand.name) detects which of these you speak. You can pick up to \(DictationLanguage.maxSpokenLanguages) languages."
        }
        return "\(Brand.name) detects which of these you speak. Pick one language to always dictate in it."
    }

    /// What the Settings row shows: "Auto-detect", "Russian", "English, Russian", "English, Russian +1".
    static func summary(_ tags: [String]) -> String {
        guard !tags.isEmpty else { return "Auto-detect" }
        let names = tags.map { DictationLanguage(tag: $0).localizedName }
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
}
