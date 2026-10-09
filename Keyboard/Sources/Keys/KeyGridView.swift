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
        background.layer.cornerRadius = 8
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

        if let label = spec.label {
            titleLabel.text = label
            let isCharacter = spec.style == .character && label.count == 1
            titleLabel.font = isCharacter
                ? .systemFont(ofSize: 25, weight: .regular)
                : .systemFont(ofSize: 16, weight: .regular)
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
        didSet { updateColors() }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = bounds.insetBy(dx: 3, dy: 5)
        background.frame = inset
        titleLabel.frame = inset.insetBy(dx: 2, dy: 0)
        iconView.frame = inset
    }

    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let base: UIColor
        switch spec.style {
        case .character:
            base = dark ? UIColor(white: 0.42, alpha: 1) : .white
        case .function:
            base = dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1)
        case .returnKey:
            base = dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1)
        }
        let highlighted = spec.style == .character
            ? (dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.69, green: 0.71, blue: 0.75, alpha: 1))
            : (dark ? UIColor(white: 0.42, alpha: 1) : .white)
        background.backgroundColor = isHighlighted ? highlighted : base
        titleLabel.textColor = dark ? .white : .black
        iconView.tintColor = dark ? .white : .black
        background.layer.shadowColor = UIColor.black.cgColor
        background.layer.shadowOpacity = dark ? 0 : 0.25
        background.layer.shadowOffset = CGSize(width: 0, height: 1)
        background.layer.shadowRadius = 0
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
        case .globe: "Next keyboard"
        }
    }
}

/// Lays out rows of `KeyButton`s with proportional widths.
final class KeyGridView: UIView {
    var onKeyDown: ((KeySpec) -> Void)?
    var onKeyUp: ((KeySpec) -> Void)?
    /// The globe key must forward its touches to `handleInputModeList(from:with:)`.
    weak var globeTarget: UIInputViewController?

    private var rows: [[KeyButton]] = []
    private let rowHeight: CGFloat = 54

    func configure(rows specs: [[KeySpec]]) {
        rows.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        rows = specs.map { row in
            row.map { spec in
                let button = KeyButton(spec: spec)
                if spec.action == .globe, let globeTarget {
                    button.addTarget(globeTarget,
                                     action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                                     for: .allTouchEvents)
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
}
