import UIKit

/// Liquid Glass surfaces (iOS 26), with a blur fallback on older systems.
@MainActor
enum Glass {
    /// Glass follows light/dark mode, but the app's colours come from the Mattermost theme; match it.
    static var style: UIUserInterfaceStyle {
        var white: CGFloat = 0
        Theme.current.centerChannelBg.getWhite(&white, alpha: nil)
        return white < 0.5 ? .dark : .light
    }

    /// A glass background. `cornerRadius` nil makes a capsule.
    static func make(cornerRadius: CGFloat? = nil, interactive: Bool = false) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = interactive
            let view = UIVisualEffectView(effect: effect)
            view.cornerConfiguration = cornerRadius.map { .uniformCorners(radius: .fixed($0)) } ?? .capsule()
            return view
        }
        let view = CapsuleBlurView(effect: UIBlurEffect(style: .systemThinMaterial))   // follows overrideUserInterfaceStyle
        view.radius = cornerRadius
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous
        return view
    }
}

private final class CapsuleBlurView: UIVisualEffectView {
    var radius: CGFloat?
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = radius ?? bounds.height / 2
    }
}

/// The conversation's floating title pill: channel icon, name and member count on glass over the
/// messages. Tapping it opens the channel menu.
///
/// It sits on the messages' grid: the leading slot (Back on a phone, else the channel icon or the
/// DM avatar) is centred on the avatar column, and the title starts where names do.
final class GlassHeaderView: UIView {
    var onTap: (() -> Void)?
    var onBack: (() -> Void)?

    let avatar = AvatarView(size: 28)
    private let glass = Glass.make(interactive: true)
    private let back = UIButton(type: .system)
    private let titleArea = TitleArea()
    private let slotView = UIView()      // the channel icon or DM avatar
    private let icon = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let accessoryHolder = UIStackView()
    private var hasIcon = true

    static let height: CGFloat = 52
    /// Inset of the leading slot inside the pill; the pill itself sits this far left of the
    /// messages' side padding, so the slot lines up with their avatars.
    static let padding: CGFloat = 8
    private static let slot = PostLayout.avatar
    private static let slotGap = PostLayout.textX - PostLayout.side - PostLayout.avatar

    /// Back inside the pill, in the leading slot (in place of the channel icon).
    var showsBack = false {
        didSet {
            back.isHidden = !showsBack
            updateSlot()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        back.setImage(CompassIcon.image("arrow-back-ios", size: 24), for: .normal)
        back.accessibilityLabel = "Back"
        back.isHidden = true
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .primaryActionTriggered)

        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        icon.contentMode = .center
        for v in [icon, avatar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slotView.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: slotView.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: slotView.centerYAnchor),
            ])
        }
        let leading = UIStackView(arrangedSubviews: [slotView, text])
        leading.spacing = Self.slotGap
        leading.alignment = .center
        leading.isUserInteractionEnabled = false
        titleArea.embed(leading)
        titleArea.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)

        accessoryHolder.isHidden = true
        accessoryHolder.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [back, titleArea, accessoryHolder])
        row.spacing = Self.slotGap
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Self.padding),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            back.widthAnchor.constraint(equalToConstant: Self.slot),
            back.heightAnchor.constraint(equalTo: row.heightAnchor),
            slotView.widthAnchor.constraint(equalToConstant: Self.slot),
            slotView.heightAnchor.constraint(equalToConstant: Self.slot),
            titleArea.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
        // Back, the title (opens the menu) and any accessory, in that order.
        accessibilityElements = [back, titleArea, accessoryHolder]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `iconName` is a Compass icon; pass nil to show the avatar instead (DMs).
    func configure(iconName: String?, title titleText: String, subtitle subtitleText: String?,
                   hint: String, theme: Theme) {
        overrideUserInterfaceStyle = Glass.style
        back.tintColor = theme.centerChannelColor
        hasIcon = iconName != nil
        if let iconName {
            icon.image = CompassIcon.image(iconName, size: 20)
            icon.tintColor = theme.centerChannelColor.opacity(0.72)
        }
        updateSlot()
        title.set(titleText, Typography.style(.heading, 200), color: theme.centerChannelColor)
        subtitle.isHidden = subtitleText == nil
        if let subtitleText {
            subtitle.set(subtitleText, Typography.style(.body, 75), color: theme.centerChannelColor.opacity(0.64))
        }
        titleArea.accessibilityLabel = [titleText, subtitleText].compactMap { $0 }.joined(separator: ", ")
        titleArea.accessibilityHint = hint
    }

    /// The leading slot shows Back, or else the channel icon or DM avatar.
    private func updateSlot() {
        slotView.isHidden = showsBack
        icon.isHidden = !hasIcon
        avatar.isHidden = hasIcon
    }

    /// A trailing control inside the pill (e.g. Follow in threads).
    func setAccessory(_ control: UIControl?) {
        accessoryHolder.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let control { accessoryHolder.addArrangedSubview(control) }
        accessoryHolder.isHidden = control == nil
    }
}

/// The tappable title part of the pill; dims while pressed.
private final class TitleArea: UIControl {
    func embed(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}

/// A round glass button (Back), placed beside the title pill or in the Duo's side column.
final class GlassCircleButton: UIControl {
    private let glass = Glass.make(interactive: true)
    private let image = UIImageView()
    static let size: CGFloat = 48

