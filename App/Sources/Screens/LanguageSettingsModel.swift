import Foundation
import MurmurCore
import Observation

/// The primary and secondary dictation languages with their download and verification state.
/// Backs the Debug languages section now and Settings › Languages later.
@MainActor
@Observable
final class LanguageSettingsModel {
    private(set) var available: [DictationLanguage] = []
    private(set) var primary = DictationLanguage.englishUS.tag
    private(set) var secondary: String?
    private(set) var statuses: [String: SpeechAssetManager.LanguageStatus] = [:]
    /// In-progress work per language ("Downloading Russian… 42%").
    private(set) var activity: [String: String] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var diagnostics: String?

    @ObservationIgnored private let assets: SpeechAssetManager
    @ObservationIgnored private weak var session: SessionController?
    @ObservationIgnored private let settings: SharedSettings

    init(assets: SpeechAssetManager, session: SessionController, settings: SharedSettings = .shared) {
        self.assets = assets
        self.session = session
        self.settings = settings
    }

    var chosenTags: [String] {
        [primary] + (secondary.map { [$0] } ?? [])
    }

    func load() async {
        available = await LanguageResolver.availableLanguages()
        primary = await LanguageResolver.primaryTag(settings: settings)
        secondary = settings.secondaryLanguage
        await refreshStatuses()
    }

    func refreshStatuses() async {
        for tag in chosenTags {
            statuses[tag] = await assets.status(for: tag)
        }
    }

    func setPrimary(_ tag: String) async {
        guard tag != primary else { return }
        settings.primaryLanguage = tag
        primary = tag
        if secondary == tag {
            settings.secondaryLanguage = nil
            secondary = nil
        }
        await prepare(tag)
        session?.languagesDidChange()
        await reconcile()
    }

    func setSecondary(_ tag: String?) async {
        let tag = tag == primary ? nil : tag
        guard tag != secondary else { return }
        settings.secondaryLanguage = tag
        secondary = tag
        if let tag { await prepare(tag) }
        session?.languagesDidChange()
        await reconcile()
    }

    func download(_ tag: String) async {
        await prepare(tag)
        session?.languagesDidChange()
    }

    /// Re-runs the download check and the validation transcription.
    func verifyNow(_ tag: String) async {
        await assets.forgetVerification(tag: tag)
        await prepare(tag)
        session?.languagesDidChange()
    }

    func loadDiagnostics() async {
        diagnostics = await assets.diagnostics()
    }

    func statusLine(for tag: String) -> String {
        if let activity = activity[tag] { return activity }
        if let error = errors[tag] { return error }
        guard let status = statuses[tag] else { return "Checking…" }
        if let verified = status.verified, status.isReady {
            let engine = AppleSpeechTranscriber.Kind(rawValue: verified.engine)?.displayName ?? verified.engine
            return "Ready · \(engine)"
        }
        if status.speech == nil, status.dictation == nil { return "Not supported on this iPhone" }
        if status.speech == .installed || status.dictation == .installed { return "Downloaded · not verified" }
        return "Not downloaded"
    }

    // MARK: Helpers

    private func prepare(_ tag: String) async {
        errors[tag] = nil
        activity[tag] = "Preparing…"
        let name = DictationLanguage(tag: tag).localizedName
        do {
            _ = try await assets.ensureReady(tag: tag, override: TranscriberEngine.current.kindOverride) { [weak self] event in
                Task { @MainActor in
                    if let text = Self.describe(event, name: name) { self?.activity[tag] = text }
                }
            }
        } catch {
            errors[tag] = error.localizedDescription
        }
        activity[tag] = nil
        statuses[tag] = await assets.status(for: tag)
    }

    private func reconcile() async {
        await assets.reconcileReservations(keep: chosenTags)
        await refreshStatuses()
    }

    private static func describe(_ event: SpeechAssetManager.InstallEvent, name: String) -> String? {
        switch event {
        case .downloading(let fraction, let engine):
            "Downloading \(name) (\(engine.displayName))… \(Int((fraction * 100).rounded()))%"
        case .validating(let engine):
            "Checking \(engine.displayName)…"
        case .ready:
            nil
        }
    }
}
