import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// One channel's (or one thread's) messages plus composer, matching the official channel screen.
///
/// - The list is **inverted** (flipped): the newest message is item 0 at the visual bottom. Opening a
///   channel needs no scroll-to-bottom, and older history appends at the far end, so nothing jumps.
/// - Every row's text and height is computed off the main thread before it's applied.
/// - Keyboard: the composer is pinned to `view.keyboardLayoutGuide`, so iOS moves the layout in the
///   same animation as the keyboard. The composer only takes focus in `viewDidAppear`, and only when
///   explicitly asked (the notification-keyboard bug).
final class ConversationViewController: UIViewController, HidesNavigationBar {
    let channelId: String
    /// Set when this screen is a thread: shows the root and its replies, and replies go to the thread.
    let rootId: String?
    var shouldFocusComposerOnAppear = false

    private enum Item: Hashable {
        case post(String)
        case date(String)       // "yyyy-MM-dd"
        case newMessages
        case intro
    }

    private let session = AppSession.shared
    private var collectionView: UICollectionView!
    private let listLayout = MessageListLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let composer = ComposerView()
    private let autocomplete = AutocompleteView()
    private let jumpButton = UIButton(type: .custom)
    private let header = GlassHeaderView()
    private let backButton = GlassCircleButton(icon: "arrow-back-ios")
    private let scrim = TopScrim()

    private var posts: [String: Post] = [:]
    private var order: [String] = []            // newest first
    private var layouts: [String: PostLayout] = [:]
    private var failedIds: Set<String> = []
    private var expandedIds: Set<String> = []
    /// Thread roots that aren't in the loaded page, fetched so inline replies can say whose message they answer.
    private var roots: [String: Post] = [:]
    private var fetchingRoots: Set<String> = []
    private var crt: Bool { session.collapsedThreads }
    private var dateLabels: [String: String] = [:]
    private var layoutWidth: CGFloat = 0
    /// A rebuild was skipped while off screen; run it on the next layout pass.
    private var needsRebuild = false
    private var page = 0
    private var reachedOldest = false
    private var loadingOlder = false
    private var lastViewedAt: Int64 = 0         // for the "New Messages" line
    private var rebuildGeneration = 0
    private var observerToken: UUID?
    private var emojiObserver: NSObjectProtocol?
    private var lastTypingSent = Date.distantPast
    private var tokenTask: Task<Void, Never>?
    private var memberCount: Int?
    // Duo inner screen: a thread opens beside the channel instead of covering it.
    private let contentGuide = UILayoutGuide()
    private var contentTrailing: NSLayoutConstraint!
    private var threadPane: UINavigationController?
    private let paneDivider = UIView()
    private static let paneThreshold: CGFloat = 760   // below this a thread pane is too cramped; push instead

