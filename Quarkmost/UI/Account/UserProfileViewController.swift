import UIKit

/// The profile bottom sheet (`screens/user_profile`): avatar with status, name, tags, custom status,
/// "Send message", then nickname / position / local time.
final class UserProfileViewController: StackScreenViewController {
    private let userId: String
    private let channelId: String?

    init(userId: String, channelId: String?) {
        self.userId = userId
        self.channelId = channelId
        super.init(nibName: nil, bundle: nil)
        BottomSheet.install(on: self, detents: [.medium, .large])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        Task {
            let session = AppSession.shared
            async let user = try? session.client.user(id: userId)
            async let status = try? session.client.statuses(userIds: [userId])
            if let u = await user { session.cache([u]) }
            if let s = await status?.first { session.setStatusLocally(s.userId, s.status) }
            build()
        }
    }

    private func build() {
        clear()
        let theme = Theme.current
        let session = AppSession.shared
        guard let user = session.user(userId) else {
            addText("Loading…")
            return
        }
        let avatar = AvatarView(size: 96)
        avatar.setUser(user.id, pictureUpdate: user.lastPictureUpdate)
        if !(user.isBot ?? false) { avatar.setStatus(session.status(user.id) ?? "offline", background: theme.centerChannelBg) }

        let name = UILabel(user.fullName.isEmpty ? user.username : user.fullName,
                           Typography.style(.heading, 600), color: theme.centerChannelColor, lines: 2)
        let handle = UILabel("@\(user.username)", Typography.style(.body, 200), color: theme.centerChannelColor.opacity(0.64))
        let text = UIStackView(arrangedSubviews: [name, handle])
        text.axis = .vertical
        text.spacing = 2
        var tags: [String] = []
        if user.isBot ?? false { tags.append("BOT") }
        if user.isSystemAdmin { tags.append("SYSTEM ADMIN") }
        if (user.deleteAt ?? 0) > 0 { tags.append("DEACTIVATED") }
        if !tags.isEmpty {
            let tagRow = UIStackView()
            tagRow.spacing = 6
            for t in tags {
                let l = PaddedTag(t)
                tagRow.addArrangedSubview(l)
            }
            tagRow.addArrangedSubview(UIView())
            text.addArrangedSubview(tagRow)
        }
        let top = UIStackView(arrangedSubviews: [avatar, text])
        top.spacing = 16
        top.alignment = .center
        let wrap = UIView()
        top.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(top)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 28), top.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -16),
            top.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 20), top.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -20),
        ])
        stack.addArrangedSubview(wrap)

        if let custom = user.customStatus {
            addText("\(EmojiStore.shared.unicode(for: custom.emoji) ?? "💬")  \(custom.text)", style: Typography.style(.body, 200), alpha: 1)
        }

        if (user.deleteAt ?? 0) == 0 {
            var config = UIButton.Configuration.filled()
            config.title = user.id == session.me?.id ? "Send a message to yourself" : "Send message"
            config.image = CompassIcon.image("send", size: 18)
            config.imagePadding = 8
            config.baseBackgroundColor = theme.buttonBg.opacity(0.08)
            config.baseForegroundColor = theme.buttonBg
            config.background.cornerRadius = 4
            config.contentInsets = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                let id = self.userId
                self.dismiss(animated: true) { Router.shared.openDirect(userId: id) }
            })
            let w = UIView()
            button.translatesAutoresizingMaskIntoConstraints = false
            w.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: w.topAnchor, constant: 8), button.bottomAnchor.constraint(equalTo: w.bottomAnchor, constant: -16),
                button.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 20), button.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -20),
            ])
            stack.addArrangedSubview(w)
        }

        func field(_ title: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let t = UILabel(title, Typography.style(.body, 50, .semibold), color: theme.centerChannelColor.opacity(0.56))
            addPadded(t, top: 8, bottom: 2)
            let v = UILabel(value, Typography.style(.body, 200), color: theme.centerChannelColor, lines: 0)
            addPadded(v, top: 0, bottom: 8)
        }
        field("NICKNAME", user.nickname)
        field("POSITION", user.position)
        if let tz = user.timezone {
            let auto = tz["useAutomaticTimezone"]?.stringValue != "false"
            let id = (auto ? tz["automaticTimezone"] : tz["manualTimezone"])?.stringValue ?? ""
            if let zone = TimeZone(identifier: id) {
                let f = DateFormatter()
                f.timeZone = zone
                f.dateFormat = session.uses24HourClock ? "HH:mm zzz" : "h:mm a zzz"
                field("LOCAL TIME", f.string(from: Date()))
            }
        }
    }
}

final class PaddedTag: UILabel {
    init(_ text: String) {
        super.init(frame: .zero)
        let theme = Theme.current
        self.text = text
        font = UIFont(name: "OpenSans-SemiBold", size: 10)
        textColor = theme.centerChannelColor
        textAlignment = .center
        layer.backgroundColor = theme.centerChannelColor.opacity(0.08).cgColor
        layer.cornerRadius = 4
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 8, height: 16)
    }
}
