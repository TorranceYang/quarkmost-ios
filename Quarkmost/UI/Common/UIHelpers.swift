import UIKit

extension UILabel {
    convenience init(_ text: String, _ style: Typography.Style, color: UIColor, lines: Int = 1,
                     alignment: NSTextAlignment = .natural) {
        self.init()
        numberOfLines = lines
        set(text, style, color: color, alignment: alignment)
        adjustsFontForContentSizeCategory = true
    }

    func set(_ text: String, _ style: Typography.Style, color: UIColor, alignment: NSTextAlignment = .natural) {
        var attrs = style.attributes(color: color, alignment: alignment)
        if let p = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            // Multi-line labels wrap; single-line ones end in "…" rather than being clipped.
            p.lineBreakMode = numberOfLines != 1 ? .byWordWrapping : .byTruncatingTail
            attrs[.paragraphStyle] = p
        }
        attributedText = NSAttributedString(string: text, attributes: attrs)
    }
}

/// Round profile picture with an optional status badge, loaded through `ImageLoader`.
final class AvatarView: UIView {
    private let imageView = UIImageView()
    private let ring = UIView()
    private let statusIcon = UIImageView()
    private var task: Task<Void, Never>?
    private var size: CGFloat
    private var currentURL: URL?

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        addSubview(imageView)
        addSubview(ring)
        ring.addSubview(statusIcon)
        ring.isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: size, height: size) }

    func setUser(_ userId: String?, pictureUpdate: Int64? = nil, overrideURL: URL? = nil) {
        task?.cancel()
        let theme = Theme.current
        guard let url = overrideURL ?? userId.map({ ImageLoader.profileImageURL(userId: $0, lastPictureUpdate: pictureUpdate) }) else {
            imageView.image = CompassIcon.image("account-outline", size: size)
            imageView.tintColor = theme.centerChannelColor.opacity(0.48)
            return
        }
        currentURL = url
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        if let hit = ImageLoader.shared.cached(url, pointSize: size, scale: scale) { imageView.image = hit; return }
        imageView.image = CompassIcon.image("account-outline", size: size)
        imageView.tintColor = theme.centerChannelColor.opacity(0.32)
        let size = self.size
        task = Task { [weak self] in
            guard let image = await ImageLoader.shared.image(url, pointSize: size, scale: scale),
                  !Task.isCancelled, let self, self.currentURL == url else { return }
            self.imageView.image = image
        }
    }

    /// Shows the status badge ("online", "away", "dnd", "offline"); nil hides it.
    func setStatus(_ status: String?, background: UIColor) {
        guard let status else { ring.isHidden = true; return }
        let theme = Theme.current
        let (name, color): (String, UIColor) = switch status {
        case "online": ("check-circle", theme.onlineIndicator)
        case "away": ("clock", theme.awayIndicator)
        case "dnd": ("minus-circle", theme.dndIndicator)
        default: ("circle-outline", theme.centerChannelColor.opacity(0.48))
        }
        let s = max(12, (size * 0.3).rounded())
        ring.isHidden = false
        ring.backgroundColor = background
        ring.layer.cornerRadius = (s + 4) / 2
        ring.frame = CGRect(x: size - s - 1, y: size - s - 1, width: s + 4, height: s + 4)
        statusIcon.frame = CGRect(x: 2, y: 2, width: s, height: s)
        statusIcon.image = CompassIcon.image(name, size: s)
        statusIcon.tintColor = color
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }
}

/// A tappable settings-style row: icon, title, optional subtitle and detail, optional accessory.
final class MenuRow: UIControl {
    enum Accessory { case none, chevron, check(Bool), toggle(Bool) }

    let iconView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let detailLabel = UILabel()
    private let accessoryView = UIImageView()
    let toggle = UISwitch()
    var onToggle: ((Bool) -> Void)?
    private var action: (() -> Void)?