    init(channelId: String, title: String?, rootId: String? = nil) {
        self.channelId = channelId
        self.rootId = rootId
        super.init(nibName: nil, bundle: nil)
        self.title = rootId == nil ? (title ?? "Conversation") : "Thread"
        lastViewedAt = rootId == nil ? (AppSession.shared.member(channelId)?.lastViewedAt ?? 0) : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let token = observerToken, emoji = emojiObserver
        MainActor.assumeIsolated {
            if let token { AppSession.shared.stopObservingPosts(token) }
            if let emoji { NotificationCenter.default.removeObserver(emoji) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        // Run under the (hidden) navigation bar from the first layout. Laid out below the opaque
        // bar instead, the screen slid up when the bar hid, and the glass header jumped with it.
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg

        listLayout.leadingPadding = 12   // breathing room between the newest message and the composer
        listLayout.heightForItem = { [weak self] indexPath in self?.height(at: indexPath) ?? 0 }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        collectionView.backgroundColor = theme.centerChannelBg
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        [collectionView, composer, autocomplete, jumpButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        jumpButton.setImage(CompassIcon.image("arrow-down", size: 24), for: .normal)
        jumpButton.tintColor = theme.buttonColor
        jumpButton.backgroundColor = theme.buttonBg
        jumpButton.layer.cornerRadius = 20
        jumpButton.layer.shadowColor = UIColor.black.cgColor
        jumpButton.layer.shadowOpacity = 0.2
        jumpButton.layer.shadowRadius = 6
        jumpButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        jumpButton.alpha = 0
        jumpButton.accessibilityLabel = "Jump to recent messages"
        jumpButton.addAction(UIAction { [weak self] _ in
            self?.collectionView.setContentOffset(.zero, animated: true)
        }, for: .primaryActionTriggered)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        view.addLayoutGuide(contentGuide)
        contentTrailing = contentGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        let collectionTrailing = collectionView.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor)
        collectionTrailing.priority = .defaultHigh
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),   // scrolls under the floating header
            // Safe area matters on the Duo's outer screen, where the status bar runs down the right edge.
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionTrailing,
            collectionView.bottomAnchor.constraint(equalTo: composer.topAnchor),
            contentGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentGuide.topAnchor.constraint(equalTo: view.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentTrailing,
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            autocomplete.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            autocomplete.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor, constant: -8),
            autocomplete.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -4),
            jumpButton.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor, constant: -16),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -16),
            jumpButton.widthAnchor.constraint(equalToConstant: 40),
            jumpButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        let postCell = UICollectionView.CellRegistration<PostCell, String> { [weak self] cell, _, id in
            guard let self, let layout = layouts[id] else { return }
            cell.configure(layout, theme: Theme.current)
            cell.onTapTarget = { [weak self] key, value in PostActions.openTarget(key, value, channelId: self?.channelId) }
            cell.onToggleReaction = { [weak self] post, name in self?.toggleReaction(post, name) }
            cell.onShowReactions = { [weak self] post, emoji in
                guard let self else { return }
                present(ReactionsViewController(post: posts[post.id] ?? post, initialEmoji: emoji), animated: true)
            }
            cell.onAddReaction = { [weak self] post in self?.pickReaction(for: post) }
            cell.onLongPress = { [weak self] post in self?.showOptions(for: post) }
            cell.onOpenImage = { [weak self] _, index in
                guard let self else { return }
                PostActions.openMedia(layout, index: index, from: self)
            }
            cell.onTapFile = { [weak self] _, file in if let self { FilePreviewer.open(file, from: self) } }
            cell.onOpenThread = { [weak self] post in self?.openThreadScreen(post) }
            cell.onTapAvatar = { [weak self] post in
                guard !post.fromWebhook else { return }
                Router.shared.showProfile(userId: post.userId, channelId: self?.channelId)
            }
            cell.onTapFailed = { [weak self] post in self?.showFailedOptions(post) }
            cell.onToggleExpand = { [weak self] post in
                guard let self else { return }
                if !expandedIds.insert(post.id).inserted { expandedIds.remove(post.id) }
                layouts[post.id] = nil
                rebuild(animated: false)
            }
            // Tapping a message opens its thread to reply, as in the official app. With the keyboard
            // up, the first tap just dismisses it.
            cell.onTap = { [weak self] post in
                guard let self else { return }
                if composer.isFocused_ { view.endEditing(true); return }
                guard rootId == nil, !post.isSystemMessage, post.pendingPostId != post.id else { return }
                openThreadScreen(post)
            }
            cell.onSwipeReply = rootId != nil ? nil : { [weak self] post in
                self?.view.endEditing(true)
                self?.openThread(rootId: post.rootId.isEmpty ? post.id : post.rootId, focusComposer: true)
            }
        }
        let dateCell = UICollectionView.CellRegistration<DateSeparatorCell, String> { [weak self] cell, _, key in
            cell.configure(self?.dateLabels[key] ?? key, theme: Theme.current)
        }
        let newCell = UICollectionView.CellRegistration<DateSeparatorCell, Int> { cell, _, _ in
            cell.configure("New Messages", theme: Theme.current, color: Theme.current.newMessageSeparator)
        }
        let introCell = UICollectionView.CellRegistration<ChannelIntroCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(channelId: channelId)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .post(let id): cv.dequeueConfiguredReusableCell(using: postCell, for: indexPath, item: id)
            case .date(let key): cv.dequeueConfiguredReusableCell(using: dateCell, for: indexPath, item: key)
            case .newMessages: cv.dequeueConfiguredReusableCell(using: newCell, for: indexPath, item: 0)
            case .intro: cv.dequeueConfiguredReusableCell(using: introCell, for: indexPath, item: 0)
            }
        }

        setUpComposer()
        setUpHeader()

        observerToken = session.observePosts(channelId: channelId) { [weak self] event in self?.handle(event) }
        // Custom emoji images arrive after login; re-render so `:name:` becomes the image.
        emojiObserver = NotificationCenter.default.addObserver(forName: CustomEmojiStore.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layouts = [:]
                self?.rebuild(animated: false)
            }
        }
        loadNewest()
    }

    // MARK: Header
    //
    // A floating glass pill with the channel's name (tap for the channel menu) and a round glass
    // Back button, with messages scrolling underneath. The system navigation bar is hidden here.
    // On the iPhone Duo, Back sits in the side column under the status icons, as our own view, so
    // it can't overflow into a "⋯" menu.

    private func setUpHeader() {
        let theme = Theme.current
        scrim.setColor(theme.centerChannelBg)
        scrim.isUserInteractionEnabled = false
        header.onTap = { [weak self] in self?.headerTapped() }
        header.onBack = { [weak self] in self?.goBack() }
        backButton.setTint(theme.centerChannelColor)
        backButton.accessibilityLabel = "Back"
        backButton.addAction(UIAction { [weak self] _ in self?.goBack() }, for: .touchUpInside)
        [scrim, header, backButton].forEach(view.addSubview)
        if rootId == nil {
            Task {
                memberCount = (try? await session.client.channelStats(id: channelId))?.memberCount
                refreshHeader()
            }
        } else {
            refreshFollowButton()
        }
        refreshHeader()
    }

    /// Set when shown as the thread pane beside a channel: Back closes the pane.
    var onClose: (() -> Void)?

    private func goBack() {
        if let onClose { onClose(); return }
        guard let nav = navigationController else { return }
        if nav.viewControllers.count > 1 { nav.popViewController(animated: true) }
        else { splitViewController?.show(.primary) }
    }

    private var showsBack: Bool {
        if onClose != nil { return true }
        guard let nav = navigationController else { return false }
        return nav.viewControllers.first !== self || splitViewController?.isCollapsed == true
    }

    /// Lays out the pill, Back and the scrim, and keeps the newest messages clear of them.
    private func layoutHeader() {
        guard view.window != nil else { return }
        let window = view.window?.safeAreaInsets ?? .zero
        // The navigation container's top inset, not ours: ours still counts the navigation bar on
        // the first layout pass, before it hides, which made the pill start low and then jump up.
        let safeTop = navigationController?.view.safeAreaInsets.top ?? view.safeAreaInsets.top
        let area = collectionView.frame          // the chat column (excludes a thread pane)
        let top = max(safeTop, 8) + (safeTop > 0 ? 2 : 0)
        // On the Duo, Back goes in the status-bar column; elsewhere it's the pill's leading slot.
        let backInColumn = showsBack && window.right >= 70
        header.showsBack = showsBack && !backInColumn
        backButton.isHidden = !backInColumn
        if backInColumn {
            // The status icons are centred 48pt in from the edge on both Duo screens (not in the
            // middle of the safe-area column). On the outer screen they sit lower, under the camera.
            let size = GlassCircleButton.size
            let y: CGFloat = view.bounds.width < 600 ? 170 : 116
            backButton.frame = CGRect(x: (view.bounds.width - 48 - size / 2).rounded(), y: y, width: size, height: size)
        }
        // On the messages' grid: the pill's leading slot over the avatars, its title over the names.
        let inset = PostLayout.side - GlassHeaderView.padding
        header.frame = CGRect(x: area.minX + inset, y: top, width: area.width - 2 * inset, height: GlassHeaderView.height)
        scrim.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: header.frame.maxY + 12)
        scrim.setSolidHeight(max(safeTop, header.frame.midY))   // no text fighting the title
        // The list is flipped, so its visual top is the bottom inset.
        let clearance = header.frame.maxY + 6 - area.minY
        if collectionView.contentInset.bottom != clearance {
            collectionView.contentInset.bottom = clearance
            collectionView.verticalScrollIndicatorInsets.bottom = clearance
        }
    }

    private func refreshHeader() {
        let theme = Theme.current
        let channel = session.channel(channelId)
        let name = channel.map(session.title(for:)) ?? title ?? ""
        let hint = rootId == nil ? "Opens channel options" : "Opens the channel"
        if rootId != nil {
            header.configure(iconName: "message-text-outline", title: "Thread", subtitle: "in \(name)", hint: hint, theme: theme)
            return
        }
        var subtitle: String?
        var iconName: String? = "globe"
        if let channel, channel.type == .direct, let other = session.teammateId(of: channel) {
            let user = session.user(other)
            iconName = nil
            header.avatar.setUser(other, pictureUpdate: user?.lastPictureUpdate)
            if !(user?.isBot ?? false) { header.avatar.setStatus(session.status(other), background: theme.centerChannelBg) }
            if let custom = user?.customStatus {
                subtitle = "\(EmojiStore.shared.unicode(for: custom.emoji) ?? "") \(custom.text)".trimmingCharacters(in: .whitespaces)
            } else if user?.isBot ?? false {
                subtitle = "Bot"
            }
        } else {
            switch channel?.type {
            case .privateChannel: iconName = "lock-outline"
            case .group: iconName = "account-multiple-outline"
            default: iconName = "globe"
            }
            subtitle = memberCountText
        }
        if session.isMuted(channelId) { subtitle = (subtitle.map { $0 + " · " } ?? "") + "Muted" }
        header.configure(iconName: iconName, title: name, subtitle: subtitle, hint: hint, theme: theme)
    }

    private var memberCountText: String? {
        memberCount.map { "\($0) \($0 == 1 ? "member" : "members")" }
    }

    /// Actions with a short title become the quick buttons along the top; the rest are rows.
    private func showChannelMenu() {
        guard let channel = session.channel(channelId) else { return }
        let all = ChannelActions.options(for: channel, from: self)
        var buttons = all.compactMap { option in
            option.shortTitle.map { PostOptionsViewController.Option(icon: option.icon, title: $0, action: option.action) }
        }
        buttons.append(.init(icon: "magnify", title: "Search") { [weak self] in self?.searchInChannel() })
        let menu = ChannelMenuViewController(title: session.title(for: channel), subtitle: memberCountText,
                                             buttons: buttons, rows: all.filter { $0.shortTitle == nil },
                                             anchor: header.convert(header.bounds, to: nil))
        present(menu, animated: true)
    }

    private func searchInChannel() {
        guard let channel = session.channel(channelId) else { return }
        let term = channel.type == .direct ? "from:\(session.teammateId(of: channel).flatMap { self.session.user($0)?.username } ?? "") "
            : "in:\(channel.name) "
        Router.shared.search(term)
    }

    private func headerTapped() {
        if rootId != nil { Router.shared.openChannel(channelId); return }
        showChannelMenu()
    }

    private func refreshFollowButton() {
        // Following only exists with Collapsed Reply Threads (official thread header hides it otherwise).
        guard crt, let rootId, let root = posts[rootId] else { return }
        let following = root.isFollowing ?? false
        var config = UIButton.Configuration.filled()
        var title = AttributedString(following ? "Following" : "Follow")
        title.font = Typography.style(.heading, 75).font
        config.attributedTitle = title
        config.baseBackgroundColor = Theme.current.centerChannelColor.opacity(following ? 0.16 : 0.08)
        config.baseForegroundColor = Theme.current.centerChannelColor
        config.contentInsets = .init(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.background.cornerRadius = 4
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            guard let self, let root = posts[rootId] else { return }
            setFollowing(!(root.isFollowing ?? false), root)
        })
        header.setAccessory(button)
    }

    // MARK: Composer

    private func setUpComposer() {
        let name = session.channel(channelId).map(session.title(for:)) ?? title ?? ""
        composer.placeholder = rootId == nil ? "Write to \(name)" : "Reply to this thread..."
        composer.text = session.draft(channelId: channelId, rootId: rootId)
        composer.onTextChange = { [weak self] text in
            guard let self else { return }
            session.setDraft(text, channelId: channelId, rootId: rootId)
            if !text.isEmpty, Date().timeIntervalSince(lastTypingSent) > 4 {
                lastTypingSent = Date()
                session.sendTyping(channelId: channelId, rootId: rootId)
            }
        }
        composer.onSend = { [weak self] text, files in self?.send(text, files: files) }
        composer.onToken = { [weak self] token in self?.updateAutocomplete(token) }
        composer.onAttach = { [weak self] in self?.showAttachmentOptions() }
        composer.onEmoji = { [weak self] in
            let picker = EmojiPickerViewController()
            picker.onPick = { name in self?.composer.insert(":\(name):") }
            self?.present(picker, animated: true)
        }
        composer.onPasteImage = { [weak self] image in self?.attach(image: image) }
        autocomplete.onPick = { [weak self] row in
            guard let completion = row.completion else { return }
            self?.composer.completeToken(with: completion)
            self?.autocomplete.show([])
        }
        if let channel = session.channel(channelId), channel.deleteAt > 0 {
            composer.isUserInteractionEnabled = false
            composer.alpha = 0.5
            composer.placeholder = "You are viewing an archived channel. New messages cannot be posted."
        }
    }

    /// Suggestions for the word being typed (`components/autocomplete`).
    private func updateAutocomplete(_ token: ComposerToken?) {
        tokenTask?.cancel()
        guard let token else { autocomplete.show([]); return }
        tokenTask = Task { [weak self] in
            guard let self else { return }
            var rows: [SearchListViewController.Row] = []
            switch token {
            case .mention(let term):
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let team = session.team else { return }
                let result = try? await session.client.autocompleteUsers(term: term, teamId: team.id, channelId: channelId)
                let inChannel = result?.users ?? [], out = result?.outOfChannel ?? []
                session.cache(inChannel + out)
                func row(_ u: User, _ section: String) -> SearchListViewController.Row {
                    .init(id: u.id, title: "@\(u.username)", subtitle: u.fullName.isEmpty ? nil : u.fullName, userId: u.id,
                          pictureUpdate: u.lastPictureUpdate, detail: (u.isBot ?? false) ? "BOT" : nil, section: section,
                          completion: "@\(u.username)")
                }
                rows = inChannel.map { row($0, "Channel Members") }
                for (key, desc) in [("here", "Notifies everyone online in this channel"), ("channel", "Notifies everyone in this channel"),
                                    ("all", "Notifies everyone in this channel")] where key.hasPrefix(term.lowercased()) {
                    rows.append(.init(id: "special-\(key)", title: "@\(key)", subtitle: desc, icon: "account-multiple-outline", completion: "@\(key)"))
                }
                rows += out.prefix(10).map { row($0, "Not in Channel") }
            case .channel(let term):
                let q = term.lowercased()
                let mine = session.allChannels.filter { $0.type == .open || $0.type == .privateChannel }
                    .filter { q.isEmpty || $0.name.contains(q) || $0.displayName.lowercased().contains(q) }
                var seen = Set(mine.map(\.id))
                var all = mine
                if !q.isEmpty, let team = session.team,
                   let more = try? await session.client.autocompleteChannels(term: term, teamId: team.id) {
                    all += more.filter { seen.insert($0.id).inserted }
                }
                rows = all.prefix(25).map {
                    .init(id: $0.id, title: $0.displayName, subtitle: "~\($0.name)",
                          icon: $0.type == .privateChannel ? "lock-outline" : "globe", completion: "~\($0.name)")
                }
            case .emoji(let term):
                var seen = Set<String>()
                let names = (CustomEmojiStore.shared.search(term) + EmojiStore.shared.search(term, limit: 30).map(\.name))
                    .filter { seen.insert($0).inserted }.prefix(30)
                rows = names.map { .init(id: $0, title: ":\($0):", emoji: $0, completion: ":\($0):") }
            case .slash(let term):
                let q = term.lowercased()
                let builtIn: [(String, String, String)] = [
                    ("away", "", "Set your status away"), ("online", "", "Set your status online"),
                    ("dnd", "", "Do not disturb disables mobile push notifications"), ("offline", "", "Set your status offline"),
                    ("me", "[message]", "Do an action"), ("shrug", "[message]", "Adds ¯\\_(ツ)_/¯ to your message"),
                    ("header", "[text]", "Edit the channel header"), ("purpose", "[text]", "Edit the channel purpose"),
                    ("join", "~[channel]", "Join the open channel"), ("leave", "", "Leave the current channel"),
                    ("mute", "", "Turns off notifications for the current channel"), ("search", "[text]", "Search text in messages"),
                    ("code", "[text]", "Display text as a code block"), ("echo", "\"message\" [delay in seconds]", "Echo back text from your account"),
                    ("invite", "@[username] ~[channel]", "Invite a user to a channel"), ("kick", "@[username]", "Remove a member from a channel"),
                    ("msg", "@[username] 'message'", "Send Direct Message to a user"), ("status", "[:emoji_name:] [status_message]", "Set or clear your status"),
                ]
                let server = await session.commands()
                var seen = Set<String>()
                rows = server.filter { ($0.autoComplete ?? true) && $0.trigger.hasPrefix(q) && seen.insert($0.trigger).inserted }.map {
                    .init(id: $0.trigger, title: "/\($0.trigger) \($0.autoCompleteHint ?? "")", subtitle: $0.autoCompleteDesc,
                          icon: "slash-forward-box-outline", completion: "/\($0.trigger)")
                }
                rows += builtIn.filter { $0.0.hasPrefix(q) && seen.insert($0.0).inserted }.map {
                    .init(id: $0.0, title: "/\($0.0) \($0.1)", subtitle: $0.2, icon: "slash-forward-box-outline", completion: "/\($0.0)")
                }
            }
            guard !Task.isCancelled else { return }
            autocomplete.show(rows)
        }
    }

    // MARK: Attachments (`screens/attachment_options`)

    private func showAttachmentOptions() {
        var options: [PostOptionsViewController.Option] = [
            .init(icon: "image-outline", title: "Choose from photo library") { [weak self] in
                var config = PHPickerConfiguration()
                config.selectionLimit = 10
                config.filter = .any(of: [.images, .videos])
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                self?.present(picker, animated: true)
            },
        ]
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            options.append(.init(icon: "camera-outline", title: "Take photo or video") { [weak self] in
                let picker = UIImagePickerController()
                picker.sourceType = .camera
                picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
                picker.delegate = self
                self?.present(picker, animated: true)
            })
        }
        options.append(.init(icon: "paperclip", title: "Attach a file") { [weak self] in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            self?.present(picker, animated: true)
        })
        presentOptions(options, title: "Files and media")
    }

    fileprivate func attach(image: UIImage, name: String? = nil) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let filename = name ?? "image-\(Int(Date().timeIntervalSince1970)).jpg"
        composer.addUpload(data: data, filename: filename, thumbnail: image.preparingThumbnail(of: CGSize(width: 192, height: 192)), channelId: channelId)
    }

    fileprivate func attach(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL) else { showToast("Couldn't read \(fileURL.lastPathComponent)"); return }
        let thumb = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 192, height: 192))
        composer.addUpload(data: data, filename: fileURL.lastPathComponent, thumbnail: thumb, channelId: channelId)
    }

    // MARK: Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if rootId == nil {
            session.viewingChannelId = channelId
            session.markRead(channelId: channelId)
        }
        if hidSidebarForThread, let split = splitViewController {
            let coordinator = animated && !split.isCollapsed ? transitionCoordinator : nil
            if let coordinator, coordinator.isInteractive {
                // Swiping back from the thread: bring the channel list back only once the swipe
                // completes. Restoring it mid-swipe left a half-open mix (and a thread with the
                // list beside it) when the swipe was let go early.
                coordinator.notifyWhenInteractionChanges { [weak self] context in
                    guard !context.isCancelled else { return }
                    self?.hidSidebarForThread = false
                    UIView.animate(withDuration: 0.25) { split.preferredDisplayMode = .oneBesideSecondary }
                }
            } else {
                hidSidebarForThread = false
                if let coordinator {
                    coordinator.animate(alongsideTransition: { _ in split.preferredDisplayMode = .oneBesideSecondary })
                } else {
                    split.preferredDisplayMode = .oneBesideSecondary
                }
            }
        }
        refreshHeader()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if shouldFocusComposerOnAppear {
            shouldFocusComposerOnAppear = false
            composer.focus()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if rootId == nil, session.viewingChannelId == channelId { session.viewingChannelId = nil }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
        // Folded to the outer screen with a thread pane open: turn the pane into a pushed screen.
        if let pane = threadPane, visibleWidth < Self.paneThreshold, let thread = pane.viewControllers.first {
            closeThreadPane()
            pane.setViewControllers([], animated: false)
            (thread as? ConversationViewController)?.onClose = nil
            navigationController?.pushViewController(thread, animated: false)
        }
        // Fold/unfold or rotation: re-lay out every row for the new width (off the main thread).
        if collectionView.bounds.width > 0, collectionView.bounds.width != layoutWidth || needsRebuild, !order.isEmpty {
            rebuild(animated: false)
        }
    }

    func openThread(rootId: String, focusComposer: Bool = false) {
        guard self.rootId == nil else { return }
        if let open = threadPane?.viewControllers.first as? ConversationViewController, open.rootId == rootId {
            if focusComposer { open.composer.focus() }
            return
        }
        let thread = ConversationViewController(channelId: channelId, title: title, rootId: rootId)
        thread.shouldFocusComposerOnAppear = focusComposer
        if visibleWidth >= Self.paneThreshold, splitViewController?.isCollapsed == false {
            showThreadPane(thread)
        } else if let split = splitViewController, !split.isCollapsed {
            // Unfolded Duo: give the thread the whole screen by sliding the channel list away;
            // it comes back when the thread is closed (see viewWillAppear).
            hidSidebarForThread = true
            UIView.animate(withDuration: 0.25) { split.preferredDisplayMode = .secondaryOnly }
            navigationController?.pushViewController(thread, animated: true)
        } else {
            navigationController?.pushViewController(thread, animated: true)
        }
    }

    /// Width actually on screen: the view runs under the channel list and the Duo's status column,
    /// which show up as side safe-area insets.
    private var visibleWidth: CGFloat { view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right }

    /// Set when opening a thread hid the channel list, so returning here brings it back.
    private var hidSidebarForThread = false

    /// Inner Duo screen: channel list | conversation | thread.
    private func showThreadPane(_ thread: ConversationViewController) {
        closeThreadPane()
        let theme = Theme.current
        thread.onClose = { [weak self] in self?.closeThreadPane(animated: true) }
        let nav = ThemedNavigationController(rootViewController: thread)
        addChild(nav)
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        paneDivider.backgroundColor = theme.centerChannelColor.opacity(0.16)
        paneDivider.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nav.view)
        view.addSubview(paneDivider)
        let width = max(300, (view.bounds.width * 0.45).rounded())
        NSLayoutConstraint.activate([
            nav.view.topAnchor.constraint(equalTo: view.topAnchor),
            nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nav.view.widthAnchor.constraint(equalToConstant: width),
            paneDivider.topAnchor.constraint(equalTo: view.topAnchor),
            paneDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            paneDivider.trailingAnchor.constraint(equalTo: nav.view.leadingAnchor),
            paneDivider.widthAnchor.constraint(equalToConstant: 1),
        ])
        nav.didMove(toParent: self)
        threadPane = nav
        contentTrailing.constant = -width - 1
        view.layoutIfNeeded()
    }

    private func closeThreadPane(animated: Bool = false) {
        guard let pane = threadPane else { return }
        threadPane = nil
        pane.willMove(toParent: nil)
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        paneDivider.removeFromSuperview()
        contentTrailing.constant = 0
        if animated { UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() } }
    }

    fileprivate func openThreadScreen(_ post: Post) {
        openThread(rootId: post.rootId.isEmpty ? post.id : post.rootId)
    }

    // MARK: Loading

    private func loadNewest() {
        Task {
            if let rootId {
                guard let list = try? await session.client.thread(postId: rootId) else { return }
                merge(list.orderedPosts)
                reachedOldest = true
                await session.loadUsers(list.orderedPosts.map(\.userId))
                rebuild(animated: false)
                refreshFollowButton()
                markThreadRead()
                return
            }
            // Cached page first: instant open, and readable offline.
            if order.isEmpty, let cached = DiskCache.load([Post].self, key: "posts-\(channelId)"), !cached.isEmpty {
                merge(cached)
                rebuild(animated: false)
            }
            guard let list = try? await session.client.posts(channelId: channelId, page: 0, collapsedThreads: crt) else {
                if order.isEmpty { showLoadError() }
                return
            }
            contentUnavailableConfiguration = nil
            // Posts deleted while we were away are in the cache but not in the fresh page.
            let fresh = Set(list.order)
            if let oldest = list.orderedPosts.map(\.createAt).min() {
                for (id, post) in posts where post.createAt >= oldest && !fresh.contains(id) && post.pendingPostId != id { posts[id] = nil }
            }
            DiskCache.save(list.orderedPosts, key: "posts-\(channelId)")
            merge(list.orderedPosts)
            reachedOldest = list.order.count < 60
            page = 0
            await session.loadUsers(list.orderedPosts.map(\.userId))
            rebuild(animated: false)
        }
    }

    private func showLoadError() {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = CompassIcon.image("alert-circle-outline", size: 48)
        config.imageProperties.tintColor = Theme.current.centerChannelColor.opacity(0.48)
        config.text = "Couldn't load messages"
        config.textProperties.color = Theme.current.centerChannelColor
        var retry = UIButton.Configuration.filled()
        retry.title = "Retry"
        retry.baseBackgroundColor = Theme.current.buttonBg
        config.button = retry
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.loadNewest() }
        contentUnavailableConfiguration = config
    }

    private func markThreadRead() {
        guard crt, let rootId, let me = session.me, let team = session.team else { return }
        Task {
            try? await session.client.markThreadRead(userId: me.id, teamId: team.id, threadId: rootId,
                                                     timestamp: Int64(Date().timeIntervalSince1970 * 1000))
            session.refreshThreadTotals()
        }
    }

    private func loadOlder() {
        guard rootId == nil, !loadingOlder, !reachedOldest, !order.isEmpty else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            guard let list = try? await session.client.posts(channelId: channelId, page: page + 1, collapsedThreads: crt) else { return }
            page += 1
            reachedOldest = list.order.count < 60
            merge(list.orderedPosts)
            await session.loadUsers(list.orderedPosts.map(\.userId))
            rebuild(animated: false)
        }
    }

    private func merge(_ new: [Post]) {
        for post in new {
            if post.deleteAt > 0 { posts[post.id] = nil; continue }
            // With collapsed threads, replies live in their thread, not the channel.
            if let rootId {
                if post.id != rootId && post.rootId != rootId { continue }
            } else if post.isReply && crt {
                continue   // collapsed threads: replies live only in their thread
            }
            posts[post.id] = post
        }
        order = posts.values.sorted { $0.createAt > $1.createAt }.map(\.id)
    }

    private func handle(_ event: AppSession.PostEvent) {
        switch event {
        case .posted(let post), .edited(let post):
            if rootId == nil, post.isReply {
                // A new reply bumps the root's reply count in the channel.
                if case .posted = event, var root = posts[post.rootId] {
                    root.replyCount = (root.replyCount ?? 0) + 1
                    if post.userId == session.me?.id { root.isFollowing = true }
                    posts[root.id] = root
                    layouts[root.id] = nil
                    if crt { rebuild(animated: false) }
                }
                if crt { return }   // otherwise the reply also appears inline below
            }
            if let rootId, post.id != rootId, post.rootId != rootId { return }
            // Replace our pending copy when the server echoes it back.
            if let pending = post.pendingPostId, pending != post.id { posts[pending] = nil; layouts[pending] = nil }
            // The echo carries no follow state; keep what we know.
            var post = post
            if post.isFollowing == nil { post.isFollowing = posts[post.id]?.isFollowing }
            if post.replyCount == nil || post.replyCount == 0 { post.replyCount = posts[post.id]?.replyCount ?? post.replyCount }
            layouts[post.id] = nil
            // The previous newest row may need its reply bar joined to this one.
            if case .posted = event, let newest = order.first { layouts[newest] = nil }
            merge([post])
            Task { await session.loadUsers([post.userId]); rebuild(animated: true) }
            if rootId != nil, view.window != nil { markThreadRead() }
        case .reactionAdded(let r), .reactionRemoved(let r):
            guard var post = posts[r.postId] else { return }
            var list = post.metadata?.reactions ?? []
            list.removeAll { $0.userId == r.userId && $0.emojiName == r.emojiName }
            if case .reactionAdded = event { list.append(r) }
            if post.metadata == nil { post.metadata = PostMetadata() }
            post.metadata?.reactions = list
            posts[post.id] = post
            layouts[post.id] = nil
            rebuild(animated: false)
        case .deleted(let post):
            posts[post.id] = nil
            order.removeAll { $0 == post.id }
            rebuild(animated: true)
        case .typing(let root):
            guard root == (rootId ?? "") else { return }
            composer.setTyping(session.typingNames(channelId: channelId, rootId: rootId))
        case .reconnected:
            loadNewest()
        }
    }

    // MARK: Building rows

    /// Computes missing (or width-stale) layouts in the background, then applies one snapshot.
    fileprivate func rebuild(animated: Bool) {
        let width = collectionView.bounds.width
        // Off screen (e.g. messages loaded before the view is in the window), the width is just the
        // default screen width; laying out at it made long messages run off screen on one line until
        // the next pass. Wait until we're on screen at the real width.
        guard width > 0, view.window != nil else { needsRebuild = true; return }
        needsRebuild = false
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let widthChanged = width != layoutWidth

        // Walk oldest → newest to decide grouping and separators.
        var inputs: [PostInput] = []
        var items: [Item] = []      // built oldest-first, reversed at the end
        var previous: Post?
        var newLineInserted = false
        let myId = session.me?.id
        let calendar = Calendar.current
        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"
        if reachedOldest, rootId == nil { items.append(.intro) }

        for id in order.reversed() {
            guard let post = posts[id] else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(post.createAt) / 1000)
            var consecutive = false
            var replyBar: PostInput.ReplyBar?
            var commentedOn: String?
            if let previous {
                let prevDate = Date(timeIntervalSince1970: TimeInterval(previous.createAt) / 1000)
                if !calendar.isDate(prevDate, inSameDayAs: date) {
                    let key = keyFormatter.string(from: date)
                    dateLabels[key] = Formatters.day(date)
                    items.append(.date(key))
                } else {
                    consecutive = previous.userId == post.userId && !post.isSystemMessage && !previous.isSystemMessage
                        && post.createAt - previous.createAt < 5 * 60 * 1000
                        && previous.overrideUsername == post.overrideUsername
                        && previous.fromWebhook == post.fromWebhook
                        && !(post.isPinned ?? false) && !session.savedPostIds.contains(post.id)
                        && !(session.user(post.userId)?.isBot ?? false)   // bots always show their header
                }
            } else {
                let key = keyFormatter.string(from: date)
                dateLabels[key] = Formatters.day(date)
                items.append(.date(key))
            }
            // Inline replies (collapsed threads off), following `post_list/post/index.ts`: a reply only
            // groups under the previous post when it continues the same thread; a root post that has
            // replies never groups; the first reply after something else says whose message it answers.
            if rootId == nil, !crt {
                let firstReply = post.isReply && (previous.map { post.rootId != $0.id && post.rootId != $0.rootId } ?? true)
                let hasReplies = post.isReply || (post.replyCount ?? 0) > 0
                let sameRoot = !firstReply && (post.isReply || (previous?.rootId.isEmpty ?? false))
                let sameSequence = hasReplies ? post.isReply : !post.isReply
                consecutive = consecutive && sameRoot && sameSequence
                if post.isReply {
                    let next = nextPost(after: id)
                    replyBar = .init(first: firstReply || !consecutive, last: next?.rootId != post.rootId,
                                     highlight: highlightsThread(post.rootId))
                    let differentSequence = previous.map { $0.rootId.isEmpty ? $0.id != post.rootId : $0.rootId != post.rootId } ?? true
                    if differentSequence, let root = posts[post.rootId] ?? roots[post.rootId] {
                        commentedOn = root.overrideUsername ?? session.displayName(session.user(root.userId))
                    } else if differentSequence {
                        fetchRoot(post.rootId)
                    }
                }
            }
            if !newLineInserted, lastViewedAt > 0, post.createAt > lastViewedAt, post.userId != myId,
               post.pendingPostId != post.id {
                items.append(.newMessages)
                newLineInserted = true
                consecutive = false
            }
            items.append(.post(id))
            let barChanged = (layouts[id]?.replyBarFrame != nil) != (replyBar != nil)
                || (layouts[id]?.commentedOn == nil) != (commentedOn == nil)
            if widthChanged || layouts[id] == nil || layouts[id]?.consecutive != consecutive || barChanged {
                var input = PostInput.make(post, consecutive: consecutive, failed: failedIds.contains(id))
                input.expanded = expandedIds.contains(id)
                input.collapsedThreads = crt
                input.replyBar = replyBar
                input.commentedOn = commentedOn
                inputs.append(input)
            }
            previous = post
        }
        items.reverse()

        let style = RenderStyle.current(myUsername: session.me?.username ?? "")
        Task.detached(priority: .userInitiated) { [inputs] in
            let built = inputs.map { PostLayoutBuilder.layout($0, width: width, style: style) }
            await MainActor.run { [weak self] in
                guard let self, generation == self.rebuildGeneration else { return }
                // The width changed while laying out: never show rows laid out for the old width.
                guard width == self.collectionView.bounds.width else { self.rebuild(animated: false); return }
                for layout in built { self.layouts[layout.id] = layout }
                self.layoutWidth = width
                self.apply(items, changed: Set(built.map(\.id)), animated: animated, widthChanged: widthChanged)
            }
        }
    }

    /// The next newer post in the list (`order` is newest first).
    private func nextPost(after id: String) -> Post? {
        guard let i = order.firstIndex(of: id), i > 0 else { return nil }
        return posts[order[i - 1]]
    }

    /// Reply bars turn the mention color for threads you started or replied in, per your
    /// "reply notifications" setting, as in the official app.
    private func highlightsThread(_ rootId: String) -> Bool {
        guard let me = session.me else { return false }
        let level = me.notifyProps?["comments"]?.stringValue ?? "never"
        let root = posts[rootId] ?? roots[rootId]
        if level == "never" { return false }
        if root?.userId == me.id { return true }
        return level == "any" && posts.values.contains { $0.rootId == rootId && $0.userId == me.id }
    }

    private func fetchRoot(_ id: String) {
        guard !fetchingRoots.contains(id) else { return }
        fetchingRoots.insert(id)
        Task {
            guard let root = try? await session.client.post(id: id) else { return }
            roots[id] = root
            await session.loadUsers([root.userId])
            for (pid, post) in posts where post.rootId == id { layouts[pid] = nil }
            rebuild(animated: false)
        }
    }

    private func apply(_ items: [Item], changed: Set<String>, animated: Bool, widthChanged: Bool) {
        let before = dataSource.snapshot().itemIdentifiers
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        snapshot.reconfigureItems(items.filter {
            if case .post(let id) = $0 { return changed.contains(id) && before.contains($0) }
            return false
        })

        // Reading older messages: keep them still when something new arrives at the bottom.
        let offsetBefore = collectionView.contentOffset.y
        let heightBefore = collectionView.contentSize.height
        let keepPosition = offsetBefore > 40 && !before.isEmpty && before.first != items.first

        if widthChanged { listLayout.invalidateLayout() }
        dataSource.apply(snapshot, animatingDifferences: animated && !keepPosition && view.window != nil) { [weak self] in
            guard let self, keepPosition else { return }
            self.collectionView.layoutIfNeeded()
            let added = self.collectionView.contentSize.height - heightBefore
            self.collectionView.contentOffset.y = offsetBefore + max(0, added)
        }
    }

    private func height(at indexPath: IndexPath) -> CGFloat {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return 0 }
        switch item {
        case .post(let id): return layouts[id]?.height ?? 44
        case .date: return DateSeparatorCell.height
        case .newMessages: return 28
        case .intro: return ChannelIntroCell.height
        }
    }

    // MARK: Sending

    private func send(_ text: String, files: [FileInfo]) {
        guard let me = session.me else { return }
        autocomplete.show([])
        if text.hasPrefix("/"), files.isEmpty, !text.hasPrefix("//") { runCommand(text); return }
        let pendingId = "\(me.id):\(Int64(Date().timeIntervalSince1970 * 1000))"
        var pending = Post.pending(id: pendingId, channelId: channelId, userId: me.id, message: text, rootId: rootId)
        if !files.isEmpty {
            pending.metadata = PostMetadata()
            pending.metadata?.files = files
        }
        posts[pendingId] = pending
        order.insert(pendingId, at: 0)
        lastViewedAt = 0     // you've seen everything once you reply
        collectionView.setContentOffset(.zero, animated: true)
        rebuild(animated: true)
        deliver(pending, fileIds: files.map(\.id))
    }

    private func deliver(_ pending: Post, fileIds: [String]) {
        let pendingId = pending.id
        Task {
            do {
                let sent = try await session.client.createPost(channelId: channelId, message: pending.message, rootId: rootId,
                                                               fileIds: fileIds, pendingPostId: pendingId)
                if posts[pendingId] != nil {
                    posts[pendingId] = nil
                    layouts[pendingId] = nil
                    merge([sent])
                    rebuild(animated: false)
                }
            } catch {
                // Keep it in the list, marked failed; tapping it offers Retry or Delete (`post/body/failed`).
                failedIds.insert(pendingId)
                layouts[pendingId] = nil
                rebuild(animated: false)
            }
        }
    }

    private func showFailedOptions(_ post: Post) {
        presentOptions([
            .init(icon: "refresh", title: "Retry") { [weak self] in
                guard let self else { return }
                failedIds.remove(post.id)
                layouts[post.id] = nil
                rebuild(animated: false)
                deliver(post, fileIds: post.metadata?.files?.map(\.id) ?? [])
            },
            .init(icon: "close-circle", title: "Delete", destructive: true) { [weak self] in
                guard let self else { return }
                failedIds.remove(post.id)
                posts[post.id] = nil
                order.removeAll { $0 == post.id }
                rebuild(animated: true)
            },
        ], title: "Message failed to send")
    }

    /// Slash commands run on the server; a few have local effects (`/search`, `/leave`).
    private func runCommand(_ text: String) {
        guard let team = session.team else { return }
        let lower = text.lowercased()
        if lower.hasPrefix("/search ") { Router.shared.search(String(text.dropFirst(8))); return }
        Task {
            do {
                let response = try await session.client.executeCommand(text, channelId: channelId, teamId: team.id, rootId: rootId)
                if let goto = response.gotoLocation, !goto.isEmpty, let url = URL(string: goto, relativeTo: ServerConfig.baseURL)?.absoluteURL {
                    Router.shared.open(url: url)
                }
                if let message = response.text, !message.isEmpty, response.responseType != "in_channel" { showToast(message) }
                if lower.hasPrefix("/leave") { Router.shared.root?.closeConversation(channelId: channelId) }
                try? await session.refreshSidebar()
                refreshHeader()
            } catch {
                composer.text = text
                showError(error)
            }
        }
    }
}

