import MurmurCore
import MurmurUI
import SwiftUI

// Original artwork for the onboarding media panels, drawn in SwiftUI. Nothing here is traced
// from the references; it only fills the same slots. Looping motion stops under Reduce Motion.

private let line = Palette.ink

// MARK: Phone and keyboard mocks

/// A phone seen at an angle, showing an app with the Murmur keyboard.
struct PhoneMock<Screen: View>: View {
    var width: CGFloat = 230
    @ViewBuilder var screen: Screen

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.16)
            .fill(Color(hex: 0x1C1B20))
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.13)
                    .fill(Color(hex: 0xEEF1F6))
                    .overlay { screen.clipShape(.rect(cornerRadius: width * 0.13)) }
                    .padding(width * 0.035)
            }
            .frame(width: width, height: width * 2.05)
            .shadow(color: .black.opacity(0.28), radius: 14, x: 6, y: 10)
    }
}

/// The numbers-first Murmur keyboard, small.
struct MiniMurmurKeyboard: View {
    var listening = false
    var animated = true

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Capsule().fill(Color(hex: 0xC9CCD3)).frame(width: 70, height: 6)
                Spacer()
                Circle().fill(line)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: listening ? "checkmark" : "mic.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
            .padding(.horizontal, 8)
            if listening {
                VStack(spacing: 6) {
                    VoicePill(animated: animated, color: line).frame(width: 74, height: 26)
                    Text("Listening")
                        .font(.ui(8, .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(height: 92)
            } else {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 3.5) {
                        ForEach(0..<(row == 2 ? 7 : 10), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3).fill(.white).frame(height: 20)
                        }
                    }
                }
                HStack(spacing: 3.5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xB9BDC6)).frame(width: 34, height: 20)
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(height: 20)
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xB9BDC6)).frame(width: 34, height: 20)
                }
            }
        }
        .padding(6)
        .background(Color(hex: 0xD6D9E0))
    }
}

/// A rounded app tile with a glyph (no third-party logos).
struct AppTile: View {
    let systemImage: String
    var tint: Color = Palette.ink

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.white)
            .frame(width: 62, height: 62)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Palette.cream, lineWidth: 3) }
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

/// Reference 05's media slot: an app with the Murmur keyboard, the mic pulsing.
struct AnyAppIllustration: View {
    let useCase: UseCase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Color(hex: 0xC7A13A), Color(hex: 0xA9862A)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                PhoneMock(width: 210) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 7) {
                            Capsule().fill(Color(hex: 0xC9CCD3)).frame(width: 120, height: 7)
                            Capsule().fill(Color(hex: 0xDADDE3)).frame(width: 150, height: 7)
                            Capsule().fill(Color(hex: 0xDADDE3)).frame(width: 90, height: 7)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(14)
                        MiniMurmurKeyboard(animated: !reduceMotion)
                    }
                }
                .rotationEffect(.degrees(28))
                .offset(x: 48, y: 30)
            }
            .overlay(alignment: .topLeading) {
                AppTile(systemImage: useCase.appGlyph).padding(16)
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityElement()
            .accessibilityLabel("The Murmur keyboard in another app")
    }
}

/// Reference 40's media slot: dictating into a chat with the listening panel up.
struct ReadyIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [Color(hex: 0x7DB4C6), Color(hex: 0x5E97AC)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                PhoneMock(width: 210) {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill(Palette.teal).frame(width: 22, height: 22)
                                Capsule().fill(Color(hex: 0xC9CCD3)).frame(width: 70, height: 7)
                            }
                            Capsule().fill(Color(hex: 0xDADDE3)).frame(width: 150, height: 7)
                            Capsule().fill(Color(hex: 0xDADDE3)).frame(width: 110, height: 7)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(16)
                        MiniMurmurKeyboard(listening: true, animated: !reduceMotion)
                    }
                }
                .rotationEffect(.degrees(28))
                .offset(x: 40, y: 10)
            }
            .overlay(alignment: .topLeading) {
                AppTile(systemImage: "bubble.left.and.bubble.right.fill", tint: Palette.teal).padding(16)
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityElement()
            .accessibilityLabel("Dictating a message with the Murmur keyboard")
    }
}