    init(icon: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        image.image = CompassIcon.image(icon, size: 24)
        image.contentMode = .center
        image.frame = bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Icon colour; also matches the glass to the theme's light/dark.
    func setTint(_ color: UIColor) {
        image.tintColor = color
        overrideUserInterfaceStyle = Glass.style
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }
}

/// Fades the chat colour in behind the status bar and the floating header, so messages scrolling
/// underneath don't fight with the clock or the title.
final class TopScrim: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    func setColor(_ color: UIColor) {
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = [color.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.4, 1]
    }

    /// Fully opaque down to `solid` points (the status bar), then fading out.
    func setSolidHeight(_ solid: CGFloat) {
        guard let g = layer as? CAGradientLayer, bounds.height > 0 else { return }
        g.locations = [0, NSNumber(value: Double(min(0.95, solid / bounds.height))), 1]
    }
}

// MARK: - Channel menu

/// Opens from the title pill: a glass card in its place with quick buttons (favourite, add,
/// search) and the rest of the channel actions as rows.
final class ChannelMenuViewController: UIViewController {
    private let titleText: String
    private let subtitleText: String?
    private let buttons: [PostOptionsViewController.Option]
    private let rows: [PostOptionsViewController.Option]
    private let anchor: CGRect          // the pill, in window coordinates
    private let dim = UIView()
    private let card = Glass.make(cornerRadius: 26)
    private let stack = UIStackView()

    init(title: String, subtitle: String?, buttons: [PostOptionsViewController.Option],
         rows: [PostOptionsViewController.Option], anchor: CGRect) {
        self.titleText = title
        self.subtitleText = subtitle
        self.buttons = buttons
        self.rows = rows
        self.anchor = anchor
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = .clear
        card.overrideUserInterfaceStyle = Glass.style
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        dim.frame = view.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        view.addSubview(dim)
        view.addSubview(card)

        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -10),
        ])

        // Header: close, title and subtitle (same place as the pill it grew from).
        let close = UIButton(type: .system)
        close.setImage(CompassIcon.image("close", size: 22), for: .normal)
        close.tintColor = theme.centerChannelColor
        close.accessibilityLabel = "Close"
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        close.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let title = UILabel(titleText, Typography.style(.heading, 200), color: theme.centerChannelColor)
        let text = UIStackView(arrangedSubviews: [title])
        text.axis = .vertical
        if let subtitleText {
            text.addArrangedSubview(UILabel(subtitleText, Typography.style(.body, 75), color: theme.centerChannelColor.opacity(0.64)))
        }
        let header = UIStackView(arrangedSubviews: [close, text])
        header.spacing = 8
        header.alignment = .center
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(10, after: header)

        if !buttons.isEmpty {
            let row = UIStackView(arrangedSubviews: buttons.map { quickButton($0, theme) })
            row.spacing = 8
            row.distribution = .fillEqually
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(8, after: row)
        }
        for option in rows { stack.addArrangedSubview(menuRow(option, theme)) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let local = view.convert(anchor, from: nil)
        let width = local.width
        let size = stack.systemLayoutSizeFitting(CGSize(width: width - 32, height: 0),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let maxHeight = view.bounds.height - local.minY - view.safeAreaInsets.bottom - 16
        let frame = CGRect(x: local.minX, y: local.minY, width: width, height: min(maxHeight, size.height + 18))
        // bounds + center, not frame: the card is scaled while it animates in.
        card.bounds.size = frame.size
        card.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Grow down from the pill.
        view.layoutIfNeeded()
        card.transform = CGAffineTransform(scaleX: 0.96, y: 0.9).translatedBy(x: 0, y: -card.bounds.height * 0.05)
        transitionCoordinator?.animate(alongsideTransition: { _ in self.card.transform = .identity })
    }

    @objc private func close() { dismiss(animated: true) }

    private func run(_ option: PostOptionsViewController.Option) {
        dismiss(animated: true) { option.action() }
    }

    private func quickButton(_ option: PostOptionsViewController.Option, _ theme: Theme) -> UIView {
        var config = UIButton.Configuration.plain()
        config.image = CompassIcon.image(option.icon, size: 20)
        config.imagePadding = 6
        var t = AttributedString(option.title)
        t.font = Typography.style(.body, 100, .semibold).font
        config.attributedTitle = t
        config.baseForegroundColor = theme.centerChannelColor
        config.contentInsets = .init(top: 10, leading: 6, bottom: 10, trailing: 6)
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.run(option) })
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 1
        button.layer.borderColor = theme.centerChannelColor.opacity(0.16).cgColor
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return button
    }

    private func menuRow(_ option: PostOptionsViewController.Option, _ theme: Theme) -> UIView {
        let row = OptionRow()
        let color = option.destructive ? theme.dndIndicator : theme.centerChannelColor
        row.icon.image = CompassIcon.image(option.icon, size: 24)
        row.icon.tintColor = option.destructive ? theme.dndIndicator : theme.centerChannelColor.opacity(0.72)
        row.label.attributedText = NSAttributedString(string: option.title,
                                                      attributes: Typography.style(.body, 200).attributes(color: color))
        row.accessibilityLabel = option.title
        row.addAction(UIAction { [weak self] _ in self?.run(option) }, for: .touchUpInside)
        return row
    }
}