extension ConversationViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Inverted: older history is at the far end of the content.
        let remaining = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)
        if remaining < 1200 { loadOlder() }
        let showJump = scrollView.contentOffset.y > scrollView.bounds.height * 0.8
        if showJump != (jumpButton.alpha > 0.5) {
            UIView.animate(withDuration: 0.2) { self.jumpButton.alpha = showJump ? 1 : 0 }
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }
}

extension ConversationViewController: PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
                                      UINavigationControllerDelegate, UIDocumentPickerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            let suggested = provider.suggestedName
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] url, _ in
                    guard let url else { return }
                    // The file is deleted when this block returns, so copy it first.
                    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: copy)
                    try? FileManager.default.copyItem(at: url, to: copy)
                    Task { @MainActor in self?.attach(fileURL: copy) }
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    guard let image = object as? UIImage else { return }
                    Task { @MainActor in self?.attach(image: image, name: suggested.map { "\($0).jpg" }) }
                }
            }
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        if let url = info[.mediaURL] as? URL { attach(fileURL: url) }
        else if let image = info[.originalImage] as? UIImage { attach(image: image) }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        urls.forEach(attach(fileURL:))
    }
}

/// The beginning of a channel's history (`channel_post_list/intro`).
final class ChannelIntroCell: UICollectionViewCell {
    static let height: CGFloat = 148
    private let avatar = AvatarView(size: 48)
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        textLabel.numberOfLines = 3
        avatar.translatesAutoresizingMaskIntoConstraints = true
        [avatar, icon, titleLabel, textLabel].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(channelId: String) {
        let session = AppSession.shared
        let theme = Theme.current
        guard let channel = session.channel(channelId) else { return }
        let name = session.title(for: channel)
        let text: String
        avatar.isHidden = true
        icon.isHidden = false
        switch channel.type {
        case .direct:
            if let other = session.teammateId(of: channel) {
                avatar.isHidden = false
                icon.isHidden = true
                avatar.setUser(other, pictureUpdate: session.user(other)?.lastPictureUpdate)
            }
            text = "This is the start of your conversation with \(name). Messages and files shared here are not shown to anyone else."
        case .group:
            icon.image = CompassIcon.image("account-multiple-outline", size: 48)
            text = "This is the start of your conversation with this group. Messages and files shared here are not shown to anyone else outside of the group."
        case .privateChannel:
            icon.image = CompassIcon.image("lock-outline", size: 48)
            text = "This is the start of \(name). Only invited members can see messages posted in this private channel."
        case .open:
            icon.image = CompassIcon.image("globe", size: 48)
            text = channel.name == "town-square"
                ? "Welcome to \(name). Post messages here that you want everyone to see. Everyone automatically becomes a member of this channel when they join the team."
                : "This is the start of \(name). Any team member can join and read this channel."
        }
        icon.tintColor = theme.centerChannelColor.opacity(0.48)
        titleLabel.set(name, Typography.style(.heading, 600), color: theme.centerChannelColor)
        var attrs = Typography.style(.body, 100).attributes(color: theme.centerChannelColor.opacity(0.72))
        if let p = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            p.lineBreakMode = .byWordWrapping
            attrs[.paragraphStyle] = p
        }
        textLabel.attributedText = NSAttributedString(string: text, attributes: attrs)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width - 32
        avatar.frame = CGRect(x: 16, y: 16, width: 48, height: 48)
        icon.frame = avatar.frame
        titleLabel.frame = CGRect(x: 16, y: 72, width: w, height: 30)
        textLabel.frame = CGRect(x: 16, y: 102, width: w, height: 40)
    }
}

