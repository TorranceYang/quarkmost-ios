import UIKit

/// The long-press sheet. Mattermost's (`screens/post_options`) at heart — a reaction bar, then
/// option rows — with the three most-used actions pulled into one strip above the list.
/// A bottom sheet on a phone; a popover beside the message on a wide screen.
final class PostOptionsViewController: UIViewController {
    struct Option {
        let icon: String
        let title: String
        var destructive = false
        /// Shown in the quick-action strip above the list (at most three).
        var quick = false
        /// Label for a compact button (e.g. "Star" for "Favorite"); options that have one are the
        /// quick buttons in the channel menu.
        var shortTitle: String? = nil
        let action: () -> Void
    }

    var onReact: ((String) -> Void)?
    var onMoreReactions: (() -> Void)?

    private let options: [Option]
    private let stack = UIStackView()
    private let showsReactionBar: Bool
    private let sheetTitle: String?

    init(options: [Option], showsReactionBar: Bool = true, title: String? = nil) {
        self.options = options
        self.showsReactionBar = showsReactionBar
        self.sheetTitle = title
        super.init(nibName: nil, bundle: nil)
        BottomSheet.install(on: self, detents: [.fitting { [weak self] in self?.fittingHeight() ?? 300 }])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg

        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
        ])

        if let sheetTitle {
            let label = UILabel(sheetTitle, Typography.style(.heading, 600), color: theme.centerChannelColor, lines: 2)
            stack.addArrangedSubview(label)
            stack.setCustomSpacing(12, after: label)
        }
        if showsReactionBar {
            stack.addArrangedSubview(makeReactionBar(theme))
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        }
        let quick = Array(options.filter(\.quick).prefix(3))
        if !quick.isEmpty {
            stack.addArrangedSubview(makeQuickStrip(quick, theme))
            stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        }
        var dividerShown = false
        for option in options where !option.quick {
            if option.destructive, !dividerShown {
                dividerShown = true
                let line = UIView()
                line.backgroundColor = theme.centerChannelColor.opacity(0.08)
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(makeRow(option, theme))
        }
    }

    private func fittingHeight() -> CGFloat {
        view.layoutIfNeeded()
        return stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 8 + 8
    }

    /// Recent emoji in soft rounded squares (Mattermost's shape, a little rounder), then "more".
    private func makeReactionBar(_ theme: Theme) -> UIView {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.distribution = .equalSpacing
        bar.alignment = .center
        bar.heightAnchor.constraint(equalToConstant: 48).isActive = true
        func square(_ b: UIButton) {
            b.layer.cornerRadius = 12
            b.layer.cornerCurve = .continuous
            b.widthAnchor.constraint(equalToConstant: 46).isActive = true
            b.heightAnchor.constraint(equalToConstant: 46).isActive = true
            b.layer.backgroundColor = theme.centerChannelColor.opacity(0.08).cgColor
        }
        for name in EmojiStore.shared.recent.filter(EmojiStore.shared.exists).prefix(5) {
            let b = UIButton(type: .custom)
            if let emoji = EmojiStore.shared.unicode(for: name) {
                b.setTitle(emoji, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 26)
            } else if let image = CustomEmojiStore.shared.image(name) {
                b.setImage(image.resized(to: 28), for: .normal)
            }
            square(b)
            b.accessibilityLabel = "React with \(name.replacingOccurrences(of: "_", with: " "))"
            b.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { self?.onReact?(name) } },
                        for: .primaryActionTriggered)
            bar.addArrangedSubview(b)
        }
        let more = UIButton(type: .custom)
        more.setImage(CompassIcon.image("emoticon-plus-outline", size: 26), for: .normal)
        more.tintColor = theme.centerChannelColor.opacity(0.64)
        square(more)
        more.accessibilityLabel = "More reactions"
        more.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { self?.onMoreReactions?() } },
                       for: .primaryActionTriggered)
        bar.addArrangedSubview(more)
        return bar
    }

    /// One rounded strip split into equal segments: icon over a short label.
    private func makeQuickStrip(_ quick: [Option], _ theme: Theme) -> UIView {
        let strip = UIStackView()
        strip.axis = .horizontal
        strip.distribution = .fillEqually
        strip.backgroundColor = theme.centerChannelColor.opacity(0.06)
        strip.layer.cornerRadius = 14
        strip.layer.cornerCurve = .continuous
        strip.clipsToBounds = true
        strip.heightAnchor.constraint(equalToConstant: 62).isActive = true
        for (i, option) in quick.enumerated() {
            let segment = QuickSegment(option: option, theme: theme)
            segment.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { option.action() } },
                              for: .touchUpInside)
            if i > 0 {
                let line = UIView()
                line.backgroundColor = theme.centerChannelColor.opacity(0.1)
                line.translatesAutoresizingMaskIntoConstraints = false
                segment.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: segment.leadingAnchor),
                    line.widthAnchor.constraint(equalToConstant: 1),
                    line.topAnchor.constraint(equalTo: segment.topAnchor, constant: 14),
                    line.bottomAnchor.constraint(equalTo: segment.bottomAnchor, constant: -14),
                ])
            }
            strip.addArrangedSubview(segment)
        }
        return strip
    }

    private func makeRow(_ option: Option, _ theme: Theme) -> UIView {
        let row = OptionRow()
        let color = option.destructive ? theme.dndIndicator : theme.centerChannelColor
        row.icon.image = CompassIcon.image(option.icon, size: 24)
        row.icon.tintColor = option.destructive ? theme.dndIndicator : theme.centerChannelColor.opacity(0.64)
        row.label.attributedText = NSAttributedString(string: option.title,
                                                      attributes: Typography.style(.body, 200).attributes(color: color))
        row.accessibilityLabel = option.title
        row.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) { option.action() }
        }, for: .touchUpInside)
        return row
    }
}

/// 48pt row: 24pt icon, 16pt gap, label. Dims while pressed.
final class OptionRow: UIControl {
    let icon = UIImageView()
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        [icon, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
        label.adjustsFontForContentSizeCategory = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.4 : 1 } }
}

/// A segment of the quick-action strip. Darkens while pressed.
private final class QuickSegment: UIControl {
    private let tint: UIColor

    init(option: PostOptionsViewController.Option, theme: Theme) {
        tint = theme.centerChannelColor
        super.init(frame: .zero)
        let icon = UIImageView(image: CompassIcon.image(option.icon, size: 22))
        icon.tintColor = theme.centerChannelColor.opacity(0.8)
        icon.contentMode = .center
        let label = UILabel(option.title, Typography.style(.body, 75, .semibold), color: theme.centerChannelColor)
        label.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [icon, label])
        column.axis = .vertical
        column.spacing = 4
        column.alignment = .center
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = option.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? tint.opacity(0.08) : .clear }
    }
}

extension UIImage {
    func resized(to side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}
