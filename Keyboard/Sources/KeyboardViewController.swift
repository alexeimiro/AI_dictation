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
    private let repeater = KeyRepeater()
    private let settings = SharedSettings.shared
    private var toolbarHost: UIHostingController<KeyboardToolbar>?
    private var panelHost: UIHostingController<ListeningPanel>?
    private var client: KeyboardSessionClient?
    private var plane: KeyboardPlane = .numbers
    private var shift: ShiftState = .off
    private var lastShiftTap = Date.distantPast
    private var lastInsertedDictation: String?
    private var layoutSignature = ""
    private var memoryTimer: Timer?
    private lazy var haptics = UIImpactFeedbackGenerator(style: .light)

    private static let keyboardHeight: CGFloat = 272

    // MARK: Lifecycle

    override func loadView() {
        let inputView = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView.allowsSelfSizing = true
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
        plane = settings.keyboardLayout == .qwerty ? .letters : .numbers
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.hasFullAccess = hasFullAccess
        model.defaultStyle = settings.defaultStyle
        loadLanguages()
        if hasFullAccess { haptics.prepare() }
        updateAutoShift()
        reloadKeys()
        client?.activate()
        startMemoryReadout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        repeater.stop()
        client?.deactivate()
        memoryTimer?.invalidate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateAutoShift()
        reloadKeys()
    }

    // MARK: Views

    private func buildViews() {
        guard let view else { return }
        let toolbar = embed(KeyboardToolbar(model: model), in: view)
        let panel = embed(ListeningPanel(model: model), in: view)
        toolbarHost = toolbar
        panelHost = panel

        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        keyGrid.globeTarget = self
        keyGrid.onKeyDown = { [weak self] spec in self?.keyDown(spec) }
        keyGrid.onKeyUp = { [weak self] spec in self?.keyUp(spec) }
        view.addSubview(keyGrid)

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
        ])
        panel.view.isHidden = true
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
        let showsGlobe = needsInputModeSwitchKey
        let signature = "\(plane)|\(shift)|\(showsGlobe)|\(returnTitle)"
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        keyGrid.configure(rows: KeyboardLayouts.rows(
            for: plane, shift: shift, showsGlobe: showsGlobe, returnTitle: returnTitle))
    }

    private func updateCaptureUI() {
        let capturing = model.isCapturing
        panelHost?.view.isHidden = !capturing
        keyGrid.isHidden = capturing
    }

    private func wireActions() {
        model.actions = KeyboardModel.Actions(
            mic: { [weak self] in self?.client?.micTapped() },
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
                self?.model.languageOverride = language
                self?.client?.languageOverride = language?.tag
            })
    }

    /// The language pill offers the secondary language only once the app has verified its
    /// model, so a switch never lands on a language that can't be recognized.
    private func loadLanguages() {
        let primary = settings.primaryLanguage.map(DictationLanguage.init(tag:)) ?? .englishUS
        let verified = settings.verifiedEngines
        let secondary = settings.secondaryLanguage.flatMap { tag -> DictationLanguage? in
            guard tag != primary.tag, verified[tag] != nil else { return nil }
            return DictationLanguage(tag: tag)
        }
        model.primaryLanguage = primary
        model.secondaryLanguage = secondary
        if let override = model.languageOverride, override != secondary {
            model.languageOverride = nil
            client?.languageOverride = nil
        }
    }

    // MARK: Keys

    private func keyDown(_ spec: KeySpec) {
        feedback()
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
        lastInsertedDictation = text
    }

    func sessionClientDidChange(_ client: KeyboardSessionClient) {
        model.update(from: client)
        updateCaptureUI()
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

    private func startMemoryReadout() {
        #if DEBUG
        memoryTimer?.invalidate()
        updateMemoryReadout()
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMemoryReadout() }
        }
        #endif
    }

    /// Memory left before the extension is killed (the simulator doesn't enforce the limit).
    private func updateMemoryReadout() {
        model.debugMemory = "\(os_proc_available_memory() / 1_048_576)MB"
    }
}
