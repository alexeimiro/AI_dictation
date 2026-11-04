import MurmurCore
import SwiftUI
import UIKit

/// Input view that allows `UIDevice.playInputClick()`.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// The Murmur keyboard: a numbers-first (or QWERTY) key grid for typing, plus the dictation
/// toolbar. Dictation itself runs in the app (keyboards can't use the microphone); this side
/// only sends commands and inserts results — see `KeyboardSessionClient`.
final class KeyboardViewController: UIInputViewController, KeyboardSessionHost {
    private let model = KeyboardModel()
    private let keyGrid = KeyGridView()
    /// The voice pad's row of keys, under `padHost`.
    private let padKeys = KeyGridView()
    private let repeater = KeyRepeater()
    private let settings = SharedSettings.shared
    private var toolbarHost: UIHostingController<KeyboardToolbar>?
    private var panelHost: UIHostingController<ListeningPanel>?
    private var padHost: UIHostingController<VoicePad>?
    private var languageHost: UIHostingController<LanguageSelectorPanel>?
    private var client: KeyboardSessionClient?
    private var plane: KeyboardPlane = .numbers
    /// The voice layout: the pad is home, and the full keys get a key back to it.
    private var usesVoicePad = false
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    /// The last dictation, while the text before the cursor still ends with it (the pad's Undo).
    private var undoableDictation: String?
    private var layoutSignature = ""
    private lazy var haptics = UIImpactFeedbackGenerator(style: .light, view: view)
    private lazy var readyHaptics = UINotificationFeedbackGenerator(view: view)

    private static let keyboardHeight: CGFloat = 272

    // MARK: Lifecycle

    override func loadView() {
        let inputView = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
        inputView.backgroundColor = KeyboardChrome.backdropUIColor
        self.inputView = inputView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true

        let transport: IPCTransport = SharedContainer.appGroup()
            .map { DarwinIPCTransport(container: $0) } ?? InMemoryIPCTransport()
        let client = KeyboardSessionClient(transport: transport)
        client.host = self
        self.client = client

        wireActions()
        buildViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateKeyboardAppearance()
        model.hasFullAccess = hasFullAccess
        model.defaultStyle = settings.defaultStyle
        model.announcesReady = hasFullAccess && settings.readyHaptic
        loadLanguages()
        loadTranslationSettings()
        if hasFullAccess { haptics.prepare() }
        usesVoicePad = settings.keyboardLayout == .voice
        plane = switch settings.keyboardLayout {
        case .numbers: .numbers
        case .qwerty: .letters
        case .voice: .voice
        }
        updateAutoShift()
        reloadKeys()
        client?.activate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if model.showsLanguageSelector {
            model.showsLanguageSelector = false
            languageHost?.view.isHidden = true
            updateLanguagePanelAccessibility(isPresented: false, postsFocusChange: false)
        }
        repeater.stop()
        client?.deactivate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateKeyboardAppearance()
        updateAutoShift()
        reloadKeys()
        refreshUndo()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        refreshUndo()
    }

    // MARK: Views

