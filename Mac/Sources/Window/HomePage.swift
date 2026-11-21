import AppKit
import MurmurCore
import SwiftUI

/// Home: a greeting, the "Try Murmur in another app" card, this week's numbers, and every
/// dictation by day, each with its length, words and the app it went into.
struct HomePage: View {
    @Bindable var model: MacAppModel
    @State private var search = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            PageBar {
                SearchField(prompt: "Search dictations", text: $search)
                IconButton(symbol: "square.and.pencil", label: "New note", size: 30, iconSize: 16) { model.newNote() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(greeting).font(Mac.Font.pageTitle).tracking(-0.5)
                    if !model.homeIntroDismissed, search.isEmpty {
                        IntroCard(title: "Try Redmic in another app",
                                  text: "Click into Mail, Slack or any text box. Hold fn and talk, then let go: your words appear where the cursor is.",
                                  dismiss: { model.homeIntroDismissed = true }) {
                            FnKeycap()
                        } trailing: {
                            Button("Show me") { openWindow(id: "onboarding") }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    }
                    if search.isEmpty { stats }
                    if groups.isEmpty {
                        Text(search.isEmpty ? "Nothing yet. Hold fn in any app and talk." : "No dictations match “\(search)”.")
                            .font(Mac.Font.lede).foregroundStyle(Mac.Palette.second)
                            .padding(.top, 8)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            SectionLabel(text: dayTitle(group.day)).padding(.bottom, 6)
                            ForEach(group.transcripts, id: \.id) { transcript in
                                DictationRow(model: model, transcript: transcript)
                            }
                        }
                    }
                }
                .padding(.horizontal, Mac.Metric.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return model.displayName.isEmpty ? part : "\(part), \(model.displayName)"
    }

    private var transcripts: [Transcript] {
        _ = model.engine.historyRevision
        let all = model.history.recent(limit: 500)
        guard !search.isEmpty else { return all }
        return all.filter { $0.displayText.localizedCaseInsensitiveContains(search) }
    }

    private var groups: [DayGroup] { DayBucketing.group(transcripts) }

    private func dayTitle(_ day: Date) -> String {
        switch DayBucketing.relativeDay(for: day) {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        default:
            let days = Calendar.current.dateComponents([.day], from: day, to: Date()).day ?? 0
            return days < 7 ? day.formatted(.dateTime.weekday(.wide)) : day.formatted(.dateTime.month(.wide).day())
        }
    }

    /// Words this week (the plan's count, from every device, when there is one), words per
    /// minute, and the streak.
    private var stats: some View {
        let all = model.history.recent(limit: 5000)
        let week = InsightsMath.summary(all, in: .week)
        let words = model.quota?.wordsThisWeek ?? week.words
        let wpm = InsightsMath.summary(all, in: .all).wordsPerMinute
        let streak = InsightsMath.streak(all).current
        return HStack(spacing: 0) {
            stat(words.formatted(), "words this week", leading: true)
            Rectangle().fill(Mac.Palette.line).frame(width: 1)
            stat(wpm.map { "\($0)" } ?? "–", "words per minute")
            Rectangle().fill(Mac.Palette.line).frame(width: 1)
            stat("\(streak) \(streak == 1 ? "day" : "days")", "streak")
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Mac.Palette.line).frame(height: 1) }
    }

    private func stat(_ value: String, _ label: String, leading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Mac.Font.stat)
            Text(label).font(Mac.Font.small).foregroundStyle(Mac.Palette.third)
        }
        .padding(.vertical, 14)
        .padding(.leading, leading ? 2 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One dictation: its time, its text, "9 s · 13 words · Messages", and on hover Copy and More.
struct DictationRow: View {
    let model: MacAppModel
    let transcript: Transcript
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(transcript.createdAt, format: .dateTime.hour().minute())
                .font(Mac.Font.small.monospacedDigit())
                .foregroundStyle(Mac.Palette.third)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(Mac.Font.body).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(meta).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                    if model.apps.entry(for: transcript.id)?.copied == true { Badge(text: "Copied, not inserted") }
                    if transcript.status == .failed || transcript.status == .empty { Badge(text: "Not written") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: "Copy", iconSize: 14) { copy() }
                Menu {
                    Button("Copy") { copy() }
                    Button("Paste last transcript (⌃⌘V)") { Task { await model.engine.pasteLast() } }
                        .disabled(model.engine.lastText == nil)
                    Divider()
                    Button("Delete") { model.deleteTranscript(transcript) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("More")
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Mac.Palette.fill : .clear))
        .padding(.horizontal, -10)
        .onHover { hovering = $0 }
    }

    private var text: String {
        let written = transcript.displayText
        return written.isEmpty ? (transcript.errorReason ?? "Nothing was heard") : written
    }

    private var meta: String {
        var parts = ["\(Int(transcript.metrics.audioSeconds.rounded())) s",
                     "\(transcript.metrics.words) \(transcript.metrics.words == 1 ? "word" : "words")"]
        if let app = model.apps.entry(for: transcript.id)?.app { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.displayText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// The fn key drawn as a keycap: "fn" top right, the globe bottom left.
struct FnKeycap: View {
    var size: CGFloat = 56
    var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
            .fill(pressed ? Mac.Palette.live : Mac.Palette.canvas)
            .overlay(RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .strokeBorder(pressed ? Mac.Palette.live : Mac.Palette.ink, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                Text("fn").font(.system(size: size * 0.25, weight: .semibold))
                    .foregroundStyle(pressed ? .white : Mac.Palette.ink)
                    .padding(.top, size * 0.1).padding(.trailing, size * 0.14)
            }
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "globe").font(.system(size: size * 0.3, weight: .regular))
                    .foregroundStyle(pressed ? .white : Mac.Palette.ink)
                    .padding(.leading, size * 0.12).padding(.bottom, size * 0.11)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
