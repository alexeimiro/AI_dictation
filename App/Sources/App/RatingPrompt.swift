import Foundation
import MurmurCore

/// When Home asks for an App Store rating: after enough dictations that worked, spread over a few
/// days, once per version and not again for four months. It's iOS's own prompt
/// (`RequestReviewAction`), which also limits itself to three a year; App Review doesn't allow
/// custom ones (guideline 5.6.1), so there's no "Loving Murmur?" card of our own.
enum RatingPrompt {
    static let minimumGoodDictations = 10
    static let minimumDays = 3
    static let pause: TimeInterval = 120 * 86_400

    struct Record: Equatable {
        var askedVersion: String?
        var askedAt: Date?
    }

    static func shouldAsk(history: [Transcript], record: Record, version: String, now: Date = Date(),
                          calendar: Calendar = .current) -> Bool {
        guard record.askedVersion != version else { return false }
        if let askedAt = record.askedAt, now.timeIntervalSince(askedAt) < pause { return false }
        let good = history.filter(isGood)
        guard good.count >= minimumGoodDictations else { return false }
        let days = Set(good.map { calendar.startOfDay(for: $0.createdAt) })
        return days.count >= minimumDays
    }

    /// Text went in, of a few words at least.
    static func isGood(_ transcript: Transcript) -> Bool {
        (transcript.status == .cleaned || transcript.status == .raw) && transcript.metrics.words >= 3
    }

    // MARK: Persistence (app-only defaults)

    private static let versionKey = "ratingPrompt.version"
    private static let dateKey = "ratingPrompt.at"

    static func record(defaults: UserDefaults = .standard) -> Record {
        Record(askedVersion: defaults.string(forKey: versionKey), askedAt: defaults.object(forKey: dateKey) as? Date)
    }

    static func markAsked(version: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: versionKey)
        defaults.set(now, forKey: dateKey)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
