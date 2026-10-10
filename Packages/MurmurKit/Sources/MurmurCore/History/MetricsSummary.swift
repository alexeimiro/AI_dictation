import Foundation

/// Median and 95th percentile of a latency series (Debug screen), by the nearest-rank method:
/// the value at rank ⌈p × n⌉ of the sorted values, so every reported number is one that was
/// actually measured.
public struct MetricsSummary: Sendable, Hashable {
    public let count: Int
    public let median: Int?
    public let p95: Int?

    public init(count: Int, median: Int?, p95: Int?) {
        self.count = count
        self.median = median
        self.p95 = p95
    }

    public static func summarize(_ values: [Int]) -> MetricsSummary {
        let sorted = values.sorted()
        return MetricsSummary(count: sorted.count,
                              median: percentile(50, ofSorted: sorted),
                              p95: percentile(95, ofSorted: sorted))
    }

    /// Nearest-rank percentile of ascending `sorted`; nil when empty. Integer arithmetic, so
    /// ⌈0.95 × 20⌉ is 19 and never 20 through a rounding artefact.
    public static func percentile(_ percent: Int, ofSorted sorted: [Int]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = (percent * sorted.count + 99) / 100
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