    init(icon: String?, title: String, subtitle: String? = nil, detail: String? = nil, destructive: Bool = false,
         accessory: Accessory = .none, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.action = action
        let theme = Theme.current
        let color = destructive ? theme.dndIndicator : theme.centerChannelColor
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        text.isUserInteractionEnabled = false
        titleLabel.numberOfLines = 0
        subtitleLabel.numberOfLines = 0
        titleLabel.set(title, Typography.style(.body, 200), color: color)
        if let subtitle { subtitleLabel.set(subtitle, Typography.style(.body, 75), color: theme.centerChannelColor.opacity(0.64)) }
        subtitleLabel.isHidden = subtitle == nil
        detailLabel.set(detail ?? "", Typography.style(.body, 100), color: theme.centerChannelColor.opacity(0.56))
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.image = icon.flatMap { CompassIcon.image($0, size: 24) }
        iconView.tintColor = destructive ? theme.dndIndicator : theme.centerChannelColor.opacity(0.64)
        iconView.isHidden = icon == nil
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true
        accessoryView.tintColor = theme.centerChannelColor.opacity(0.32)
        accessoryView.setContentHuggingPriority(.required, for: .horizontal)
        toggle.onTintColor = theme.buttonBg
        toggle.addAction(UIAction { [weak self] _ in self?.onToggle?(self?.toggle.isOn ?? false) }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [iconView, text, detailLabel, accessoryView, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.setCustomSpacing(16, after: iconView)
        row.translatesAutoresizingMaskIntoConstraints = false
        [iconView, detailLabel, accessoryView].forEach { $0.isUserInteractionEnabled = false }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        setAccessory(accessory)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setAccessory(_ accessory: Accessory) {
        accessoryView.isHidden = true
        toggle.isHidden = true
        switch accessory {
        case .none: break
        case .chevron:
            accessoryView.isHidden = false
            accessoryView.image = CompassIcon.image("chevron-right", size: 24)
            accessoryView.tintColor = Theme.current.centerChannelColor.opacity(0.32)
        case .check(let on):
            accessoryView.isHidden = !on
            accessoryView.image = CompassIcon.image("check", size: 24)
            accessoryView.tintColor = Theme.current.buttonBg
            accessibilityTraits = on ? [.button, .selected] : .button
        case .toggle(let on):
            toggle.isHidden = false
            toggle.isOn = on
        }
    }

    func setDetail(_ text: String) {
        detailLabel.set(text, Typography.style(.body, 100), color: Theme.current.centerChannelColor.opacity(0.56))
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
}

/// Base for the settings-like screens: a scrolling vertical stack on the center background.
class StackScreenViewController: UIViewController {
    let scrollView = UIScrollView()
    let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.current.centerChannelBg
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
        ])
    }

    func clear() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    func addDivider() {
        let line = UIView()
        line.backgroundColor = Theme.current.centerChannelColor.opacity(0.12)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let wrap = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -20),
        ])
        stack.addArrangedSubview(wrap)
    }

    func addSectionTitle(_ text: String) {
        let label = UILabel(text.uppercased(), Typography.style(.heading, 75), color: Theme.current.centerChannelColor.opacity(0.56))
        addPadded(label, top: 20, bottom: 8)
    }

    func addText(_ text: String, style: Typography.Style = Typography.style(.body, 100), alpha: CGFloat = 0.72) {
        let label = UILabel(text, style, color: Theme.current.centerChannelColor.opacity(alpha), lines: 0)
        addPadded(label, top: 4, bottom: 8)
    }

    func addPadded(_ view: UIView, top: CGFloat = 0, bottom: CGFloat = 0, side: CGFloat = 20) {
        let wrap = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: top),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -bottom),
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: side),
            view.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -side),
        ])
        stack.addArrangedSubview(wrap)
    }
}

extension UIViewController {
    /// Small confirmation pill near the bottom, like the official snack bar.
    func showToast(_ text: String) {
        let theme = Theme.current
        let host: UIView = view.window ?? view
        let label = PaddedLabel()
        label.attributedText = NSAttributedString(
            string: text, attributes: Typography.style(.body, 100, .semibold).attributes(color: theme.centerChannelBg))
        label.backgroundColor = theme.centerChannelColor
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 1.6) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
        }
    }

    /// Official-style bottom sheet of option rows.
    func presentOptions(_ options: [PostOptionsViewController.Option], title: String? = nil) {
        let sheet = PostOptionsViewController(options: options, showsReactionBar: false, title: title)
        view.endEditing(true)
        present(sheet, animated: true)
    }

    func confirm(title: String, message: String, action: String, destructive: Bool = true, _ run: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: action, style: destructive ? .destructive : .default) { _ in run() })
        present(alert, animated: true)
    }

    func showError(_ error: Error) {
        let message = (error as? APIError)?.message ?? error.localizedDescription
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Wraps a screen in a themed navigation controller for modal presentation, with a Close button.
    func wrappedForModal() -> UINavigationController {
        let nav = ThemedNavigationController(rootViewController: self)
        nav.applyThemedBar()
        if navigationItem.leftBarButtonItem == nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: CompassIcon.image("close", size: 24), primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
            navigationItem.leftBarButtonItem?.accessibilityLabel = "Close"
        }
        return nav
    }
}