    private func buildViews() {
        guard let view else { return }
        view.backgroundColor = KeyboardChrome.backdropUIColor
        let toolbar = embed(KeyboardToolbar(model: model), in: view)
        let panel = embed(ListeningPanel(model: model), in: view)
        toolbarHost = toolbar
        panelHost = panel

        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        keyGrid.globeTarget = self
        keyGrid.onKeyDown = { [weak self] spec in self?.keyDown(spec) }
        keyGrid.onKeyUp = { [weak self] spec in self?.keyUp(spec) }
        keyGrid.onSpaceTrackStart = { [weak self] in self?.spaceTrackDidBegin() }
        keyGrid.onSpaceTrackMove = { [weak self] offset in self?.moveCursor(offset) }
        view.addSubview(keyGrid)

        let pad = embed(VoicePad(model: model), in: view)
        // A keyboard extension gets no touches where it draws nothing; a barely-there fill makes
        // the pad's empty space a trackpad.
        pad.view.backgroundColor = UIColor(white: 0, alpha: 0.001)
        padHost = pad
        padKeys.translatesAutoresizingMaskIntoConstraints = false
        padKeys.globeTarget = self
        padKeys.onKeyDown = { [weak self] spec in self?.keyDown(spec) }
        padKeys.onKeyUp = { [weak self] spec in self?.keyUp(spec) }
        padKeys.onSpaceTrackStart = { [weak self] in self?.spaceTrackDidBegin() }
        padKeys.onSpaceTrackMove = { [weak self] offset in self?.moveCursor(offset) }
        view.addSubview(padKeys)

        let languagePanel = embed(LanguageSelectorPanel(model: model), in: view)
        languagePanel.view.backgroundColor = .clear
        languageHost = languagePanel

        let height = view.heightAnchor.constraint(equalToConstant: Self.keyboardHeight)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            height,
            toolbar.view.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.view.heightAnchor.constraint(equalToConstant: 50),
            keyGrid.topAnchor.constraint(equalTo: toolbar.view.bottomAnchor),
            keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.view.topAnchor.constraint(equalTo: keyGrid.topAnchor),
            panel.view.leadingAnchor.constraint(equalTo: keyGrid.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: keyGrid.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: keyGrid.bottomAnchor),
            pad.view.topAnchor.constraint(equalTo: keyGrid.topAnchor),
            pad.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pad.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pad.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            padKeys.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            padKeys.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            padKeys.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            padKeys.heightAnchor.constraint(equalToConstant: 58),
            languagePanel.view.topAnchor.constraint(equalTo: view.topAnchor),
            languagePanel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            languagePanel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            languagePanel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panel.view.isHidden = true
        pad.view.isHidden = true
        padKeys.isHidden = true
        languagePanel.view.isHidden = true
    }

    private func embed<Content: View>(_ content: Content, in container: UIView) -> UIHostingController<Content> {
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        host.didMove(toParent: self)
        return host
    }

    /// Rebuilds the key grid only when something visible changed. Rebuilding while a key is
    /// held would cancel its touch (and stop delete auto-repeat).
    private func reloadKeys() {
        let returnTitle = KeyboardLayouts.returnTitle(for: textDocumentProxy.returnKeyType ?? .default)
        if model.returnTitle != returnTitle { model.returnTitle = returnTitle }
        let showsGlobe = needsInputModeSwitchKey
        let typingLanguage = model.effectiveLanguage.languageCode
        let signature = "\(plane)|\(shift)|\(showsGlobe)|\(usesVoicePad)|\(returnTitle)|\(typingLanguage)"
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        let rows = KeyboardLayouts.rows(for: plane, shift: shift, showsGlobe: showsGlobe,
                                        showsVoicePad: usesVoicePad, returnTitle: returnTitle,
                                        languageCode: typingLanguage)
        (plane == .voice ? padKeys : keyGrid).configure(rows: rows)
        updateKeyAreas()
    }

    /// The keys, the voice pad or the listening panel, whichever fits the plane and the phase. The
    /// pad shows its own listening state, so it keeps the panel hidden.
    private func updateKeyAreas() {
        let capturing = model.isCapturing
        let onPad = plane == .voice
        if model.showsVoicePad != onPad { model.showsVoicePad = onPad }
        padHost?.view.isHidden = !onPad
        padKeys.isHidden = !onPad || capturing
        keyGrid.isHidden = onPad || capturing
        panelHost?.view.isHidden = onPad || !capturing
    }

