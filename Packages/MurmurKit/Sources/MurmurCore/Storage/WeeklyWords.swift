import Foundation

/// Basic's free words come back every week, at the server's `week_start()`: Sunday 00:00 in
/// Los Angeles, daylight saving included.
public enum WeeklyWords {
    public static let resetTimeZone = TimeZone(identifier: "America/Los_Angeles")!
    /// How long after a reset an answer from the server may still be about the week before.
    public static let clockMargin: TimeInterval = 600

    /// The first reset after `date`.
    public static func nextReset(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resetTimeZone
        // Weekday 1 is Sunday in the Gregorian calendar. Midnight on a Sunday is never skipped or
        // repeated: the clocks change at 2:00.
        return calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: 1),
                                 matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(7 * 86_400)
    }
}
