import MurmurCore
import SwiftUI

/// The black pill Murmur shows while listening, as the mock draws it in pictures: a red dot that
/// rings, white bars, and the time.
struct ListeningPill: View {
    var bars: [CGFloat] = [8, 14, 22, 16, 26, 12, 20, 9, 16, 6]
    var time = "0:02"

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                PulseDot()
                Circle().fill(Mac.Palette.liveOnDark).frame(width: 10, height: 10)
            }
            .frame(width: 10, height: 10)
            HStack(spacing: 3) {
                ForEach(bars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 3, height: bars[index])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 28)
            Text(time).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.leading, 18).padding(.trailing, 16)
        .frame(width: 228, height: 40)
        .background(Capsule(style: .circular).fill(Mac.Palette.ink))
        .shadow(color: .black.opacity(0.2), radius: 9, y: 6)
        .accessibilityLabel("Murmur listening")
    }
}

/// The ring that swells from the live dot.
struct PulseDot: View {
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .strokeBorder(Mac.Palette.liveOnDark, lineWidth: 1.5)
            .frame(width: 10, height: 10)
            .scaleEffect(grown && !reduceMotion ? 2.6 : 1)
            .opacity(grown && !reduceMotion ? 0 : 0.7)
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { grown = true } }
    }
}

/// A small window card in a picture: three grey dots and a title.
private struct MiniWindow<Content: View>: View {
    let title: String
    var width: CGFloat = 400
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Mac.Palette.border).frame(width: 10, height: 10) }
                Text(title).font(.system(size: 12)).foregroundStyle(Mac.Palette.third)
                    .frame(maxWidth: .infinity).padding(.trailing, 46)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xEDEDED)).frame(height: 1) }
            content
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Mac.Palette.canvas))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Mac.Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 15, y: 10)
    }
}

/// Welcome: a message being written, the listening pill, and fn held.
struct WelcomePicture: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniWindow(title: "New message") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("To: Sam").font(.system(size: 12)).foregroundStyle(Mac.Palette.third)
                    (Text("Running ten minutes late, start without") + Text("|").foregroundStyle(Mac.Palette.ink))
                        .font(.system(size: 15))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
            }
            .offset(x: 44, y: 120)
            ListeningPill().offset(x: 130, y: 330)
            HStack(spacing: 8) {
                Keycaps(keys: ["fn"])
                Text("held").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            }
            .offset(x: 196, y: 396)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Sign in: what comes with the account.
struct AccountPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Comes with your account").font(Mac.Font.cardTitle).padding(.bottom, 6)
            row("Dictionary", "Your words")
            row("Snippets", "Your shortcuts")
            row("Notes", "On both devices")
            row("Style", "How Murmur writes")
            row("Pro", "If you have it on iPhone", last: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 16).fill(Mac.Palette.canvas))
        .shadow(color: .black.opacity(0.06), radius: 15, y: 10)
    }

    private func row(_ name: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(Mac.Palette.second)
        }
        .font(.system(size: 14))
        .frame(height: 44)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(Mac.Palette.line).frame(height: 1) } }
    }
}

/// Two permissions: System Settings › Accessibility with Murmur's switch, and the three steps.
struct AccessibilityPicture: View {
    let granted: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    bar(1); bar(0.8); bar(0.9)
                    Text("Privacy & Security").font(.system(size: 10))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Mac.Palette.border))
                        .padding(.horizontal, -4)
                    bar(0.7); bar(1)
                }
                .padding(.top, 34).padding(.horizontal, 10).padding(.bottom, 10)
                .frame(width: 112, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(hex: 0xF7F7F7))
                .overlay(alignment: .trailing) { Rectangle().fill(Color(hex: 0xEDEDED)).frame(width: 1) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accessibility").font(.system(size: 13, weight: .bold))
                    Text("Allow the apps below to control your computer.").font(.system(size: 11)).foregroundStyle(Mac.Palette.third)
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            MarkView(size: 12, color: .white).frame(width: 18, height: 18)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Mac.Palette.ink))
                            Text("Murmur").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            miniSwitch(on: granted)
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 5).fill(Mac.Palette.line).frame(width: 18, height: 18)
                            Text("Another app").font(.system(size: 12)).foregroundStyle(Mac.Palette.third)
                            Spacer()
                            miniSwitch(on: false)
                        }
                        .padding(.horizontal, 10).frame(height: 34)
                        .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xEDEDED)).frame(height: 1) }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xEDEDED), lineWidth: 1))
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 16)
            }
            .frame(width: 400, height: 190)
            .background(RoundedRectangle(cornerRadius: 12).fill(Mac.Palette.canvas))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Mac.Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 15, y: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click Open Settings.")
                Text("2. Turn on Murmur. Your Mac may ask for your password.")
                Text("3. Come back here. Murmur notices by itself.")
            }
            .font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            .frame(width: 380, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ width: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 3).fill(Mac.Palette.line).frame(width: proxy.size.width * width)
        }
        .frame(height: 8)
    }

    private func miniSwitch(on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Mac.Palette.ink : Mac.Palette.track).frame(width: 30, height: 18)
            Circle().fill(.white).frame(width: 14, height: 14).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .animation(.snappy, value: on)
    }
}