    private func wireActions() {
        model.actions = KeyboardModel.Actions(
            mic: { [weak self] in
                guard let self else { return }
                feedback()
                // On the voice layout's full keys, talking goes back to the pad.
                if usesVoicePad, plane != .voice {
                    plane = .voice
                    reloadKeys()
                }
                client?.micTapped()
            },
            stop: { [weak self] in self?.client?.stopTapped() },
            cancel: { [weak self] in self?.client?.cancelTapped() },
            insertPending: { [weak self] in self?.client?.insertPendingResult() },
            dismissPending: { [weak self] in self?.client?.dismissPendingResult() },
            dismissNotice: { [weak self] in self?.client?.dismissNotice() },
            openApp: { [weak self] in
                guard let self else { return }
                HostAppOpener.open(Brand.settingsURL, from: self)
            },
            setStyle: { [weak self] style in
                self?.model.styleOverride = style
                self?.client?.styleOverride = style
            },
            setLanguage: { [weak self] language in
                self?.selectSourceLanguage(language)
            },
            showLanguageSelector: { [weak self] in
                guard let self else { return }
                self.languageHost?.view.isHidden = false
                withAnimation(.easeOut(duration: 0.18)) { self.model.showsLanguageSelector = true }
                self.updateLanguagePanelAccessibility(isPresented: true)
            },
            hideLanguageSelector: { [weak self] in
                withAnimation(.easeIn(duration: 0.15)) { self?.model.showsLanguageSelector = false }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(170))
                    guard let self, !self.model.showsLanguageSelector else { return }
                    self.languageHost?.view.isHidden = true
                    self.updateLanguagePanelAccessibility(isPresented: false)
                }
            },
            setTranslationEnabled: { [weak self] enabled in self?.setTranslationEnabled(enabled) },
            setTargetLanguage: { [weak self] language in self?.selectTargetLanguage(language) },
            swapLanguages: { [weak self] in self?.swapTranslationLanguages() },
            deleteDown: { [weak self] in self?.keyDown(KeySpec(action: .delete)) },
            deleteUp: { [weak self] in self?.keyUp(KeySpec(action: .delete)) },
            deleteWord: { [weak self] in
                self?.repeater.stop()
                self?.deleteWordBackward()
            },
            returnKey: { [weak self] in self?.keyDown(KeySpec(action: .returnKey)) },
            undo: { [weak self] in self?.undoLastDictation() },
            moveCursor: { [weak self] offset in self?.moveCursor(offset) })
    }

    private func updateLanguagePanelAccessibility(isPresented: Bool, postsFocusChange: Bool = true) {
        languageHost?.view.accessibilityViewIsModal = isPresented
        toolbarHost?.view.accessibilityElementsHidden = isPresented
        panelHost?.view.accessibilityElementsHidden = isPresented
        padHost?.view.accessibilityElementsHidden = isPresented
        keyGrid.accessibilityElementsHidden = isPresented
        padKeys.accessibilityElementsHidden = isPresented

        if postsFocusChange {
            let focusTarget = isPresented ? languageHost?.view : toolbarHost?.view
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .screenChanged, argument: focusTarget)
            }
        }
    }

    private func updateKeyboardAppearance() {
        overrideUserInterfaceStyle = switch textDocumentProxy.keyboardAppearance {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
    }

    /// Loads the app's installed on-device languages. Cloud recognition can additionally use the
    /// compact common-language list exposed by `KeyboardModel`.
    private func loadLanguages() {
        let primary = settings.primaryLanguage.map(DictationLanguage.init(tag:)) ?? .englishUS
        let verified = settings.verifiedEngines
        let secondary = settings.secondaryLanguage.flatMap { tag -> DictationLanguage? in
            guard tag != primary.tag, verified[tag] != nil else { return nil }
            return DictationLanguage(tag: tag)
        }
        model.primaryLanguage = primary
        model.secondaryLanguage = secondary
    }

    /// Defaults to an installed system keyboard language, then to the iPhone interface language,
    /// then the app's primary dictation language. The onboarding flow normally made the same
    /// choice already; doing it here also handles upgraded installs.
    private func loadTranslationSettings() {
        let available = ([model.primaryLanguage] + (model.secondaryLanguage.map { [$0] } ?? [])
                         + KeyboardModel.commonLanguages)
            .reduce(into: [String: DictationLanguage]()) { result, language in
                result[language.languageCode] = result[language.languageCode] ?? language
            }
        let installedIdentifiers = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
            + Locale.preferredLanguages
        let defaultSource = installedIdentifiers.lazy
            .map(DictationLanguage.init(normalizing:))
            .compactMap { available[$0.languageCode] }
            .first ?? model.primaryLanguage
        let savedSource = settings.translationSourceLanguage.map(DictationLanguage.init(tag:))
        let source = savedSource ?? defaultSource
        model.languageOverride = source.languageCode == model.primaryLanguage.languageCode ? nil : source
        client?.languageOverride = model.languageOverride?.tag

        let target = settings.translationTargetLanguage.map(DictationLanguage.init(tag:))
            ?? defaultTargetLanguage(source: source)
        model.targetLanguage = target.languageCode == source.languageCode
            ? fallbackTargetLanguage(excluding: source.languageCode) : target
        model.translationEnabled = settings.translationEnabled
        model.recentLanguages = settings.recentTranslationLanguages
            .map(DictationLanguage.init(tag:))
            .filter { !$0.isAutomatic }
        syncTranslationToClient()
    }

    private func defaultTargetLanguage(source: DictationLanguage) -> DictationLanguage {
        for identifier in Locale.preferredLanguages {
            let language = DictationLanguage(normalizing: identifier)
            if language.languageCode != source.languageCode { return language }
        }
        return fallbackTargetLanguage(excluding: source.languageCode)
    }

    private func fallbackTargetLanguage(excluding sourceCode: String) -> DictationLanguage {
        KeyboardModel.commonLanguages.first { $0.languageCode != sourceCode } ?? .englishUS
    }

    private func selectSourceLanguage(_ language: DictationLanguage?) {
        let selected = language ?? model.primaryLanguage
        model.languageOverride = selected.languageCode == model.primaryLanguage.languageCode ? nil : selected
        settings.translationSourceLanguage = selected.tag
        client?.languageOverride = model.languageOverride?.tag
        if model.targetLanguage.languageCode == selected.languageCode {
            selectTargetLanguage(fallbackTargetLanguage(excluding: selected.languageCode))
        }
        remember(selected)
        reloadKeys()
    }

    private func selectTargetLanguage(_ language: DictationLanguage) {
        guard !language.isAutomatic, language.languageCode != model.effectiveLanguage.languageCode else { return }
        model.targetLanguage = language
        settings.translationTargetLanguage = language.tag
        remember(language)
        syncTranslationToClient()
    }

    private func setTranslationEnabled(_ enabled: Bool) {
        model.translationEnabled = enabled
        settings.translationEnabled = enabled
        if enabled, model.targetLanguage.languageCode == model.effectiveLanguage.languageCode {
            selectTargetLanguage(fallbackTargetLanguage(excluding: model.effectiveLanguage.languageCode))
        }
        syncTranslationToClient()
    }

    private func swapTranslationLanguages() {
        guard model.translationEnabled, !model.effectiveLanguage.isAutomatic else { return }
        let oldSource = model.effectiveLanguage
        let oldTarget = model.targetLanguage
        selectSourceLanguage(oldTarget.languageCode == model.primaryLanguage.languageCode ? nil : oldTarget)
        selectTargetLanguage(oldSource)
    }

    private func syncTranslationToClient() {
        client?.translationTargetLanguage = model.translationEnabled ? model.targetLanguage.tag : nil
    }

    private func remember(_ language: DictationLanguage) {
        guard !language.isAutomatic else { return }
        let tags = [language.tag] + settings.recentTranslationLanguages.filter {
            DictationLanguage(tag: $0).languageCode != language.languageCode
        }
        settings.recentTranslationLanguages = tags
        model.recentLanguages = settings.recentTranslationLanguages.map(DictationLanguage.init(tag:))
    }

    // MARK: Keys

    private func keyDown(_ spec: KeySpec) {
        feedback()
        switch spec.action {
        case .character, .space, .returnKey, .delete: clearUndo()
        default: break
        }
        switch spec.action {
        case .character(let value):
            textDocumentProxy.insertText(value)
            if shift == .on {
                shift = .off
                reloadKeys()
            }
        case .space:
            insertSpace()
        case .returnKey:
            textDocumentProxy.insertText("\n")
        case .delete:
            repeater.start(
                deleteCharacter: { [weak self] in self?.textDocumentProxy.deleteBackward() },
                deleteWord: { [weak self] in self?.deleteWordBackward() })
        case .shift:
            let now = Date()
            if now.timeIntervalSince(lastShiftTap) < 0.3 {
                shift = .capsLock
            } else {
                shift = shift == .off ? .on : .off
            }
            lastShiftTap = now
            reloadKeys()
        case .plane(let newPlane):
            plane = newPlane
            updateAutoShift()
            reloadKeys()
        case .globe:
            break
        }
    }

    private func keyUp(_ spec: KeySpec) {
        if spec.action == .delete {
            repeater.stop()
            updateAutoShift()
            reloadKeys()
        }
    }

    private func spaceTrackDidBegin() {
        feedback()
        clearUndo()
    }

    private func moveCursor(_ offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        clearUndo()
    }

    /// Double space after a word types ". ", like the system keyboard.
    private func insertSpace() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if before.hasSuffix(" "), let previous = before.dropLast().last, previous.isLetter || previous.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
        } else {
            textDocumentProxy.insertText(" ")
        }
        updateAutoShift()
        reloadKeys()
    }

    private func deleteWordBackward() {
        guard let before = textDocumentProxy.documentContextBeforeInput, !before.isEmpty else {
            textDocumentProxy.deleteBackward()
            return
        }
        var count = 0
        var index = before.endIndex
        while index > before.startIndex, before[before.index(before: index)].isWhitespace {
            index = before.index(before: index)
            count += 1
        }
        while index > before.startIndex, !before[before.index(before: index)].isWhitespace {
            index = before.index(before: index)
            count += 1
        }
        for _ in 0..<max(count, 1) { textDocumentProxy.deleteBackward() }
    }

    private func updateAutoShift() {
        guard plane == .letters, shift != .capsLock else { return }
        let autocapitalize = textDocumentProxy.autocapitalizationType ?? .sentences
        guard autocapitalize != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let sentenceStart = trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("?")
            || trimmed.hasSuffix("!") || before.hasSuffix("\n")
        shift = sentenceStart && (before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n")) ? .on : .off
    }

    private func feedback() {
        UIDevice.current.playInputClick()
        if hasFullAccess, settings.keyboardFeedback {
            haptics.impactOccurred(intensity: 0.6)
        }
    }

    // MARK: KeyboardSessionHost

    var currentDocumentIdentifier: UUID? {
        textDocumentProxy.documentIdentifier
    }

    func openContainingApp(_ url: URL) {
        HostAppOpener.open(url, from: self) { [weak self] success in
            if !success { self?.client?.containingAppOpenFailed() }
        }
    }

    func insertDictation(_ result: DictationResult) {
        let traits = InsertionTraits(
            contextBefore: textDocumentProxy.documentContextBeforeInput,
            singleLine: isSingleLineField,
            language: result.language)
        let text = TextJoiner.prepare(result.text, traits: traits)
        guard !text.isEmpty else { return }
        textDocumentProxy.insertText(text)
        undoableDictation = text
        model.undoableWords = text.split(whereSeparator: \.isWhitespace).count
    }

    /// Success or warning, so a dictation can finish while nobody watches the screen.
    func dictationDidFinish(_ outcome: DictationOutcome) {
        guard hasFullAccess, settings.readyHaptic else { return }
        readyHaptics.notificationOccurred(outcome == .ready ? .success : .warning)
    }

    func sessionClientDidChange(_ client: KeyboardSessionClient) {
        model.update(from: client)
        if model.isProcessing, model.announcesReady { readyHaptics.prepare() }
        updateKeyAreas()
    }

    // MARK: Undo

    /// The text before the cursor must still end with the dictation. Apps may hand over only the
    /// end of a long one, so a context that is entirely the dictation's tail counts too.
    private func undoStillApplies(_ text: String) -> Bool {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        return before.hasSuffix(text) || (!before.isEmpty && text.hasSuffix(before))
    }

    private func refreshUndo() {
        if let text = undoableDictation, !undoStillApplies(text) { clearUndo() }
    }

    private func undoLastDictation() {
        guard let text = undoableDictation, undoStillApplies(text) else { return clearUndo() }
        feedback()
        for _ in 0..<text.count { textDocumentProxy.deleteBackward() }
        clearUndo()
        updateAutoShift()
        reloadKeys()
    }

    private func clearUndo() {
        undoableDictation = nil
        if model.undoableWords != nil { model.undoableWords = nil }
    }

    /// Return would submit here (send/go/search…), so dictations must stay on one line.
    private var isSingleLineField: Bool {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .default: break
        default: return true
        }
        switch textDocumentProxy.keyboardType ?? .default {
        case .URL, .webSearch, .emailAddress, .twitter: return true
        default: return false
        }
    }

}
