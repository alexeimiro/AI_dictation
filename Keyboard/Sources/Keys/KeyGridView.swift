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
        background.layer.cornerRadius = 10
        background.layer.cornerCurve = .continuous
        background.layer.borderWidth = 0.6
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
            titleLabel.font = isCharacter
                ? .systemFont(ofSize: 23, weight: .regular)
                : .systemFont(ofSize: 15, weight: .medium)
        }
        if let systemImage = spec.systemImage {
            iconView.image = UIImage(systemName: systemImage,
                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
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

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = bounds.insetBy(dx: 3, dy: 4)
        background.frame = inset
        titleLabel.frame = inset.insetBy(dx: 2, dy: 0)
        iconView.frame = inset
    }

    private func updateColors() {
        let base: UIColor
        switch spec.style {
        case .character:
            base = KeyboardChrome.keyUIColor
        case .function:
            base = KeyboardChrome.functionKeyUIColor
        case .returnKey:
            base = KeyboardChrome.accentUIColor
        }
        let highlighted = spec.style == .returnKey
            ? KeyboardChrome.accentUIColor.withAlphaComponent(0.72)
            : KeyboardChrome.pressedKeyUIColor
        background.backgroundColor = isHighlighted ? highlighted : base
        let foreground = spec.style == .returnKey ? KeyboardChrome.accentGlyphUIColor : UIColor.label
        titleLabel.textColor = foreground
        iconView.tintColor = foreground
        background.layer.borderColor = KeyboardChrome.borderUIColor.resolvedColor(with: traitCollection).cgColor
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.22 : 0.13
        background.layer.shadowOffset = CGSize(width: 0, height: isHighlighted ? 0.5 : 1.5)
        background.layer.shadowRadius = isHighlighted ? 0.5 : 1.5
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
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: rowHeight * 4 + 8)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalPadding: CGFloat = 3
        let width = bounds.width - horizontalPadding * 2
        let rowCount = CGFloat(max(rows.count, 1))
        let height = min(rowHeight, (bounds.height - 4) / rowCount)
        // Reference unit: a 10-key row fills the width.
        let unit = width / 10

        for (rowIndex, row) in rows.enumerated() {
            let totalWeight = row.reduce(0) { $0 + $1.spec.weight }
            // Rows narrower than 10 units (e.g. "asdfghjkl") are centered; wider rows scale down.
            let rowWidth = min(width, totalWeight * unit)
            let scale = rowWidth / (totalWeight * unit)
            var x = horizontalPadding + (width - rowWidth) / 2
            let y = 2 + CGFloat(rowIndex) * height
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
