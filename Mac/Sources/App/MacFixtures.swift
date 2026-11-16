import Foundation
import MurmurCore

/// Launch arguments for screenshot runs and tests. Release builds ignore all of them.
struct MacLaunchOptions {
    var fixtures = false
    var page: MacAppModel.Page?
    var settingsTab: String?
    var onboardingStep: String?
    var barState: String?
    var sheet: String?
    var quickNote = false

    static let current = MacLaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        #if DEBUG
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        fixtures = arguments.contains("-mac-fixtures")
        page = value(after: "-page").flatMap(MacAppModel.Page.init(rawValue:))
        settingsTab = value(after: "-settings")
        onboardingStep = value(after: "-onboarding")
        barState = value(after: "-bar")
        sheet = value(after: "-sheet")
        quickNote = arguments.contains("-quicknote")
        #endif
    }
}

/// The mock's sample content (olga, her dictations, words, snippets and notes), in memory only.
@MainActor
enum MacFixtures {
    static let name = "olga"
    static let email = "olga@example.com"

    static var quota: AccountService.Quota {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -8, to: now)!
        let json = """
            {"plan":"pro","on_trial":true,"trial_ends_at":"\(iso(start.addingTimeInterval(14 * 86_400)))",
             "trial_started_at":"\(iso(start))","words_this_week":1240,"weekly_limit":null,"remaining":null}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(AccountService.Quota.self, from: Data(json.utf8)) // swiftlint:disable:this force_try
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func seed(history: HistoryStore, library: LibraryStore, apps: DictationAppLog) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: calendar.date(byAdding: .day, value: -day, to: today)!)!
        }
        let rows: [(Date, String, String, Double, Int, String, Bool)] = [
            (at(0, 14, 2), "en", "Running ten minutes late, start without me. I’ll join from the car.", 9, 13, "Messages", false),
            (at(0, 12, 47), "ru", "Привет! Договор посмотрел, правки пришлю до вечера.", 6, 8, "Telegram", true),
            (at(0, 11, 30), "en", "Can you send me the deck before the call? I want to check the numbers on slide four.", 8, 18, "Slack", false),
            (at(0, 9, 15), "en", "Add oat milk, coffee filters and something for dinner to the list.", 7, 12, "Notes", false),
            (at(1, 18, 30), "en", "Thanks for the notes. Two things before we ship: the welcome copy and the icon.", 11, 15, "Mail", false),
            (at(1, 16, 5), "ru", "Напомни позвонить маме в субботу утром.", 4, 6, "Reminders", false),
        ]
        var earlier: [(Date, String, String, Double, Int, String, Bool)] = []
        // A few weeks of quieter days behind them, for Insights' heatmap and streak.
        for day in 2..<100 where day % 3 != 1 || day < 6 {
            let words = 20 + (day * 37) % 160
            earlier.append((at(day, 10 + day % 8, (day * 13) % 60), day % 4 == 0 ? "ru" : "en",
                            "Earlier dictation \(day)", Double(words) / 2.4, words,
                            ["Slack", "Mail", "Messages", "Notes", "Safari"][day % 5], false))
        }
        for (date, language, text, seconds, words, app, copied) in rows + earlier {
            let transcript = Transcript(
                createdAt: date, language: language, style: .verbatim, rawText: text, cleanedText: text,
                status: .cleaned, metrics: TranscriptMetrics(audioSeconds: seconds, words: words), source: .keyboard)
            history.record(transcript)
            apps.record(transcript.id, app: app, bundleID: nil, copied: copied)
        }
        _ = try? library.saveEntry(term: "Anton", misspelling: nil)
        _ = try? library.saveEntry(term: "by the way", misspelling: "btw")
        _ = try? library.saveEntry(term: "Kubernetes", misspelling: "cooper netties")
        _ = try? library.saveEntry(term: "Murmur", misspelling: nil)
        _ = try? library.saveEntry(term: "Сбербанк", misspelling: nil)
        _ = try? library.saveSnippet(trigger: "standup update",
                                     expansion: "Yesterday: shipped the keyboard redesign. Today: Dictionary and Snippets. Blockers: none.")
        _ = try? library.saveSnippet(trigger: "my email address", expansion: email)
        _ = try? library.saveSnippet(trigger: "my calendar link", expansion: "https://cal.com/olga/30min")
        _ = try? library.saveSnippet(trigger: "office address", expansion: "Office 1204, Bay Square 3, Business Bay, Dubai")
        let notes: [(String, String, Date)] = [
            ("Questions for the accountant", "Ask about the VAT registration deadline and whether the app's income counts as export of services.", at(6, 10, 0)),
            ("Список на выходные", "Купить фильтры для кофе, забрать куртку из химчистки, позвонить маме.", at(2, 11, 0)),
            ("Call with the designer", "Walk through the Mac mock: the floating bar, the menu-bar menu and onboarding.", at(1, 15, 0)),
            ("Pitch idea: a voice keyboard", """
                A voice keyboard that keeps your exact words and only fixes what you ask it to. People talk three times faster than they type, but most dictation either mangles names or rewrites everything into the same polite voice.

                Two modes: word for word by default, and a rewrite only when you pick one. Learns names from your dictionary. Works in Russian and English in the same sentence.
                """, at(0, 9, 41)),
        ]
        for (title, body, date) in notes {
            var note = library.createNote(now: date)
            note.title = title
            note.body = body
            library.updateNote(note, now: date)
        }
    }
}