extension UINavigationController {
    /// The official header: sidebar color, Metropolis title, white controls.
    func applyThemedBar() {
        let theme = Theme.current
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = theme.sidebarBg
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = Typography.style(.heading, 300)
            .attributes(color: theme.sidebarHeaderTextColor, alignment: .center)
        let back = CompassIcon.image("arrow-back-ios", size: 24)
        appearance.setBackIndicatorImage(back, transitionMaskImage: back)
        appearance.backButtonAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.clear]
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.tintColor = theme.sidebarHeaderTextColor
    }
}

/// Text field in the official "floating input" spirit: bordered, themed.
final class ThemedTextField: UITextField {
    init(placeholder: String) {
        super.init(frame: .zero)
        let theme = Theme.current
        font = Typography.style(.body, 200).font
        adjustsFontForContentSizeCategory = true
        textColor = theme.centerChannelColor
        tintColor = theme.linkColor
        attributedPlaceholder = NSAttributedString(string: placeholder,
                                                   attributes: [.foregroundColor: theme.centerChannelColor.opacity(0.48)])
        layer.cornerRadius = 4
        layer.borderWidth = 1
        layer.borderColor = theme.centerChannelColor.opacity(0.16).cgColor
        keyboardAppearance = theme.centerChannelBg.luminance < 0.5 ? .dark : .light
        leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        leftViewMode = .always
        rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        rightViewMode = .always
        heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

func formatFileSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

/// Flat search field in the official style (rounded 8pt box, magnifier, no system glass).
/// `onSidebar` uses the sidebar colors (Search tab header); otherwise the center-channel colors.
final class FlatSearchField: UITextField {
    private let icon = UIImageView()
    private let onSidebar: Bool

    init(placeholder: String, onSidebar: Bool = false) {
        self.onSidebar = onSidebar
        super.init(frame: .zero)
        let theme = Theme.current
        let base = onSidebar ? theme.sidebarText : theme.centerChannelColor
        font = Typography.style(.body, 200).font
        adjustsFontForContentSizeCategory = true
        textColor = base
        tintColor = onSidebar ? theme.sidebarText : theme.linkColor
        backgroundColor = base.opacity(onSidebar ? 0.12 : 0.08)
        layer.cornerRadius = 8
        borderStyle = .none
        autocapitalizationType = .none
        autocorrectionType = .no
        clearButtonMode = .whileEditing
        keyboardAppearance = (onSidebar ? theme.sidebarBg : theme.centerChannelBg).luminance < 0.5 ? .dark : .light
        icon.image = CompassIcon.image("magnify", size: 24)
        icon.tintColor = base.opacity(0.72)
        icon.contentMode = .center
        icon.frame = CGRect(x: 8, y: 0, width: 24, height: 40)
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 40))
        holder.addSubview(icon)
        leftView = holder
        leftViewMode = .always
        setPlaceholder(placeholder)
        accessibilityTraits.insert(.searchField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setPlaceholder(_ text: String) {
        let theme = Theme.current
        let base = onSidebar ? theme.sidebarText : theme.centerChannelColor
        attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: base.opacity(0.64)])
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        super.clearButtonRect(forBounds: bounds).offsetBy(dx: -6, dy: 0)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { super.textRect(forBounds: bounds).inset(by: .init(top: 0, left: 0, bottom: 0, right: 8)) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { super.editingRect(forBounds: bounds).inset(by: .init(top: 0, left: 0, bottom: 0, right: 8)) }
}

/// Flat text tabs with a tinted pill on the selected one (the official "Messages / Files" and
/// "All Your Threads / Unreads" switches), instead of the system segmented control.
final class FlatTabs: UIView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private var buttons: [UIButton] = []
    private let titles: [String]

    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        for (i, _) in titles.enumerated() {
            let b = UIButton(type: .custom)
            b.layer.cornerRadius = 4
            b.addAction(UIAction { [weak self] _ in self?.select(i, notify: true) }, for: .primaryActionTriggered)
            stack.addArrangedSubview(b)
            buttons.append(b)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int, notify: Bool = false) {
        guard index != selectedIndex || !notify else { return }
        selectedIndex = index
        refresh()
        if notify { onChange?(index) }
    }

    private func refresh() {
        let theme = Theme.current
        for (i, b) in buttons.enumerated() {
            let on = i == selectedIndex
            var config = UIButton.Configuration.plain()
            var title = AttributedString(titles[i])
            title.font = Typography.style(.body, 100, .semibold).font
            title.foregroundColor = on ? theme.buttonBg : theme.centerChannelColor.opacity(0.56)
            config.attributedTitle = title
            config.baseForegroundColor = on ? theme.buttonBg : theme.centerChannelColor.opacity(0.56)
            config.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
            b.configuration = config
            b.setNeedsUpdateConfiguration()
            b.layer.backgroundColor = (on ? theme.buttonBg.opacity(0.08) : UIColor.clear).cgColor
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}