/// Reference 26's media slot: a phone held close, a whispered waveform.
struct WhisperIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(RadialGradient(colors: [Color(hex: 0xA9A9AD), Color(hex: 0x6E6E73)],
                                 center: .init(x: 0.7, y: 0.3), startRadius: 10, endRadius: 360))
            .overlay {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(.white.opacity(0.18 - Double(ring) * 0.05), lineWidth: 1.5)
                        .frame(width: 120 + CGFloat(ring) * 70)
                        .offset(x: 30, y: -40)
                }
            }
            .overlay {
                VoicePill(animated: !reduceMotion, filled: true)
                    .frame(width: 62, height: 31)
                    .offset(x: -12, y: -60)
            }
            .overlay(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(hex: 0x1C1B20))
                    .frame(width: 120, height: 230)
                    .rotationEffect(.degrees(-62))
                    .offset(x: -36, y: -40)
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(line, lineWidth: 1) }
            .accessibilityElement()
            .accessibilityLabel("Whispering into a phone")
    }
}

// MARK: Permission and wrap-up art (thick outlines, lavender and cream)

/// Reference 17: speech turning into text.
struct MicrophoneIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.lavender)
                .overlay {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 5) {
                            Spacer()
                            Circle().fill(line).frame(width: 8, height: 8)
                            Circle().fill(line).frame(width: 8, height: 8)
                        }
                        RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 130, height: 11)
                        RoundedRectangle(cornerRadius: 2).fill(line).frame(width: 92, height: 11)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(16)
                }
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(line, lineWidth: 3.5) }
                .frame(width: 168, height: 112)
                .offset(x: 46, y: 14)
            SpeechBubble()
                .fill(line)
                .frame(width: 122, height: 88)
                .overlay {
                    Squiggle()
                        .stroke(Palette.lavender, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 66, height: 22)
                        .offset(y: -10)
                }
                .offset(x: -66, y: -34)
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(line)
                .offset(x: -62, y: 46)
        }
        .frame(width: 260, height: 170)
        .accessibilityHidden(true)
    }
}

/// Reference 35: notifications floating off a phone.
struct NotificationsIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(Palette.lavender)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Palette.cream)
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(line, lineWidth: 3.5) }
                        .overlay {
                            VStack(spacing: 4) {
                                Squiggle().stroke(line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .frame(width: 54, height: 12)
                                Squiggle().stroke(line, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .frame(width: 54, height: 12)
                            }
                        }
                        .padding(.vertical, 18)
                        .padding(.leading, 40)
                        .padding(.trailing, 18)
                }
                .overlay(alignment: .leading) {
                    Circle().fill(line).frame(width: 12, height: 12).padding(.leading, 16)
                }
                .overlay { RoundedRectangle(cornerRadius: 26).stroke(line, lineWidth: 4) }
                .frame(width: 200, height: 112)
                .rotationEffect(.degrees(-28))
                .offset(x: 10, y: 92)
            notification.offset(x: -30, y: -78)
            notification.offset(x: 55, y: -38)
            notification.offset(x: -60, y: 2)
        }
        .frame(width: 280, height: 260)
        .accessibilityHidden(true)
    }

    private var notification: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(line)
            .frame(width: 100, height: 30)
            .overlay(alignment: .leading) {
                HStack(spacing: 6) {
                    Circle().fill(Palette.lavender).frame(width: 12, height: 12)
                    VStack(spacing: 4) {
                        Capsule().fill(Palette.cream).frame(height: 2.5)
                        Capsule().fill(Palette.cream).frame(height: 2.5)
                    }
                }
                .padding(.horizontal, 9)
            }
    }
}

