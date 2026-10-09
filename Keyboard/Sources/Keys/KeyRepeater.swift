import Foundation

/// Delete-key auto-repeat: one character on press, then characters every 90 ms after a short
/// delay, switching to whole words after a dozen repeats.
@MainActor
final class KeyRepeater {
    private var task: Task<Void, Never>?

    func start(deleteCharacter: @escaping @MainActor () -> Void, deleteWord: @escaping @MainActor () -> Void) {
        stop()
        deleteCharacter()
        task = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            var repeats = 0
            while !Task.isCancelled {
                if repeats < 12 {
                    deleteCharacter()
                    try? await Task.sleep(for: .milliseconds(90))
                } else {
                    deleteWord()
                    try? await Task.sleep(for: .milliseconds(220))
                }
                repeats += 1
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