/// Who reacted (`screens/reactions`): a bar of the post's reactions with counts, the selected emoji's
/// names, then the people who used it with their profile pictures.
final class ReactionsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let post: Post
    private var order: [String] = []
    private var byEmoji: [String: [Reaction]] = [:]
    private var selected = 0
    private let bar = UIScrollView()
    private let barStack = UIStackView()
    private let aliasLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private var chips: [ReactionTab] = []

    init(post: Post, initialEmoji: String?) {
        self.post = post
        super.init(nibName: nil, bundle: nil)
        BottomSheet.install(on: self, detents: [.medium, .large])
        for r in (post.metadata?.reactions ?? []).sorted(by: { ($0.createAt ?? 0) < ($1.createAt ?? 0) }) {
            if byEmoji[r.emojiName] == nil { order.append(r.emojiName) }
            byEmoji[r.emojiName, default: []].append(r)
        }
        // Official order: most used first.
        order.sort { (byEmoji[$0]?.count ?? 0) > (byEmoji[$1]?.count ?? 0) }
        selected = initialEmoji.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg
        bottomSheet?.scrollView = table
        bar.showsHorizontalScrollIndicator = false
        barStack.axis = .horizontal
        barStack.spacing = 12
        barStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barStack)
        for (i, name) in order.enumerated() {
            let chip = ReactionTab(name: name, count: byEmoji[name]?.count ?? 0)
            chip.addAction(UIAction { [weak self] _ in self?.select(i) }, for: .touchUpInside)
            barStack.addArrangedSubview(chip)
            chips.append(chip)
        }
        aliasLabel.numberOfLines = 0
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.register(ReactorCell.self, forCellReuseIdentifier: "reactor")
        [bar, aliasLabel, table].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            bar.heightAnchor.constraint(equalToConstant: 44),
            barStack.topAnchor.constraint(equalTo: bar.contentLayoutGuide.topAnchor, constant: 6),
            barStack.leadingAnchor.constraint(equalTo: bar.contentLayoutGuide.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: bar.contentLayoutGuide.trailingAnchor),
            barStack.heightAnchor.constraint(equalToConstant: 32),
            aliasLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            aliasLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            aliasLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            table.topAnchor.constraint(equalTo: aliasLabel.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        select(selected)
        Task {
            await AppSession.shared.loadUsers(post.metadata?.reactions?.map(\.userId) ?? [])
            table.reloadData()
        }
    }

    private func select(_ i: Int) {
        guard order.indices.contains(i) else { return }
        selected = i
        for (j, chip) in chips.enumerated() { chip.setSelected(j == i) }
        let name = order[i]
        let names = EmojiStore.shared.emoji.first { $0.names.contains(name) }?.names ?? [name]
        aliasLabel.attributedText = NSAttributedString(
            string: names.map { ":\($0):" }.joined(separator: "  "),
            attributes: Typography.style(.body, 75, .semibold).attributes(color: Theme.current.centerChannelColor))
        table.reloadData()
    }

    private var current: [Reaction] { order.indices.contains(selected) ? byEmoji[order[selected]] ?? [] : [] }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { current.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reactor", for: indexPath) as! ReactorCell
        cell.configure(userId: current[indexPath.row].userId)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let userId = current[indexPath.row].userId
        dismiss(animated: true) { Router.shared.showProfile(userId: userId) }
    }
}

