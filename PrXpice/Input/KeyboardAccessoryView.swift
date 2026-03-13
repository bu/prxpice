import UIKit

/// Horizontally scrollable toolbar above the system keyboard.
/// Swipe down to collapse to a thin handle; swipe up on handle to expand.
final class KeyboardAccessoryView: UIView {

    var onTapScancode: ((_ scancode: UInt32) -> Void)?
    var onModifierDown: ((_ scancode: UInt32) -> Void)?
    var onModifierUp: ((_ scancode: UInt32) -> Void)?
    var onHideKeyboard: (() -> Void)?

    // MARK: - Dynamic colors

    private static let kbBackground = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.212, green: 0.212, blue: 0.220, alpha: 1)
            : UIColor(red: 0.820, green: 0.835, blue: 0.855, alpha: 1)
    }
    private static let keyNormal = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.380, green: 0.380, blue: 0.400, alpha: 1)
            : .white
    }
    private static let keyDark = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.270, green: 0.270, blue: 0.280, alpha: 1)
            : UIColor(red: 0.690, green: 0.706, blue: 0.729, alpha: 1)
    }
    private static let keyActive = UIColor.systemBlue

    // MARK: - Layout constants

    private let expandedHeight: CGFloat = 44
    private let collapsedHeight: CGFloat = 16
    private var heightConstraint: NSLayoutConstraint!

    // MARK: - Key definitions

    private enum SC {
        static let esc:    UInt32 = 0x01
        static let tab:    UInt32 = 0x0F
        static let ctrl:   UInt32 = 0x1D
        static let alt:    UInt32 = 0x38
        static let del:    UInt32 = 0xE053
        static let left:   UInt32 = 0xE04B
        static let right:  UInt32 = 0xE04D
        static let up:     UInt32 = 0xE048
        static let down:   UInt32 = 0xE050
        static let fKeys: [UInt32] = [0x3B,0x3C,0x3D,0x3E,0x3F,0x40,0x41,0x42,0x43,0x44,0x57,0x58]
    }

    private struct KeyDef {
        let label: String
        let scancode: UInt32
        let isModifier: Bool
        let isDark: Bool
        let width: CGFloat
    }

    private var allKeys: [KeyDef] {
        var keys: [KeyDef] = [
            KeyDef(label: "Esc",  scancode: SC.esc,  isModifier: false, isDark: true,  width: 1.0),
            KeyDef(label: "Tab",  scancode: SC.tab,  isModifier: false, isDark: true,  width: 1.0),
            KeyDef(label: "Ctrl", scancode: SC.ctrl, isModifier: true,  isDark: false, width: 1.0),
            KeyDef(label: "Alt",  scancode: SC.alt,  isModifier: true,  isDark: false, width: 1.0),
            KeyDef(label: "Del",  scancode: SC.del,  isModifier: false, isDark: true,  width: 1.0),
        ]
        keys += SC.fKeys.enumerated().map { i, sc in
            KeyDef(label: "F\(i+1)", scancode: sc, isModifier: false, isDark: false, width: 1.0)
        }
        keys += [
            KeyDef(label: "←", scancode: SC.left,  isModifier: false, isDark: false, width: 0.9),
            KeyDef(label: "↑", scancode: SC.up,    isModifier: false, isDark: false, width: 0.9),
            KeyDef(label: "↓", scancode: SC.down,  isModifier: false, isDark: false, width: 0.9),
            KeyDef(label: "→", scancode: SC.right, isModifier: false, isDark: false, width: 0.9),
        ]
        return keys
    }

    // MARK: - State

    private var activeModifiers: Set<UInt32> = []
    private var keyButtons: [UIButton] = []
    private var isCollapsed = false

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let handle = UIView()       // always-visible drag handle strip
    private let handlePill = UIView()   // visual pill inside handle
    private let hideKbButton = UIButton(type: .custom)

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear

        // Height constraint — driven by expand/collapse
        heightConstraint = heightAnchor.constraint(equalToConstant: expandedHeight)
        heightConstraint.isActive = true

        // Scrollable key area
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        // Hide keyboard button — fixed to right edge, always visible
        let img = UIImage(systemName: "keyboard.chevron.compact.down",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        hideKbButton.setImage(img, for: .normal)
        hideKbButton.tintColor = .label
        hideKbButton.backgroundColor = Self.keyDark
        hideKbButton.layer.cornerRadius = 5
        hideKbButton.layer.shadowColor = UIColor.black.cgColor
        hideKbButton.layer.shadowOpacity = 0.35
        hideKbButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        hideKbButton.layer.shadowRadius = 0
        hideKbButton.translatesAutoresizingMaskIntoConstraints = false
        hideKbButton.addTarget(self, action: #selector(hideKeyboardTapped), for: .touchUpInside)
        addSubview(hideKbButton)

        NSLayoutConstraint.activate([
            hideKbButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hideKbButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            hideKbButton.widthAnchor.constraint(equalToConstant: 44),
            hideKbButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            hideKbButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: hideKbButton.leadingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor, constant: -12),
        ])

        // Handle — sits on top, full width, collapsed height
        handle.backgroundColor = .clear
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.heightAnchor.constraint(equalToConstant: collapsedHeight),
        ])

        // Pill indicator inside handle
        handlePill.backgroundColor = UIColor.systemGray3
        handlePill.layer.cornerRadius = 2
        handlePill.translatesAutoresizingMaskIntoConstraints = false
        handlePill.alpha = 0  // hidden when expanded
        handle.addSubview(handlePill)
        NSLayoutConstraint.activate([
            handlePill.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            handlePill.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            handlePill.widthAnchor.constraint(equalToConstant: 36),
            handlePill.heightAnchor.constraint(equalToConstant: 4),
        ])

        // Swipe gestures
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
        swipeDown.direction = .down
        addGestureRecognizer(swipeDown)

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
        swipeUp.direction = .up
        handle.addGestureRecognizer(swipeUp)
        handle.isUserInteractionEnabled = true

        buildButtons()
    }

    // MARK: - Collapse / Expand

    @objc private func handleSwipeDown() {
        guard !isCollapsed else { return }
        isCollapsed = true
        heightConstraint.constant = collapsedHeight
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.scrollView.alpha = 0
            self.hideKbButton.alpha = 0
            self.handlePill.alpha = 1
            self.superview?.layoutIfNeeded()
        }
    }

    @objc private func handleSwipeUp() {
        guard isCollapsed else { return }
        isCollapsed = false
        heightConstraint.constant = expandedHeight
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.scrollView.alpha = 1
            self.hideKbButton.alpha = 1
            self.handlePill.alpha = 0
            self.superview?.layoutIfNeeded()
        }
    }

    @objc private func hideKeyboardTapped() {
        onHideKeyboard?()
    }

    // MARK: - Trait changes

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        buildButtons()
    }

    // MARK: - Button building

    private func buildButtons() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll()

        for key in allKeys {
            let btn = makeButton(label: key.label, isDark: key.isDark)
            btn.tag = Int(key.scancode)
            if key.isModifier {
                btn.addTarget(self, action: #selector(modifierTapped(_:)), for: .touchUpInside)
                if activeModifiers.contains(key.scancode) { applyActiveStyle(btn) }
            } else {
                btn.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            }
            btn.widthAnchor.constraint(equalTo: btn.heightAnchor, multiplier: key.width * 1.6).isActive = true
            stack.addArrangedSubview(btn)
            keyButtons.append(btn)
        }
    }

    private func makeButton(label: String, isDark: Bool) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(label, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        btn.setTitleColor(.label, for: .normal)
        btn.backgroundColor = isDark ? Self.keyDark : Self.keyNormal
        btn.layer.cornerRadius = 5
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.35
        btn.layer.shadowOffset = CGSize(width: 0, height: 1)
        btn.layer.shadowRadius = 0
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    private func applyActiveStyle(_ btn: UIButton) {
        btn.backgroundColor = Self.keyActive
        btn.setTitleColor(.white, for: .normal)
    }

    private func applyNormalStyle(_ btn: UIButton, isDark: Bool = false) {
        btn.backgroundColor = isDark ? Self.keyDark : Self.keyNormal
        btn.setTitleColor(.label, for: .normal)
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: UIButton) {
        onTapScancode?(UInt32(sender.tag))
        releaseAllModifiers()
    }

    @objc private func modifierTapped(_ sender: UIButton) {
        let sc = UInt32(sender.tag)
        if activeModifiers.contains(sc) {
            activeModifiers.remove(sc)
            onModifierUp?(sc)
            applyNormalStyle(sender)
        } else {
            activeModifiers.insert(sc)
            onModifierDown?(sc)
            applyActiveStyle(sender)
        }
    }

    func releaseAllModifiers() {
        guard !activeModifiers.isEmpty else { return }
        for sc in activeModifiers { onModifierUp?(sc) }
        activeModifiers.removeAll()
        buildButtons()
    }
}
