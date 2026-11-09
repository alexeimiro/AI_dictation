import MurmurCore
import os
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
    /// The style menu, the settings sheet and the language sheet, above everything but the toolbar.
    private var overlayHost: UIHostingController<KeyboardOverlayView>?
    private var heightConstraint: NSLayoutConstraint?
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var client: KeyboardSessionClient?
    private var plane: KeyboardPlane = .numbers
    /// The voice layout: the pad is home, and the full keys get a key back to it.
    private var usesVoicePad = false
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    /// The last dictation, while the text before the cursor still ends with it (the pad's Undo).
    private var undoableDictation: String?
    private var layoutSignature = ""
    /// The iPhone's language among the keyboard's (`KeyboardLanguageDefaults`): the letters under Auto.
    private var interfaceLanguage: DictationLanguage?
    /// `SharedSettings.keepScreenAwake`, read when the keyboard appears.
    private var keepsScreenAwake = true
    private var memoryTimer: Timer?
    #if DEBUG
    /// `SharedSettings.debugKeyboardDemo`, read when the keyboard appears.
    private var demo: KeyboardDemo?
    private var demoTimer: Timer?
    #endif
    private lazy var haptics = UIImpactFeedbackGenerator(style: .light, view: view)
    private lazy var readyHaptics = UINotificationFeedbackGenerator(view: view)

    /// The voice keyboard is taller, as in Anton's mock, except in landscape.
    private static let voiceHeight: CGFloat = 320
    private static let keysHeight: CGFloat = 272
    private static let voiceToolbarHeight: CGFloat = 56
    private static let keysToolbarHeight: CGFloat = 50

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
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.updateHeights()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        loadKeyboardSettings()
        updateKeyboardAppearance()
        model.style = settings.defaultStyle
        client?.styleOverride = model.style
        keepsScreenAwake = settings.keepScreenAwake
        loadLanguages()
        loadTranslationSettings()
        if hasFullAccess { haptics.prepare() }
        chooseLayout(settings.keyboardLayout)
        #if DEBUG
        demo = settings.debugKeyboardDemo
        if let layout = demo?.layout { chooseLayout(layout, demo: true) }
        #endif
        updateHeights()
        updateAutoShift()
        reloadKeys()
        client?.activate()
        #if DEBUG
        applyDemo()
        #endif
        startMemoryReadout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if model.overlay != nil {
            model.overlay = nil
            overlayHost?.view.isHidden = true
            updateOverlayAccessibility(isPresented: false, postsFocusChange: false)
        }
        repeater.stop()
        client?.deactivate()
        ScreenWake.keepAwake(false, from: self)
        memoryTimer?.invalidate()
        #if DEBUG
        demoTimer?.invalidate()
        #endif
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

        // Embedded last, so it covers everything below the toolbar.
        let overlay = embed(KeyboardOverlayView(model: model), in: view)
        overlayHost = overlay

        // The layout as `viewWillAppear` will pick it, so the voice keyboard doesn't open short.
        let tall = settings.keyboardLayout == .voice && hasFullAccess
        let height = view.heightAnchor.constraint(equalToConstant: tall ? Self.voiceHeight : Self.keysHeight)
        height.priority = UILayoutPriority(999)
        heightConstraint = height
        let toolbarHeight = toolbar.view.heightAnchor.constraint(
            equalToConstant: tall ? Self.voiceToolbarHeight : Self.keysToolbarHeight)
        toolbarHeightConstraint = toolbarHeight
        NSLayoutConstraint.activate([
            height,
            toolbar.view.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarHeight,
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
            pad.view.bottomAnchor.constraint(equalTo: padKeys.topAnchor),
            padKeys.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            padKeys.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            padKeys.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            padKeys.heightAnchor.constraint(equalToConstant: 58),
            overlay.view.topAnchor.constraint(equalTo: toolbar.view.bottomAnchor),
            overlay.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        panel.view.isHidden = true
        pad.view.isHidden = true
        padKeys.isHidden = true
        overlay.view.isHidden = true
    }

    /// The voice keyboard needs Full Access to dictate and has no letters, so without it the
    /// keyboard opens on Numbers first, where typing works (guideline 4.4.1, docs/PLAN.md). A
    /// Debug demo may show it anyway.
    private func chooseLayout(_ layout: KeyboardLayoutPreference, demo: Bool = false) {
        usesVoicePad = layout == .voice && (hasFullAccess || demo)
        plane = usesVoicePad ? .voice : layout == .qwerty ? .letters : .numbers
    }

    /// 320 pt for the voice keyboard; 272 for the key layouts, and in landscape, where the voice
    /// keyboard switches to its compact sizes.
    private func updateHeights() {
        let compact = traitCollection.verticalSizeClass == .compact
        let tall = usesVoicePad && !compact
        heightConstraint?.constant = tall ? Self.voiceHeight : Self.keysHeight
        toolbarHeightConstraint?.constant = tall ? Self.voiceToolbarHeight : Self.keysToolbarHeight
        let compactPad = usesVoicePad && compact
        if model.compactHeight != compactPad { model.compactHeight = compactPad }
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
        let typingLanguage = KeyboardLanguageDefaults.typingLanguage(source: model.effectiveLanguage,
                                                                      interface: interfaceLanguage)
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
    /// pad shows its own listening state, so it keeps the panel hidden; its space and return stay
    /// in view, dimmed, while a dictation runs.
    private func updateKeyAreas() {
        let capturing = model.isCapturing
        let onPad = plane == .voice
        if model.showsVoicePad != onPad { model.showsVoicePad = onPad }
        padHost?.view.isHidden = !onPad
        padKeys.isHidden = !onPad
        padKeys.typingEnabled = !capturing
        keyGrid.isHidden = onPad || capturing
        panelHost?.view.isHidden = onPad || !capturing
    }

    private func wireActions() {
        model.actions = KeyboardModel.Actions(
            mic: { [weak self] in
                guard let self else { return }
                feedback()
                if model.overlay != nil { hideOverlay() }
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
                guard let self else { return }
                // The pill sets the Default style, like the app's Settings, so it outlives this keyboard.
                settings.defaultStyle = style
                model.style = style
                client?.styleOverride = style
            },
            setLanguage: { [weak self] language in
                self?.selectSourceLanguage(language)
            },
            showOverlay: { [weak self] overlay in self?.showOverlay(overlay) },
            hideOverlay: { [weak self] in self?.hideOverlay() },
            setTranslationEnabled: { [weak self] enabled in self?.setTranslationEnabled(enabled) },
            setTargetLanguage: { [weak self] language in self?.selectTargetLanguage(language) },
            swapLanguages: { [weak self] in self?.swapTranslationLanguages() },
            setKeyboardFeedback: { [weak self] on in
                guard let self else { return }
                settings.keyboardFeedback = on
                model.keyboardFeedback = on
            },
            setReadyHaptic: { [weak self] on in
                guard let self else { return }
                settings.readyHaptic = on
                model.readyHaptic = on
                model.announcesReady = hasFullAccess && on
            },
            setInteractionSounds: { [weak self] on in
                guard let self else { return }
                settings.interactionSounds = on
                model.interactionSounds = on
            },
            setAppearance: { [weak self] appearance in
                guard let self else { return }
                settings.keyboardAppearance = appearance
                model.appearance = appearance
                updateKeyboardAppearance()
            },
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

    private func showOverlay(_ overlay: KeyboardOverlay) {
        overlayHost?.view.isHidden = false
        withAnimation(.easeOut(duration: 0.18)) { model.overlay = overlay }
        updateOverlayAccessibility(isPresented: true)
    }

    private func hideOverlay() {
        withAnimation(.easeIn(duration: 0.15)) { model.overlay = nil }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard let self, self.model.overlay == nil else { return }
            self.overlayHost?.view.isHidden = true
            self.updateOverlayAccessibility(isPresented: false)
        }
    }

    /// An open overlay is modal for VoiceOver; each one has its own close button and the escape
    /// gesture.
    private func updateOverlayAccessibility(isPresented: Bool, postsFocusChange: Bool = true) {
        overlayHost?.view.accessibilityViewIsModal = isPresented
        toolbarHost?.view.accessibilityElementsHidden = isPresented
        panelHost?.view.accessibilityElementsHidden = isPresented
        padHost?.view.accessibilityElementsHidden = isPresented
        keyGrid.accessibilityElementsHidden = isPresented
        padKeys.accessibilityElementsHidden = isPresented

        if postsFocusChange {
            let focusTarget = isPresented ? overlayHost?.view : toolbarHost?.view
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .screenChanged, argument: focusTarget)
            }
        }
    }

    /// The settings sheet's choice, or else the field's keyboard appearance.
    private func updateKeyboardAppearance() {
        overrideUserInterfaceStyle = switch model.appearance {
        case .light: .light
        case .dark: .dark
        case .automatic: fieldAppearance
        }
    }

    private var fieldAppearance: UIUserInterfaceStyle {
        switch textDocumentProxy.keyboardAppearance {
        case .dark: .dark
        case .light: .light
        default: .unspecified
        }
    }

    /// The settings sheet's switches and the appearance, as the app or the sheet last left them.
    private func loadKeyboardSettings() {
        model.keyboardFeedback = settings.keyboardFeedback
        model.readyHaptic = settings.readyHaptic
        model.interactionSounds = settings.interactionSounds
        model.appearance = settings.keyboardAppearance
        model.announcesReady = hasFullAccess && settings.readyHaptic
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

    /// Auto-detect until the user picks a Speak language; the letters and the translation target
    /// follow the iPhone's language until they are picked (`KeyboardLanguageDefaults`).
    private func loadTranslationSettings() {
        interfaceLanguage = KeyboardLanguageDefaults.interfaceLanguage(
            preferred: Locale.preferredLanguages, available: KeyboardModel.commonLanguages)
        let source = KeyboardLanguageDefaults.source(
            saved: settings.translationSourceLanguage, autoDetectApplied: settings.autoDetectDefaultApplied)
        if !settings.autoDetectDefaultApplied {
            settings.translationSourceLanguage = nil
            settings.autoDetectDefaultApplied = true
        }
        model.languageOverride = source.languageCode == model.primaryLanguage.languageCode ? nil : source
        client?.languageOverride = model.languageOverride?.tag

        model.recentLanguages = settings.recentTranslationLanguages
            .map(DictationLanguage.init(tag:))
            .filter { !$0.isAutomatic }
        model.targetLanguage = defaultTarget(
            saved: settings.translationTargetLanguage.map(DictationLanguage.init(tag:)), source: source)
        model.translationEnabled = settings.translationEnabled
        syncTranslationToClient()
    }

    /// The saved target unless it is `source` itself, else the iPhone's language.
    private func defaultTarget(saved: DictationLanguage? = nil, source: DictationLanguage) -> DictationLanguage {
        KeyboardLanguageDefaults.target(
            saved: saved, source: source, preferred: Locale.preferredLanguages,
            available: KeyboardModel.commonLanguages, recent: model.recentLanguages)
    }

    private func selectSourceLanguage(_ language: DictationLanguage?) {
        let selected = language ?? model.primaryLanguage
        model.languageOverride = selected.languageCode == model.primaryLanguage.languageCode ? nil : selected
        settings.translationSourceLanguage = selected.tag
        client?.languageOverride = model.languageOverride?.tag
        if model.targetLanguage.languageCode == selected.languageCode {
            selectTargetLanguage(defaultTarget(source: selected))
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
            selectTargetLanguage(defaultTarget(source: model.effectiveLanguage))
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
        #if DEBUG
        if demo != nil { return }
        #endif
        model.update(from: client)
        if model.isProcessing, model.announcesReady { readyHaptics.prepare() }
        updateKeyAreas()
        // Auto-Lock would otherwise cut a long dictation; the screen stays on only while one listens.
        ScreenWake.keepAwake(keepsScreenAwake && model.listeningSince != nil, from: self)
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

    // MARK: Debug

    /// The Debug memory readout in the toolbar, except under a demo, whose screenshots should look
    /// like a Release build.
    private func startMemoryReadout() {
        #if DEBUG
        memoryTimer?.invalidate()
        guard demo == nil else {
            model.debugMemory = nil
            return
        }
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMemoryReadout() }
        }
        #endif
    }

    #if DEBUG
    /// `SharedSettings.debugKeyboardDemo` pins one state, so each can be screenshotted in the
    /// simulator, where nothing records. The live session's updates are ignored while it is on.
    private func applyDemo() {
        demoTimer?.invalidate()
        demoTimer = nil
        guard let demo else { return }
        let id = UUID()
        model.pendingResult = nil
        model.undoableWords = nil
        switch demo.state {
        case .idle:
            model.phase = .idle
        case .translate:
            model.phase = .idle
            model.translationEnabled = true
        case .starting:
            model.phase = .starting(id)
        case .opening:
            model.phase = .openingApp(id)
        case .reconnect:
            model.phase = .needsReconnect
        case .listening:
            model.translationEnabled = true
            model.phase = .listening(id, since: Date().addingTimeInterval(-12))
            startDemoLevels()
        case .processing:
            model.translationEnabled = true
            model.phase = .processing(id)
        case .inserted:
            model.phase = .idle
            model.undoableWords = 12
        case .notice:
            model.phase = .notice("We didn't catch anything. Try again a little closer.")
        case .pending:
            model.phase = .idle
            model.pendingResult = DictationResult(
                requestId: id, documentIdentifier: nil, text: "Running ten minutes late, start without me",
                status: .cleaned, createdAt: Date())
        case .fullAccess:
            model.phase = .needsFullAccess
        case .style:
            model.phase = .idle
            showOverlay(.style)
        case .settings:
            model.phase = .idle
            showOverlay(.settings)
        case .languages:
            model.phase = .idle
            model.translationEnabled = true
            showOverlay(.languages)
        }
        updateKeyAreas()
    }

    /// A speech-like level for the demo's listening state: syllables riding a slower phrase.
    private func startDemoLevels() {
        let start = Date()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let time = Date().timeIntervalSince(start)
                let level = 0.12 + 0.7 * abs(sin(time * 7.3)) * (0.55 + 0.45 * sin(time * 1.3))
                self.model.levels.removeFirst()
                self.model.levels.append(min(1, max(0.06, level)))
            }
        }
    }

    /// The footprint and what is left before the extension is killed, in MB, e.g. "21.4/27MB"
    /// (the simulator doesn't enforce the limit). The peak goes to the app's Debug screen.
    private func updateMemoryReadout() {
        let footprint = Self.physicalFootprint()
        if footprint > settings.debugKeyboardPeakFootprint { settings.debugKeyboardPeakFootprint = footprint }
        let used = String(format: "%.1f", Double(footprint) / 1_048_576)
        model.debugMemory = "\(used)/\(os_proc_available_memory() / 1_048_576)MB"
    }

    /// What iOS counts against the extension's memory limit (`phys_footprint`).
    private static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
    #endif
}