/// One tab in the reactions bar: emoji (standard or custom image) and count; selected gets a tint.
final class ReactionTab: UIControl {
    private let emoji = UILabel()
    private let image = UIImageView()
    private let count = UILabel()
    private let countText: String

    init(name: String, count: Int) {
        countText = "\(count)"
        super.init(frame: .zero)
        layer.cornerRadius = 4
        if let unicode = EmojiStore.shared.unicode(for: name) {
            emoji.text = unicode
            emoji.font = .systemFont(ofSize: 20)
        } else {
            image.image = CustomEmojiStore.shared.image(name)
            image.contentMode = .scaleAspectFit
        }
        [emoji, image, self.count].forEach { $0.isUserInteractionEnabled = false; $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        let glyph: UIView = emoji.text != nil ? emoji : image
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 50),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
            self.count.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5),
            self.count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            self.count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(name.replacingOccurrences(of: "_", with: " ")), \(count)"
        accessibilityTraits = .button
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ on: Bool) {
        let theme = Theme.current
        backgroundColor = on ? theme.buttonBg.opacity(0.08) : theme.centerChannelBg
        count.attributedText = NSAttributedString(string: countText, attributes:
            Typography.style(.body, 100, .semibold).attributes(color: on ? theme.buttonBg : theme.centerChannelColor.opacity(0.56)))
        accessibilityTraits = on ? [.button, .selected] : .button
    }
}

