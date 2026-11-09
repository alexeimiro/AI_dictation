import UIKit

/// A single key. UIKit (not SwiftUI gestures) so presses register on touch-down with no lag.
final class KeyButton: UIControl {
    let spec: KeySpec
    private let titleLabel = UILabel()
    private let iconView = UIImageView()
    private let background = UIView()

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isExclusiveTouch = true
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 8.5
        background.layer.cornerCurve = .continuous
        addSubview(background)

        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        titleLabel.isUserInteractionEnabled = false
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        addSubview(titleLabel)
        addSubview(iconView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (button: KeyButton, _: UITraitCollection) in
            button.updateColors()
        }

        if let label = spec.label {
            titleLabel.text = label
            let isCharacter = spec.style == .character && label.count == 1
            titleLabel.font = .systemFont(ofSize: isCharacter ? 24 : 17, weight: .regular)
        }
        if let systemImage = spec.systemImage {
            iconView.image = UIImage(systemName: systemImage,
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        }
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        accessibilityLabel = Self.accessibilityLabel(for: spec)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet {
            updateColors()
            let target = isHighlighted && !UIAccessibility.isReduceMotionEnabled
                ? CGAffineTransform(scaleX: 0.965, y: 0.965) : .identity
            guard transform != target else { return }
            if UIAccessibility.isReduceMotionEnabled {
                transform = target
                return
            }
            UIView.animate(withDuration: 0.08, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = target
            }
        }
    }

    /// Wispr's key face: 43 pt tall in a 53 pt row, 3 pt in from the sides plus the spec's gaps.
    override func layoutSubviews() {
        super.layoutSubviews()
        var face = bounds.insetBy(dx: 3, dy: 5)
        face.origin.x += spec.leadingGap
        face.size.width -= spec.leadingGap + spec.trailingGap
        background.frame = face
        titleLabel.frame = face.insetBy(dx: 2, dy: 0)
        iconView.frame = face
    }

    /// Wispr's keys: every key the same flat grey (white in light), no shadow. Increase Contrast
    /// adds a hairline.
    private func updateColors() {
        background.backgroundColor = isHighlighted ? KeyboardChrome.pressedKeyUIColor : KeyboardChrome.keyUIColor
        titleLabel.textColor = .label
        iconView.tintColor = .label
        background.layer.borderWidth = traitCollection.accessibilityContrast == .high ? 1 : 0
        background.layer.borderColor = KeyboardChrome.borderUIColor.resolvedColor(with: traitCollection).cgColor
    }

    private static func accessibilityLabel(for spec: KeySpec) -> String {
        switch spec.action {
        case .character(let value): value
        case .delete: "Delete"
        case .space: "Space"
        case .returnKey: spec.label ?? "Return"
        case .shift: "Shift"
        case .plane(.letters): "Letters"
        case .plane(.numbers): "Numbers"
        case .plane(.symbols): "More symbols"
        case .plane(.voice): "Voice pad"
        case .abc: "Letters"
        case .globe: "Next keyboard"
        }
    }
}

/// Lays out rows of `KeyButton`s with proportional widths.
final class KeyGridView: UIView {
    var onKeyDown: ((KeySpec) -> Void)?
    var onKeyUp: ((KeySpec) -> Void)?
    var onSpaceTrackStart: (() -> Void)?
    var onSpaceTrackMove: ((Int) -> Void)?
    /// The globe key must forward its touches to `handleInputModeList(from:with:)`.
    weak var globeTarget: UIInputViewController?

    private var rows: [[KeyButton]] = []
    /// Wispr's row pitch; rows share a shorter grid evenly.
    private let rowHeight: CGFloat = 54
    private var spaceTrackOrigin: CGPoint = .zero
    private var consumedSpaceTranslation: CGFloat = 0
    private static let cursorStep: CGFloat = 9

    func configure(rows specs: [[KeySpec]]) {
        rows.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        rows = specs.map { row in
            row.map { spec in
                let button = KeyButton(spec: spec)
                if spec.action == .globe, let globeTarget {
                    button.addTarget(globeTarget,
                                     action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                                     for: .allTouchEvents)
                } else if spec.action == .space {
                    // Delay insertion until release so a hold can turn the key into a trackpad.
                    button.addTarget(self, action: #selector(spaceTapped(_:)), for: .touchUpInside)
                    let hold = UILongPressGestureRecognizer(target: self, action: #selector(spaceTracked(_:)))
                    hold.minimumPressDuration = 0.35
                    hold.allowableMovement = .greatestFiniteMagnitude
                    button.addGestureRecognizer(hold)
                } else {
                    button.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
                    button.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
                }
                addSubview(button)
                return button
            }
        }
        if !typingEnabled { applyTypingEnabled() }
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: rowHeight * 4)
    }

    /// Off while a dictation runs: the typing keys dim and stop responding (return could send a
    /// message before the text lands). The globe stays live, as iOS expects.
    var typingEnabled = true {
        didSet {
            if typingEnabled != oldValue { applyTypingEnabled() }
        }
    }

    private func applyTypingEnabled() {
        for button in rows.joined() where button.spec.action != .globe {
            button.isEnabled = typingEnabled
            button.isUserInteractionEnabled = typingEnabled
            button.alpha = typingEnabled ? 1 : 0.4
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalPadding: CGFloat = 3
        let width = bounds.width - horizontalPadding * 2
        let rowCount = CGFloat(max(rows.count, 1))
        let height = min(rowHeight, bounds.height / rowCount)
        // Reference unit: a 10-key row fills the width.
        let unit = width / 10

        for (rowIndex, row) in rows.enumerated() {
            let totalWeight = row.reduce(0) { $0 + $1.spec.weight }
            // Rows narrower than 10 units (e.g. "asdfghjkl") are centered; wider rows scale down.
            let rowWidth = min(width, totalWeight * unit)
            let scale = rowWidth / (totalWeight * unit)
            var x = horizontalPadding + (width - rowWidth) / 2
            let y = CGFloat(rowIndex) * height
            for button in row {
                let keyWidth = button.spec.weight * unit * scale
                button.frame = CGRect(x: x, y: y, width: keyWidth, height: height)
                x += keyWidth
            }
        }
    }

    @objc private func keyDown(_ sender: KeyButton) {
        onKeyDown?(sender.spec)
    }

    @objc private func keyUp(_ sender: KeyButton) {
        onKeyUp?(sender.spec)
    }

    @objc private func spaceTapped(_ sender: KeyButton) {
        onKeyDown?(sender.spec)
        onKeyUp?(sender.spec)
    }

    @objc private func spaceTracked(_ gesture: UILongPressGestureRecognizer) {
        guard let button = gesture.view as? KeyButton else { return }
        switch gesture.state {
        case .began:
            spaceTrackOrigin = gesture.location(in: self)
            consumedSpaceTranslation = 0
            button.isHighlighted = true
            onSpaceTrackStart?()
        case .changed:
            let translation = gesture.location(in: self).x - spaceTrackOrigin.x
            let steps = Int((translation - consumedSpaceTranslation) / Self.cursorStep)
            guard steps != 0 else { return }
            consumedSpaceTranslation += CGFloat(steps) * Self.cursorStep
            onSpaceTrackMove?(steps)
        case .ended, .cancelled, .failed:
            button.isHighlighted = false
            consumedSpaceTranslation = 0
        default:
            break
        }
    }
}
