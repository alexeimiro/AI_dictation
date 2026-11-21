import AppKit
import MurmurBrand
import MurmurCore
import SwiftUI

/// The menu-bar icon's menu, as the mock lists it. A standard macOS menu, so "Murmur is on" is a
/// checkmark item rather than a switch.
struct MenuBarMenu: View {
    @Bindable var model: MacAppModel
    @Bindable private var settings = MacSettings.shared
    @Environment(\.openURL) private var openURL
    @State private var speak = SharedSettings.shared.autoDetectDefaultApplied
        ? SharedSettings.shared.translationSourceLanguage : nil

    var body: some View {
        Toggle("Murmur is on", isOn: $model.enabled)
        Text(model.enabled ? "Hold \(settings.trigger == .function ? "fn" : settings.trigger.name) in any app to talk"
                           : "The shortcut is off")
        Divider()
        Button("Paste last transcript") { Task { await model.engine.pasteLast() } }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(model.engine.lastText == nil)
        Button("Open Murmur") { model.openMainWindow() }
        Button("New note") { model.openQuickNote() }
            .keyboardShortcut("n", modifiers: [.option, .command])
        Divider()
        Menu("Microphone") {
            Picker("Microphone", selection: Binding(get: { settings.microphoneUID ?? "" },
                                                    set: { settings.microphoneUID = $0.isEmpty ? nil : $0 })) {
                Text("System input").tag("")
                ForEach(AudioInputs.all()) { device in Text(device.name).tag(device.uid) }
            }
            .pickerStyle(.inline)
        }
        Menu("Speak language") {
            Picker("Speak language", selection: Binding(get: { speak ?? "" }, set: { tag in
                speak = tag.isEmpty ? nil : tag
                SharedSettings.shared.translationSourceLanguage = speak
                SharedSettings.shared.autoDetectDefaultApplied = speak != nil
            })) {
                Text("Auto-detect").tag("")
                ForEach(DictationLanguage.speechLanguagesByName, id: \.tag) { language in
                    Text(language.localizedName).tag(language.tag)
                }
            }
            .pickerStyle(.inline)
        }
        Menu("Style") {
            Picker("Style", selection: $model.defaultStyle) {
                ForEach(StylePreset.allCases) { style in Text(style.title).tag(style) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Compare modes…") { model.openMainWindow(page: .style) }
        }
        Divider()
        Button("Help") { openURL(MacLinks.support) }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu-bar icon. It also hands the model SwiftUI's window opener, which only views receive.
struct MenuBarLabel: View {
    let model: MacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(phase: model.engine.phase, enabled: model.enabled))
            .onAppear { model.openWindowAction = openWindow }
    }
}

/// The mark in the menu bar: at rest, with a red dot while the mic is open, faded while off.
enum MenuBarIcon {
    static func image(phase: DictationEngine.Phase, enabled: Bool) -> NSImage {
        if !enabled { return off }
        if case .listening = phase { return listening }
        return idle
    }

    static let idle = draw(template: true) { rect in
        ring(rect, color: .black)
        NSBezierPath(ovalIn: MarkGeometry.dot(in: rect)).fill()
    }

    static let off = draw(template: true) { rect in
        NSColor.black.withAlphaComponent(0.45).setStroke()
        NSColor.black.withAlphaComponent(0.45).setFill()
        ring(rect, color: NSColor.black.withAlphaComponent(0.45))
        NSBezierPath(ovalIn: MarkGeometry.dot(in: rect)).fill()
    }

    /// Not a template, so the dot can be red; the ring is drawn in the menu bar's own text colour
    /// each time it's drawn.
    static let listening = draw(template: false) { rect in
        ring(rect, color: .labelColor)
        NSColor(srgbRed: 1, green: 0.32, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(ovalIn: MarkGeometry.dot(in: rect).insetBy(dx: -0.6, dy: -0.6)).fill()
    }

    private static func ring(_ rect: NSRect, color: NSColor) {
        let ring = MarkGeometry.ring(in: rect)
        let path = NSBezierPath(ovalIn: ring.rect)
        path.lineWidth = ring.lineWidth
        color.setStroke()
        path.stroke()
    }

    private static func draw(template: Bool, _ body: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            body(rect)
            return true
        }
        image.isTemplate = template
        return image
    }
}
