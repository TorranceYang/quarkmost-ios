import UIKit

/// Root layout for iPhone and iPhone Duo.
///
/// - Outer (compact) screen: one navigation stack, tabs → conversation → thread.
/// - Inner (regular) screen: the tabs (channel list, search…) beside the conversation.
///
/// There is deliberately **no** separate `.compact` column view controller. Folding/unfolding
/// collapses and expands the *same* view-controller instances, so scroll position, the unsent
/// draft and an open thread survive the transition.
final class RootSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    let homeTabs = HomeTabsViewController()
    private var channelList: ChannelListViewController { homeTabs.channelList }
    private let channelNav: UINavigationController
    private let detailNav: UINavigationController
    private var currentConversation: ConversationViewController?
    var onLogout: (() -> Void)?

    private var notificationBanner: InAppNotificationView?
    private var observers: [NSObjectProtocol] = []

    init() {
        channelNav = ThemedNavigationController(rootViewController: homeTabs)
        detailNav = ThemedNavigationController(rootViewController: EmptyDetailViewController())
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        preferredPrimaryColumnWidthFraction = 0.34
        minimumPrimaryColumnWidth = 280
        maximumPrimaryColumnWidth = 400
        setViewController(channelNav, for: .primary)
        setViewController(detailNav, for: .secondary)
        delegate = self
        Router.shared.root = self

        channelList.onSelectChannel = { [weak self] channel in
            self?.openConversation(channelId: channel.id, rootId: nil, focusComposer: false)
        }
        channelList.onThemeChange = { [weak self] in self?.applyTheme() }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        observers.append(NotificationCenter.default.addObserver(forName: .postReceived, object: nil, queue: .main) { [weak self] note in
            guard let post = note.userInfo?["post"] as? Post, let event = note.userInfo?["event"] as? WebSocketEvent else { return }
            MainActor.assumeIsolated { self?.showInAppNotification(post, event) }
        })
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        Theme.current.sidebarIsDark ? .lightContent : .darkContent
    }

    /// The official app's channel header: sidebar color, Metropolis 18 title, white controls.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        matchInterfaceStyle()
    }

    /// Light or dark to match the theme, for everything iOS draws itself: Liquid Glass (including
    /// bar buttons iOS moves into the Duo's status column, outside our views), alerts, the keyboard.
    private func matchInterfaceStyle() {
        view.window?.overrideUserInterfaceStyle = Glass.style
    }

    private func applyTheme() {
        let theme = Theme.current
        matchInterfaceStyle()
        view.backgroundColor = theme.sidebarBg
        channelNav.applyThemedBar()
        detailNav.applyThemedBar()
        channelNav.view.backgroundColor = theme.sidebarBg
        detailNav.view.backgroundColor = theme.centerChannelBg   // conversations use the chat colour up to the top edge
        (detailNav.viewControllers.first as? EmptyDetailViewController)?.applyTheme()
        if homeTabs.isViewLoaded { homeTabs.applyTheme() }
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Single entry point for opening a conversation — from the channel list, a notification tap
    /// or a permalink. Never focuses the composer unless explicitly asked (the notification-keyboard bug).
    func openConversation(channelId: String, rootId: String?, focusComposer: Bool) {
        let conversation: ConversationViewController
        if let current = currentConversation, current.channelId == channelId,
           detailNav.viewControllers.first === current {
            conversation = current
            if rootId == nil { detailNav.popToRootViewController(animated: false) }
        } else {
            let title = AppSession.shared.channel(channelId).map(AppSession.shared.title(for:))
            conversation = ConversationViewController(channelId: channelId, title: title)
            currentConversation = conversation
            detailNav.setViewControllers([conversation], animated: false)
        refreshDetailBackButton()
        }
        channelList.activeChannelId = channelId
        conversation.shouldFocusComposerOnAppear = focusComposer
        show(.secondary)
        refreshDetailBackButton()

        if let rootId {
            if let top = detailNav.topViewController as? ConversationViewController, top.rootId == rootId { return }
            conversation.openThread(rootId: rootId)
        }
    }

    /// Shows a non-channel screen (Threads, Drafts) in the detail area.
    func showDetail(_ vc: UIViewController) {
        currentConversation = nil
        detailNav.setViewControllers([vc], animated: false)
        show(.secondary)
        refreshDetailBackButton()
    }

    /// After leaving or archiving the channel that's open.
    func closeConversation(channelId: String) {
        guard currentConversation?.channelId == channelId else { return }
        currentConversation = nil
        channelList.activeChannelId = nil
        if isCollapsed { channelNav.popToRootViewController(animated: true) }
        detailNav.setViewControllers([EmptyDetailViewController()], animated: false)
    }

    // Connection state is shown as a spinner in the sidebar header (ChannelListHeaderView).

    // MARK: In-app notification (`screens/in_app_notification`)

    private func showInAppNotification(_ post: Post, _ event: WebSocketEvent) {
        let session = AppSession.shared
        guard UIApplication.shared.applicationState == .active, post.userId != session.me?.id,
              !post.isSystemMessage, session.viewingChannelId != post.channelId, !session.isMuted(post.channelId) else { return }
        // Same rule as push: DMs and mentions notify; other channel chatter doesn't.
        let channelType = event.data?["channel_type"]?.stringValue
        let mentions = event.data?["mentions"]?.stringValue ?? ""
        let mentioned = session.me.map { mentions.contains($0.id) } ?? false
        guard channelType == "D" || channelType == "G" || mentioned else { return }
        if post.isReply, !mentioned, !(event.data?["followers"]?.stringValue ?? "").contains(session.me?.id ?? "-") { return }

        notificationBanner?.removeFromSuperview()
        let sender = post.overrideUsername ?? event.data?["sender_name"]?.stringValue ?? "Someone"
        let channelName = event.data?["channel_display_name"]?.stringValue ?? ""
        let title = channelType == "D" ? sender : (channelName.isEmpty ? sender : channelName)
        let body = channelType == "D" ? post.message : "\(sender): \(post.message)"
        let banner = InAppNotificationView(title: title, message: body.isEmpty ? "Sent an attachment" : body, userId: post.userId) { [weak self] in
            if post.isReply { self?.openConversation(channelId: post.channelId, rootId: post.rootId, focusComposer: false) }
            else { Router.shared.openChannel(post.channelId) }
        }
        notificationBanner = banner
        banner.show(in: view)
    }

    // MARK: UISplitViewControllerDelegate

    /// Folding and unfolding changes whether the conversation needs a back button.
    func splitViewControllerDidCollapse(_ svc: UISplitViewController) { refreshDetailBackButton() }
    func splitViewControllerDidExpand(_ svc: UISplitViewController) { refreshDetailBackButton() }

    private func refreshDetailBackButton() {
        if let first = detailNav.viewControllers.first { (detailNav as? ThemedNavigationController)?.flatten(first) }
    }

    /// When folding to the outer screen, keep the open conversation on top instead of
    /// dropping back to the channel list.
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column)
        -> UISplitViewController.Column {
        detailNav.viewControllers.first is EmptyDetailViewController ? .primary : .secondary
    }
}

