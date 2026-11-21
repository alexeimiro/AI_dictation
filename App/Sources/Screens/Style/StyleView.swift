import MurmurCore
import MurmurUI
import SwiftUI

/// The mode for every dictation: four tiles to pick from, and what the picked one writes from the
/// same sentence. The keyboard's style pill changes the same setting.
struct StyleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle("How Murmur writes")
                    .padding(.top, 6)
                    .accessibilityIdentifier(AccessibilityID.screen("style"))
                Text("Pick a mode for every dictation. Switch any time with the style button on the keyboard.")
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
                    .padding(.top, 8)
                ModePicker(selection: settings.defaultStyle) { style in
                    settings.defaultStyle = style
                    model.syncStyle()
                }
                .padding(.top, 20)
                ModePreview(style: settings.defaultStyle)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MenuToolbarItem()
        }
        .sensoryFeedback(.selection, trigger: settings.defaultStyle)
        // The keyboard's pill may have changed the mode while Murmur stayed in front (a note),
        // and the copy this screen reads is otherwise refreshed only when the app comes forward.
        .onAppear {
            settings.reloadFromKeyboard()
            model.syncStyle()
        }
    }
}

/// The four modes as tiles, two to a row (one at the largest text sizes). The picked one is
/// solid ink, so which mode is on reads at a glance; each tile is one button for VoiceOver and
/// Full Keyboard Access. Onboarding's style page shows the same picker.
struct ModePicker: View {
    let selection: StylePreset
    let select: (StylePreset) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        let styles = StylePreset.allCases
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: styles.count, by: perRow)), id: \.self) { first in
                GridRow {
                    ForEach(styles[first..<min(first + perRow, styles.count)]) { style in
                        ModeTile(style: style, isSelected: style == selection) { select(style) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Writing mode")
    }
}

/// One mode: its symbol, name and a short line, with the mark when it's the one in use.
struct ModeTile: View {
    let style: StylePreset
    let isSelected: Bool
    let select: () -> Void
    @ScaledMetric(relativeTo: .body) private var symbolSize: CGFloat = 19
    @ScaledMetric(relativeTo: .body) private var markSize: CGFloat = 20

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: style.symbol)
                        .font(.system(size: symbolSize, weight: .medium))
                        .frame(height: markSize)
                    Spacer(minLength: 4)
                    BrandMark(ring: isSelected ? Theme.onInk : Theme.graphic,
                              dot: isSelected ? Theme.onInk : .clear)
                        .frame(width: markSize, height: markSize)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .font(.murmur(.headline))
                    Text(style.hint)
                        .font(.murmur(.footnote))
                        .foregroundStyle(isSelected ? Theme.onInk.opacity(0.72) : Theme.second)
                }
                .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isSelected ? Theme.onInk : Theme.ink)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 108)
            .background(isSelected ? Theme.ink : Theme.fill, in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
            .animation(.easeInOut(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityHint(style.subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mode.\(style.rawValue)")
    }
}

/// What the picked mode does: the sample sentence as said, what this mode writes from it, and
/// its three promises. The example changes with the pick.
struct ModePreview: View {
    let style: StylePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("You say")
            Text(verbatim: "“\(StyleSample.spoken)”")
                .font(.transcript(.callout))
                .lineSpacing(2)
                .foregroundStyle(Theme.second)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Label {
                    Text(verbatim: "\(style.title) writes")
                } icon: {
                    Image(systemName: style.symbol)
                }
                .font(.murmur(.footnote, weight: .semibold))
                .foregroundStyle(Theme.third)
                .accessibilityAddTraits(.isHeader)
                Text(verbatim: StyleSample.written(style))
                    .font(.transcript(.body))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .id(style)
                    .transition(.opacity)
                Hairline()
                    .padding(.vertical, 14)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(style.promises, id: \.self) { promise in
                        Label {
                            Text(verbatim: promise)
                        } icon: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.second)
                    }
                }
            }
            .softCard(padding: 18)
            .padding(.top, 14)
            Text("With translation on, the translation is written in this mode too.")
                .font(.murmur(.footnote))
                .foregroundStyle(Theme.third)
                .padding(.top, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: style)
    }
}
