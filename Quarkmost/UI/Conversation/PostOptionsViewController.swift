import UIKit

/// The official long-press sheet (`screens/post_options`): a reaction bar of recent emoji with a
/// "more" button, then option rows. Presented as a bottom sheet that sizes itself to its content.
final class PostOptionsViewController: UIViewController {
    struct Option {
        let icon: String
        let title: String
        var destructive = false
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
            stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)
        }
        for option in options { stack.addArrangedSubview(makeRow(option, theme)) }

    }

    private func fittingHeight() -> CGFloat {
        view.layoutIfNeeded()
        return stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 8 + 8
    }

    private func makeReactionBar(_ theme: Theme) -> UIView {
        let bar = UIStackView()
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 8
        bar.heightAnchor.constraint(equalToConstant: 48).isActive = true
        for name in EmojiStore.shared.recent.filter(EmojiStore.shared.exists).prefix(6) {
            let b = UIButton(type: .custom)
            if let emoji = EmojiStore.shared.unicode(for: name) {
                b.setTitle(emoji, for: .normal)
                b.titleLabel?.font = .systemFont(ofSize: 28)
            } else if let image = CustomEmojiStore.shared.image(name) {
                b.setImage(image.resized(to: 30), for: .normal)
            }
            b.layer.cornerRadius = 4
            b.layer.backgroundColor = theme.centerChannelColor.opacity(0.04).cgColor
            b.accessibilityLabel = "React with \(name.replacingOccurrences(of: "_", with: " "))"
            b.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { self?.onReact?(name) } },
                        for: .primaryActionTriggered)
            bar.addArrangedSubview(b)
        }
        let more = UIButton(type: .custom)
        more.setImage(CompassIcon.image("emoticon-plus-outline", size: 28), for: .normal)
        more.tintColor = theme.centerChannelColor.opacity(0.64)
        more.layer.cornerRadius = 4
        more.layer.backgroundColor = theme.centerChannelColor.opacity(0.04).cgColor
        more.accessibilityLabel = "More reactions"
        more.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) { self?.onMoreReactions?() } },
                       for: .primaryActionTriggered)
        bar.addArrangedSubview(more)
        return bar
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

extension PostOptionsViewController {
    /// Tapping the dimmed area above the sheet closes it, like the official bottom sheet.
}

extension UIImage {
    func resized(to side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}