/// Hold fn to talk: a big keycap that turns red while the key (or the mouse) holds it.
struct KeyPicture: View {
    let model: MacAppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                if model.shortcutHeld {
                    PulseKey()
                }
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(model.shortcutHeld ? Mac.Palette.live : model.shortcutTried ? Mac.Palette.ink : Mac.Palette.canvas)
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(model.shortcutHeld ? Mac.Palette.live : Mac.Palette.ink, lineWidth: 2))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(model.shortcutHeld ? Mac.Palette.live : Mac.Palette.ink).frame(height: 6).opacity(0.0)
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(capLabel).font(.system(size: 26, weight: .semibold))
                            .padding(.top, 14).padding(.trailing, 18)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if MacSettings.shared.trigger == .function {
                            Image(systemName: "globe").font(.system(size: 34)).padding(.leading, 18).padding(.bottom, 18)
                        }
                    }
                    .foregroundStyle(model.shortcutHeld || model.shortcutTried ? .white : Mac.Palette.ink)
            }
            .frame(width: 132, height: 132)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.shortcutHeld { model.pressTestKey(true) } }
                .onEnded { _ in model.pressTestKey(false) })
            .accessibilityLabel("Hold to try the shortcut")
            Text(status).font(.system(size: 15, weight: .semibold)).frame(height: 22)
        }
    }

    private var capLabel: String {
        switch MacSettings.shared.trigger {
        case .function: "fn"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        }
    }

    private var status: String {
        model.shortcutHeld ? "Listening… let go to finish"
            : model.shortcutTried ? "That’s it. Murmur heard the key." : "Hold the key"
    }
}

private struct PulseKey: View {
    @State private var grown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .strokeBorder(Mac.Palette.live, lineWidth: 2)
            .scaleEffect(grown ? 1.35 : 1)
            .opacity(grown ? 0 : 0.7)
            .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { grown = true } }
    }
}

/// Try it here: a chat with Sam and a real reply box the dictation types into.
struct PracticePicture: View {
    @Bindable var model: MacAppModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Text("Sam").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xEDEDED)).frame(height: 1) }
                VStack(alignment: .leading) {
                    Text("Are you on your way? We’re about to start.")
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xF0F0F0)))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                TextField("Reply", text: $model.practiceText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: 34)
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(focused || !model.practiceText.isEmpty ? Mac.Palette.ink : Mac.Palette.line, lineWidth: 1.5))
                    .padding(10)
                    .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xEDEDED)).frame(height: 1) }
            }
            .frame(width: 400, height: 300)
            .background(RoundedRectangle(cornerRadius: 12).fill(Mac.Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Mac.Palette.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 15, y: 10)
            .offset(x: 44, y: 70)
            if model.engine.isListening {
                ListeningPill(time: "").offset(x: 130, y: 392)
            }
            Text("Hold here to try")
                .font(Mac.Font.label)
                .frame(width: 160, height: 36)
                .background(Capsule(style: .circular).fill(Mac.Palette.canvas))
                .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
                .contentShape(Capsule(style: .circular))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !model.engine.isListening else { return }
                        focused = true
                        model.engine.begin(handsFree: false)
                    }
                    .onEnded { _ in model.engine.end(commit: true) })
                .offset(x: 164, y: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = true }
    }
}

/// You're set: the menu bar, the bar at rest above the Dock, and where each lives.
struct MenuBarPicture: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 14) {
                Spacer()
                RoundedRectangle(cornerRadius: 2).strokeBorder(Mac.Palette.ink, lineWidth: 1.2).frame(width: 18, height: 9)
                MarkView(size: 13).padding(.horizontal, 5).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0xD6D6D6)))
                Text(Date(), format: .dateTime.hour().minute()).font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Color(hex: 0xF8F8F8, opacity: 0.95))
            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xD8D8D8)).frame(height: 1) }
            callout("In the menu bar", "Style, language, microphone, settings and your last dictation.")
                .frame(width: 220).offset(x: 248, y: 40)
            callout("Above the Dock", "The bar shows when Murmur is listening and writing.")
                .frame(width: 230).offset(x: 120, y: 356)
            IdleCapsule().offset(x: 213, y: 510)
            HStack(spacing: 9) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 9).fill(Color(hex: index % 2 == 0 ? 0xCDCDD2 : 0xC2C2C8)).frame(width: 38, height: 38)
                }
            }
            .frame(width: 320, height: 54)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.85), lineWidth: 1))
            .offset(x: 75, y: 550)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func callout(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(Mac.Palette.second)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
    }
}

/// The floating bar at rest, as the mock draws it: a small white capsule holding the mark.
struct IdleCapsule: View {
    var body: some View {
        MarkView(size: 12)
            .frame(width: 44, height: 22)
            .background(Capsule(style: .circular).fill(.white.opacity(0.94)))
            .overlay(Capsule(style: .circular).strokeBorder(Mac.Palette.ink.opacity(0.22), lineWidth: 1))
    }
}