/// A person in the reactions list: avatar, full name, @username (`components/user_item`).
final class ReactorCell: UITableViewCell {
    private let avatar = AvatarView(size: 24)
    private let name = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let bg = UIView()
        bg.backgroundColor = Theme.current.centerChannelColor.opacity(0.08)
        selectedBackgroundView = bg
        name.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(avatar)
        contentView.addSubview(name)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            avatar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            name.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            name.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(userId: String) {
        let theme = Theme.current
        let session = AppSession.shared
        let user = session.user(userId)
        avatar.setUser(userId, pictureUpdate: user?.lastPictureUpdate)
        let text = NSMutableAttributedString()
        let full = user?.fullName ?? ""
        let me = userId == session.me?.id ? " (you)" : ""
        if !full.isEmpty {
            text.append(NSAttributedString(string: full + me + "  ", attributes: Typography.style(.body, 200).attributes(color: theme.centerChannelColor)))
            text.append(NSAttributedString(string: "@\(user?.username ?? "")", attributes: Typography.style(.body, 100).attributes(color: theme.centerChannelColor.opacity(0.64))))
        } else {
            text.append(NSAttributedString(string: "@\(user?.username ?? "someone")" + me, attributes: Typography.style(.body, 200).attributes(color: theme.centerChannelColor)))
        }
        name.attributedText = text
        accessibilityLabel = user.map { full.isEmpty ? $0.username : full } ?? "Someone"
    }
}