/// Shown in the right pane on the inner screen before any channel is chosen.
final class EmptyDetailViewController: UIViewController, HidesNavigationBar {
    override func viewDidLoad() {
        super.viewDidLoad()
        applyTheme()
    }

    /// Called again once the user's theme arrives from the server.
    func applyTheme() {
        view.backgroundColor = Theme.current.centerChannelBg
        var config = UIContentUnavailableConfiguration.empty()
        config.image = CompassIcon.image("message-text-outline", size: 48)
        config.imageProperties.tintColor = Theme.current.centerChannelColor.opacity(0.32)
        config.text = "No conversation selected"
        config.textProperties.font = Typography.style(.heading, 400).font
        config.textProperties.color = Theme.current.centerChannelColor
        contentUnavailableConfiguration = config
    }

}

/// Banner that drops from the top for a new DM or mention in another channel; tap opens it,
/// swipe up or wait 5s to dismiss.
final class InAppNotificationView: UIControl {
    private let onTap: () -> Void
    private var hideTask: Task<Void, Never>?

    init(title: String, message: String, userId: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        let theme = Theme.current
        backgroundColor = theme.centerChannelColor.blended(over: .black, opacity: 0.2)
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        let avatar = AvatarView(size: 32)
        avatar.setUser(userId, pictureUpdate: AppSession.shared.user(userId)?.lastPictureUpdate)
        let t = UILabel(title, Typography.style(.body, 200, .semibold), color: .white)
        let m = UILabel(message.replacingOccurrences(of: "\n", with: " "), Typography.style(.body, 100), color: UIColor.white.withAlphaComponent(0.8))
        let text = UIStackView(arrangedSubviews: [t, m])
        text.axis = .vertical
        text.isUserInteractionEnabled = false
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.spacing = 12
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        addAction(UIAction { [weak self] _ in self?.onTap(); self?.hide() }, for: .touchUpInside)
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
        swipe.direction = .up
        addGestureRecognizer(swipe)
        accessibilityLabel = "\(title): \(message)"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let width = widthAnchor.constraint(equalToConstant: 420)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
            centerXAnchor.constraint(equalTo: host.safeAreaLayoutGuide.centerXAnchor),
            leadingAnchor.constraint(greaterThanOrEqualTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            trailingAnchor.constraint(lessThanOrEqualTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            width,
        ])
        transform = CGAffineTransform(translationX: 0, y: -160)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { self.transform = .identity }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    @objc private func swiped() { hide() }

    private func hide() {
        hideTask?.cancel()
        UIView.animate(withDuration: 0.25) { self.transform = CGAffineTransform(translationX: 0, y: -160) } completion: { _ in
            self.removeFromSuperview()
        }
    }
}
