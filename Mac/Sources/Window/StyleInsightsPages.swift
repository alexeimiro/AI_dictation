import MurmurCore
import SwiftUI

/// "How Murmur writes": the four modes, two to a row, with what each makes of the same sentence.
struct StylePage: View {
    @Bindable var model: MacAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "How Murmur writes",
                           lede: "Pick a mode for every dictation. Switch any time from the menu bar.")
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "You say")
                    Text(verbatim: "“\(StyleSample.spoken)”").font(Mac.Font.body).lineSpacing(3)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(StylePreset.allCases) { card($0) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Writing mode")
                Text("The recording goes to the AI services that write your text. They don’t train on it.")
                    .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
            }
            .padding(.horizontal, Mac.Metric.pagePadding)
            .padding(.top, 44).padding(.bottom, 40)
            .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)] }

    private func card(_ style: StylePreset) -> some View {
        let on = model.defaultStyle == style
        return Button {
            model.defaultStyle = style
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(style.title, systemImage: style.symbol).font(Mac.Font.cardTitle)
                    Text(style.subtitle).font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
                    Text("Murmur writes").font(.system(size: 12, weight: .semibold)).foregroundStyle(Mac.Palette.third)
                        .padding(.top, 8)
                    Text(verbatim: StyleSample.written(style)).font(.system(size: 14)).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RadioMark(on: on)
            }
            .foregroundStyle(Mac.Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Mac.Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? Mac.Palette.ink : Mac.Palette.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.title)
        .accessibilityHint(style.subtitle)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The mock's radio: a grey ring, or an ink ring with an ink dot.
struct RadioMark: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Mac.Palette.ink : Mac.Palette.unselected, lineWidth: 1.5)
            if on { Circle().fill(Mac.Palette.ink).padding(5) }
        }
        .frame(width: 20, height: 20)
    }
}

/// Insights: words, speed, time saved and streak for a period, the days dictated, and where and
/// in which languages. From this Mac's history: the iPhone keeps its own.
struct InsightsPage: View {
    @Bindable var model: MacAppModel
    @State private var range: InsightsMath.Range = .week

    var body: some View {
        let all = all
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    PageHeader(title: "Insights", lede: "How much you talked instead of typing, on this Mac.")
                    Spacer()
                    Segmented(selection: $range)
                }
                tiles(all)
                HStack(alignment: .top, spacing: 28) {
                    heatmap(all).frame(maxWidth: .infinity, alignment: .leading)
                    shares(all).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Time saved compares your speaking speed with typing at 40 words a minute.")
                    .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
            }
            .padding(.horizontal, Mac.Metric.pagePadding)
            .padding(.top, 44).padding(.bottom, 40)
            .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var all: [Transcript] {
        _ = model.engine.historyRevision
        return model.history.recent(limit: 5000)
    }

    private func tiles(_ all: [Transcript]) -> some View {
        let summary = InsightsMath.summary(all, in: range)
        let streak = InsightsMath.streak(all)
        let wordsNote: String
        switch range {
        case .week:
            let last = InsightsMath.previousWeekWords(all)
            if last > 0 {
                let change = Int(((Double(summary.words) - Double(last)) / Double(last) * 100).rounded())
                wordsNote = "\(change >= 0 ? "+" : "")\(change)% on last week"
            } else {
                wordsNote = "This week"
            }
        case .month: wordsNote = "\(Date().formatted(.dateTime.month(.wide))) so far"
        case .all:
            let first = InsightsMath.counted(all).map(\.createdAt).min()
            wordsNote = first.map { "Since \($0.formatted(.dateTime.month(.wide).day()))" } ?? "Since you started"
        }
        let savedNote = range == .all ? "Since you started" : range.title
        let items: [(String, String, String)] = [
            ("Words", summary.words.formatted(), wordsNote),
            ("Speed", summary.wordsPerMinute.map { "\($0) wpm" } ?? "–", "You type at about 40"),
            ("Time saved", InsightsMath.formatMinutes(summary.minutesSaved), savedNote),
            ("Streak", "\(streak.current) \(streak.current == 1 ? "day" : "days")", "Best: \(streak.best) \(streak.best == 1 ? "day" : "days")"),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(items, id: \.0) { label, value, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(Mac.Font.small).foregroundStyle(Mac.Palette.third)
                    Text(value).font(Mac.Font.tile).tracking(-0.4)
                    Text(note).font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Mac.Palette.line, lineWidth: 1))
            }
        }
    }

    private func heatmap(_ all: [Transcript]) -> some View {
        let weeks = InsightsMath.heatmap(all)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Days you dictated").font(Mac.Font.cardTitle)
                Spacer()
                Text("Last 15 weeks").font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
            }
            HStack(spacing: 4) {
                ForEach(weeks.indices, id: \.self) { week in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            let level = weeks[week][day]
                            RoundedRectangle(cornerRadius: 3)
                                .fill(level.map { Mac.Palette.heat[$0] } ?? .clear)
                                .frame(height: 15)
                        }
                    }
                }
            }
            .accessibilityLabel("Days you dictated over the last 15 weeks")
            HStack(spacing: 6) {
                Spacer()
                Text("Less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3).fill(Mac.Palette.heat[level]).frame(width: 12, height: 12)
                }
                Text("More")
            }
            .font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
        }
    }

    private func shares(_ all: [Transcript]) -> some View {
        let apps = InsightsMath.apps(all, log: model.apps.entries, in: range)
        let languages = InsightsMath.languages(all, in: range)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where you dictate").font(Mac.Font.cardTitle)
                Spacer()
                Text("Share of words").font(Mac.Font.caption).foregroundStyle(Mac.Palette.third)
            }
            if apps.isEmpty {
                Text("Nothing in this period yet.").font(Mac.Font.small).foregroundStyle(Mac.Palette.second)
            }
            ForEach(apps, id: \.name) { ShareBar(name: $0.name, share: $0.share) }
            if !languages.isEmpty {
                Text("Languages").font(Mac.Font.cardTitle).padding(.top, 8)
                ForEach(languages, id: \.name) { ShareBar(name: $0.name, share: $0.share) }
            }
        }
    }
}

/// A name, a bar for its share, and the percentage.
private struct ShareBar: View {
    let name: String
    let share: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(name).font(Mac.Font.small).lineLimit(1).frame(width: 84, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Mac.Palette.fill)
                    RoundedRectangle(cornerRadius: 4).fill(Mac.Palette.ink).frame(width: proxy.size.width * share)
                }
            }
            .frame(height: 8)
            Text(InsightsMath.percent(share)).font(Mac.Font.small.monospacedDigit()).foregroundStyle(Mac.Palette.second)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// The mock's three-way switch: a grey track, the chosen one white and lifted.
struct Segmented: View {
    @Binding var selection: InsightsMath.Range

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InsightsMath.Range.allCases) { range in
                Button(range.title) { selection = range }
                    .buttonStyle(.plain)
                    .font(Mac.Font.label)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selection == range ? Mac.Palette.canvas : .clear)
                        .shadow(color: .black.opacity(selection == range ? 0.15 : 0), radius: 1, y: 1))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10).fill(Mac.Palette.fill))
    }
}