// MARK: - Post actions

extension ConversationViewController {
    /// Applies a local change to a post and re-lays it out (off the main thread, like everything else).
    private func update(_ postId: String, _ change: (inout Post) -> Void) {
        guard var post = posts[postId] else { return }
        change(&post)
        posts[postId] = post
        layouts[postId] = nil
        rebuild(animated: false)
    }

    fileprivate func toggleReaction(_ post: Post, _ name: String) {
        guard let me = session.me else { return }
        let mine = post.metadata?.reactions?.contains { $0.userId == me.id && $0.emojiName == name } ?? false
        // Optimistic: the chip changes on tap; the WebSocket echo is idempotent.
        update(post.id) { p in
            var list = p.metadata?.reactions ?? []
            list.removeAll { $0.userId == me.id && $0.emojiName == name }
            if !mine {
                list.append(Reaction(userId: me.id, postId: p.id, emojiName: name,
                                     createAt: Int64(Date().timeIntervalSince1970 * 1000)))
            }
            if p.metadata == nil { p.metadata = PostMetadata() }
            p.metadata?.reactions = list
        }
        if !mine { EmojiStore.shared.noteUsed(name) }
        UISelectionFeedbackGenerator().selectionChanged()
        Task {
            if mine { try? await session.client.removeReaction(userId: me.id, postId: post.id, emojiName: name) }
            else { try? await session.client.addReaction(userId: me.id, postId: post.id, emojiName: name) }
        }
    }