/// Reference 37: dictating into an email on a computer.
struct DesktopIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(.white)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Capsule().fill(Color(hex: 0x2F6FDE)).frame(width: 64, height: 26)
                            .overlay { Text("Send").font(.ui(12, .semibold)).foregroundStyle(.white) }
                        ForEach(["paperclip", "link", "face.smiling", "pencil"], id: \.self) { symbol in
                            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                    ZStack(alignment: .top) {
                        LinearGradient(colors: [Color(hex: 0x2C5BD8), Color(hex: 0x8E7BE3), Color(hex: 0xF2A47C)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(height: 92)
                        VStack(spacing: 7) {
                            Text("hey jordan, umm can we do the")
                                .font(.ui(15, .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.85), in: .rect(cornerRadius: 7))
                            VoicePill(animated: !reduceMotion, color: .white)
                                .frame(width: 40, height: 14)
                                .background(.black, in: .capsule)
                            HStack(spacing: 6) {
                                ForEach(0..<9, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(dockColors[index % dockColors.count])
                                        .frame(width: 22, height: 22)
                                }
                            }
                        }
                        .offset(y: -12)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(line, lineWidth: 1.5) }
            .accessibilityElement()
            .accessibilityLabel("Dictating an email on a computer")
    }

    private var dockColors: [Color] {
        [Color(hex: 0x5AC8FA), Color(hex: 0x34C759), Color(hex: 0xFF9F0A), Color(hex: 0xAF52DE),
         Color(hex: 0xFF375F), Color(hex: 0x64D2FF), Color(hex: 0x30D158), Color(hex: 0xFFD60A)]
    }
}

/// Reference 41: the keyboard goes in the bin, the voice stays.
struct TrialIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The bin.
            BinShape()
                .fill(Palette.accent)
                .overlay { BinShape().stroke(line, lineWidth: 3) }
                .frame(width: 92, height: 102)
                .offset(x: -96, y: 92)
            Capsule().fill(line).frame(width: 110, height: 4).offset(x: -96, y: 41)
            // The keyboard dropping in.
            RoundedRectangle(cornerRadius: 6)
                .fill(Palette.cream)
                .overlay {
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { _ in
                            HStack(spacing: 3) {
                                ForEach(0..<5, id: \.self) { _ in
                                    RoundedRectangle(cornerRadius: 1).fill(Color(hex: 0xF0643A)).frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(line, lineWidth: 3) }
                .frame(width: 68, height: 56)
                .rotationEffect(.degrees(-24))
                .offset(x: -104, y: 18)
            // Ground lines.
            HStack(spacing: 6) {
                Capsule().fill(line).frame(width: 10, height: 3)
                Capsule().fill(line).frame(width: 6, height: 3)
                Capsule().fill(line).frame(width: 60, height: 3)
            }
            .offset(x: -100, y: 145)
            // The phone, held up and listening.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: 0xF0643A))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(line, lineWidth: 3.5) }
                .overlay {
                    VoicePill(animated: !reduceMotion, filled: true)
                        .frame(width: 66, height: 30)
                }
                .frame(width: 104, height: 180)
                .rotationEffect(.degrees(14))
                .offset(x: 62, y: -10)
            Sparkles.image(size: 48)
                .offset(x: 128, y: -110)
            Sparkles.image(size: 30)
                .offset(x: -10, y: -96)
        }
        .frame(width: 340, height: 330)
        .accessibilityHidden(true)
    }
}

/// QWERTY keyboard with the globe key highlighted (references 19–20).
struct GlobeKeyIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                ForEach(["I", "The", "I’m"], id: \.self) { word in
                    Text(word).font(.system(size: 13)).frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(.top, 2)
            keyRow("QWERTYUIOP")
            keyRow("ASDFGHJKL").padding(.horizontal, 12)
            HStack(spacing: 5) {
                key(Image(systemName: "shift.fill"), width: 34)
                ForEach(Array("ZXCVBNM"), id: \.self) { letter in key(Text(String(letter))) }
                key(Image(systemName: "delete.left"), width: 34)
            }
            HStack(spacing: 5) {
                key(Text("123"), width: 34)
                key(Image(systemName: "face.smiling"), width: 34)
                RoundedRectangle(cornerRadius: 5).fill(.white).frame(height: 33)
                key(Image(systemName: "return"), width: 70)
            }
            HStack {
                Image(systemName: "globe")
                    .font(.system(size: 20))
                    .padding(6)
                    .background {
                        Circle()
                            .stroke(Palette.accent, lineWidth: 2.5)
                            .scaleEffect(pulse ? 1.25 : 0.9)
                            .opacity(pulse ? 0 : 1)
                    }
                Spacer()
                Image(systemName: "mic").font(.system(size: 19))
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.top, 2)
        }
        .padding(7)
        .background(Color(hex: 0xD1D3D9), in: .rect(cornerRadius: 22))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Touch and hold the globe key to pick the Murmur keyboard")
    }

    private func keyRow(_ letters: String) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(letters), id: \.self) { letter in key(Text(String(letter))) }
        }
    }

    private func key(_ label: some View, width: CGFloat? = nil) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.white)
            .frame(width: width, height: 33)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay { label.font(.system(size: 17)).foregroundStyle(Palette.text) }
            .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
    }
}

// MARK: Shapes

struct SpeechBubble: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.78),
                        cornerRadius: rect.height * 0.3)
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.7))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.6, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY + rect.height * 0.7))
        path.closeSubpath()
        return path
    }
}

/// A looped scribble, like handwriting.
struct Squiggle: Shape {
    var loops = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / CGFloat(loops)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for index in 0..<loops {
            let x = rect.minX + CGFloat(index) * step
            path.addCurve(
                to: CGPoint(x: x + step, y: rect.maxY),
                control1: CGPoint(x: x + step * 1.1, y: rect.minY - rect.height * 0.3),
                control2: CGPoint(x: x + step * 0.1, y: rect.minY - rect.height * 0.3))
        }
        return path
    }
}

private struct BinShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
