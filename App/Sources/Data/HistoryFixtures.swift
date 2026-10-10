import Foundation
import MurmurCore

/// Sample history for screenshots and previews (`-fixtures`): English and Russian items, every
/// status, one still pending insertion.
enum HistoryFixtures {
    @MainActor
    static func seed(_ store: HistoryStore, now: Date = Date()) {
        for transcript in sample(now: now) {
            store.upsert(transcript)
        }
    }

    static func sample(now: Date = Date()) -> [Transcript] {
        func metrics(_ seconds: Double, _ words: Int, asr: Int = 640, cleanup: Int? = 1900) -> TranscriptMetrics {
            TranscriptMetrics(audioSeconds: seconds, words: words, asrMs: asr, cleanupMs: cleanup,
                              ttftMs: cleanup.map { $0 - 1200 }, totalMs: asr + (cleanup ?? 0) + 80)
        }
        return [
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111101")!,
                createdAt: now.addingTimeInterval(-40),
                language: "ru-RU", style: .casual,
                rawText: "э-э привет можешь скинуть отчёт до пятницы вопросительный знак спасибо большое",
                cleanedText: "Привет, можешь скинуть отчёт до пятницы? Спасибо большое!",
                status: .cleaned, metrics: metrics(6.2, 7), cleanupModel: "claude-opus-5-5", source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111102")!,
                createdAt: now.addingTimeInterval(-15 * 60),
                language: "en-US", style: .casual,
                rawText: "um so I was thinking we could meet at like three no wait four pm on thursday",
                cleanedText: "I was thinking we could meet at 4 PM on Thursday.",
                status: .cleaned, metrics: metrics(5.1, 11), cleanupModel: "claude-opus-5-5",
                insertedAt: now.addingTimeInterval(-15 * 60 + 3), source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111103")!,
                createdAt: now.addingTimeInterval(-2 * 3600),
                language: "ru-RU", style: .casual,
                rawText: "короче дедлайн по пулл реквесту в гитхабе перенесли на семь вечера",
                cleanedText: "Короче дедлайн по пулл реквесту в гитхабе перенесли на семь вечера",
                status: .raw, errorReason: "Offline", metrics: metrics(4.4, 10, cleanup: nil),
                insertedAt: now.addingTimeInterval(-2 * 3600 + 2), source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111104")!,
                createdAt: now.addingTimeInterval(-26 * 3600),
                language: "en-US", style: .formal,
                rawText: "things to do today first run the laundry second buy groceries and third call mom",
                cleanedText: "Things to do today:\n1. Run the laundry\n2. Buy groceries\n3. Call mom",
                status: .cleaned, metrics: metrics(7.8, 15), cleanupModel: "claude-opus-5-5",
                insertedAt: now.addingTimeInterval(-26 * 3600 + 4), source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111105")!,
                createdAt: now.addingTimeInterval(-27 * 3600),
                language: "en-US", style: .casual,
                rawText: "", status: .empty, errorReason: "We didn't catch anything.",
                metrics: metrics(1.2, 0, asr: 300, cleanup: nil), source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111106")!,
                createdAt: now.addingTimeInterval(-3 * 24 * 3600),
                language: "ru-RU", style: .casual,
                rawText: "напомни светлане юрьевне про сбербанк",
                cleanedText: "Напомни Светлане Юрьевне про Сбербанк",
                status: .limitReached, errorReason: "Dictation limit reached.",
                metrics: metrics(3.0, 5, cleanup: nil), insertedAt: now.addingTimeInterval(-3 * 24 * 3600 + 2),
                source: .keyboard),
            Transcript(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111107")!,
                createdAt: now.addingTimeInterval(-3 * 24 * 3600 - 600),
                language: "en-US", style: .casual,
                rawText: "", status: .failed, errorReason: "Couldn't transcribe that.",
                metrics: metrics(2.0, 0, asr: 250, cleanup: nil), source: .keyboard),
        ]
    }
}