    fileprivate func react(_ post: Post, _ name: String) {
        let current = posts[post.id] ?? post
        let already = current.metadata?.reactions?.contains { $0.userId == session.me?.id && $0.emojiName == name } ?? false
        if !already { toggleReaction(current, name) }
    }

    fileprivate func pickReaction(for post: Post) {
        let picker = EmojiPickerViewController()
        picker.onPick = { [weak self] name in self?.react(post, name) }
        present(picker, animated: true)
    }

    fileprivate func showOptions(for post: Post) {
        guard let me = session.me else { return }
        let post = posts[post.id] ?? post
        let mine = post.userId == me.id
        let saved = session.savedPostIds.contains(post.id)
        let pinned = post.isPinned ?? false
        var options: [PostOptionsViewController.Option] = []

        if rootId == nil, !post.isSystemMessage {
            options.append(.init(icon: "reply-outline", title: "Reply", quick: true) { [weak self] in self?.openThreadScreen(post) })
        }
        if crt, !post.isSystemMessage {
            let following = post.isFollowing ?? false
            let noun = (post.replyCount ?? 0) > 0 || post.isReply || rootId != nil ? "Thread" : "Message"
            options.append(.init(icon: following ? "message-minus-outline" : "message-check-outline",
                                 title: following ? "Unfollow \(noun)" : "Follow \(noun)") { [weak self] in
                self?.setFollowing(!following, post)
            })
        }
        options.append(.init(icon: "mark-as-unread", title: "Mark as Unread") { [weak self] in self?.markUnread(post) })
        options.append(.init(icon: "link-variant", title: "Copy Link") { [weak self] in
            UIPasteboard.general.string = PostActions.permalink(post)
            self?.showToast("Link copied")
        })
        if !post.message.isEmpty {
            options.append(.init(icon: "content-copy", title: "Copy Text", quick: true) { [weak self] in
                UIPasteboard.general.string = post.message
                self?.showToast("Copied to clipboard")
            })
        }
        options.append(.init(icon: saved ? "bookmark" : "bookmark-outline", title: saved ? "Unsave" : "Save", quick: true) { [weak self] in
            self?.session.setSaved(!saved, postId: post.id)
            self?.layouts[post.id] = nil
            self?.rebuild(animated: false)
            self?.showToast(saved ? "Removed from saved messages" : "Message saved")
        })
        if !post.isSystemMessage {
            options.append(.init(icon: pinned ? "pin" : "pin-outline",
                                 title: pinned ? "Unpin from Channel" : "Pin to Channel") { [weak self] in
                self?.setPinned(!pinned, post)
            })
        }
        if !post.isSystemMessage, mine || me.isSystemAdmin {
            // Webhook/bot posts are owned by whoever made the webhook, but aren't editable (as in the official app).
            if mine, !post.fromWebhook, !post.fromBot {
                options.append(.init(icon: "pencil-outline", title: "Edit") { [weak self] in self?.edit(post) })
            }
            options.append(.init(icon: "trash-can-outline", title: "Delete", destructive: true) { [weak self] in
                self?.confirmDelete(post)
            })
        }

        let sheet = PostOptionsViewController(options: options, showsReactionBar: !post.isSystemMessage)
        sheet.onReact = { [weak self] name in self?.react(post, name) }
        sheet.onMoreReactions = { [weak self] in self?.pickReaction(for: post) }
        view.endEditing(true)
        present(sheet, animated: true)
    }

    fileprivate func setFollowing(_ follow: Bool, _ post: Post) {
        guard let me = session.me, let team = session.team else { return }
        let threadId = post.rootId.isEmpty ? post.id : post.rootId
        update(threadId) { $0.isFollowing = follow }
        if post.id != threadId { update(post.id) { $0.isFollowing = follow } }
        refreshFollowButton()
        showToast(follow ? "Thread followed" : "Thread unfollowed")
        Task {
            try? await session.client.setFollowing(follow, userId: me.id, teamId: team.id, threadId: threadId)
            session.refreshThreadTotals()
        }
    }

    private func markUnread(_ post: Post) {
        guard let me = session.me else { return }
        lastViewedAt = post.createAt - 1
        rebuild(animated: true)
        Task {
            try? await session.client.markUnread(userId: me.id, postId: post.id)
            try? await session.refreshSidebar()
        }
    }

    private func setPinned(_ pin: Bool, _ post: Post) {
        update(post.id) { $0.isPinned = pin }
        Task { try? await session.client.setPinned(pin, postId: post.id) }
        showToast(pin ? "Pinned to channel" : "Unpinned")
    }

    private func edit(_ post: Post) {
        let editor = EditPostViewController(message: post.message) { [weak self] newText in
            self?.update(post.id) { $0.message = newText; $0.editAt = Int64(Date().timeIntervalSince1970 * 1000) }
            Task { _ = try? await self?.session.client.editPost(id: post.id, message: newText) }
        }
        present(ThemedNavigationController(rootViewController: editor), animated: true)
    }

    private func confirmDelete(_ post: Post) {
        confirm(title: "Delete Post", message: "Are you sure you want to delete this post?", action: "Delete") { [weak self] in
            guard let self else { return }
            self.posts[post.id] = nil
            self.order.removeAll { $0 == post.id }
            self.rebuild(animated: true)
            Task { try? await self.session.client.deletePost(id: post.id) }
            if post.id == self.rootId { self.navigationController?.popViewController(animated: true) }
        }
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 16, dy: 10)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 32, height: s.height + 20)
    }
}

/// Edit screen: the official app opens a full-screen editor with Cancel / Save.
final class EditPostViewController: UIViewController {
    private let textView = UITextView()
    private let original: String
    private let onSave: (String) -> Void

    init(message: String, onSave: @escaping (String) -> Void) {
        original = message
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = "Edit Message"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg
        textView.text = original
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "OpenSans", size: 16)!)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = theme.centerChannelColor
        textView.backgroundColor = .clear
        textView.tintColor = theme.linkColor
        textView.keyboardAppearance = theme.centerChannelBg.luminance < 0.5 ? .dark : .light
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Save", primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let text = self.textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text != self.original { self.onSave(text) }
            self.dismiss(animated: true)
        })
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = theme.sidebarBg
        appearance.titleTextAttributes = Typography.style(.heading, 300).attributes(color: theme.sidebarHeaderTextColor)
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.tintColor = theme.sidebarHeaderTextColor
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }
}
