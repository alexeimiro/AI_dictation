import SwiftUI

/// The pieces every screen is built from: its title, section labels, plain list rows, fields and
/// an editor sheet's top bar.

/// A screen's name at the top of its content.
public struct ScreenTitle: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.murmur(.title))
            .tracking(-0.6)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The small grey heading above a group of rows ("Today", "Your words (6)").
public struct SectionLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.murmur(.footnote, weight: .semibold))
            .foregroundStyle(Theme.third)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A list row without the list's own chrome: the screen's 20 pt margins, no separator and the
    /// canvas behind it. Rows draw their own `Hairline` where they want one.
    public func plainListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.canvas)
    }
}

/// A search field: a magnifier and the text on a grey capsule, with ✕ to clear it.
public struct SearchField: View {
    @Binding var text: String
    let prompt: String

    public init(text: Binding<String>, prompt: String) {
        _text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.third)
                .accessibilityHidden(true)
            field
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.graphic)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, text.isEmpty ? 16 : 6)
        .frame(minHeight: 44)
        .background(Theme.fill, in: .roundCapsule)
    }

    private var field: some View {
        let field = TextField(prompt, text: $text, prompt: Text(verbatim: prompt).foregroundStyle(Theme.third))
            .font(.murmur(.callout))
            .foregroundStyle(Theme.ink)
            .autocorrectionDisabled()
            .submitLabel(.search)
        #if os(iOS)
        return field.textInputAutocapitalization(.never)
        #else
        return field
        #endif
    }
}

/// A field with its label above it: the label in grey, the field on a soft fill. The label names
/// the field for VoiceOver too.
public struct LabeledField<Field: View>: View {
    let label: String
    let minHeight: CGFloat
    let field: Field

    public init(_ label: String, minHeight: CGFloat = 52, @ViewBuilder field: () -> Field) {
        self.label = label
        self.minHeight = minHeight
        self.field = field()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: label)
                .font(.murmur(.footnote, weight: .semibold))
                .foregroundStyle(Theme.third)
                .accessibilityHidden(true)
            field
                .font(.murmur(.body))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .background(Theme.fill, in: .rect(cornerRadius: 16))
                .accessibilityLabel(label)
        }
    }
}

/// The bar at the top of an editor sheet: Cancel on the left, the sheet's name, and the button
/// that confirms on the right, in bold.
public struct SheetHeader: View {
    let title: String
    let confirmTitle: String
    let canConfirm: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    public init(_ title: String, confirmTitle: String = "Save", canConfirm: Bool = true,
                cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.canConfirm = canConfirm
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        ZStack {
            Text(verbatim: title)
                .font(.murmur(.headline))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 84)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.murmur(.body))
                        .foregroundStyle(Theme.ink)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                Spacer()
                Button(action: confirm) {
                    Text(verbatim: confirmTitle)
                        .font(.murmur(.body, weight: .bold))
                        .foregroundStyle(canConfirm ? Theme.ink : Theme.graphic)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .disabled(!canConfirm)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
    }
}
