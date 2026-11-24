import UIKit

/// A searchable list used by Find Channels, Browse Channels, New DM, Members and Add Members.
class SearchListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    struct Row: Hashable {
        let id: String
        var title: String
        var subtitle: String? = nil
        var icon: String? = nil          // Compass icon, when not a user
        var userId: String? = nil        // shows an avatar
        var pictureUpdate: Int64? = nil
        var status: String? = nil
        var detail: String? = nil
        var section: String = ""
        var emoji: String? = nil         // emoji name, drawn instead of an icon
        var completion: String? = nil    // text inserted by autocomplete
    }

    var placeholder = "Search"
    var multiSelect = false
    var maxSelection = 7
    var load: (String) async -> [Row] = { _ in [] }
    var onSelect: ((Row) -> Void)?
    var emptyText = "No results"
    private(set) var selected: [Row] = []
    var onSelectionChange: (() -> Void)?

    let field = FlatSearchField(placeholder: "Search")
    let table = UITableView(frame: .zero, style: .plain)
    private var sections: [(title: String, rows: [Row])] = []
    private var searchTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg
        field.setPlaceholder(placeholder)
        field.returnKeyType = .search
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        field.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = 48
        table.sectionHeaderTopPadding = 0
        table.keyboardDismissMode = .onDrag
        table.dataSource = self
        table.delegate = self
        table.register(ListRowCell.self, forCellReuseIdentifier: "row")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            field.heightAnchor.constraint(equalToConstant: 40),
            table.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        queryChanged()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }

    func reloadRows() { queryChanged() }

    private func queryChanged() {
        searchTask?.cancel()
        let q = (field.text ?? "").trimmingCharacters(in: .whitespaces)
        searchTask = Task { [weak self] in
            if !q.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled, let self else { return }
            let rows = await load(q)
            guard !Task.isCancelled else { return }
            var order: [String] = []
            var grouped: [String: [Row]] = [:]
            for r in rows {
                if grouped[r.section] == nil { order.append(r.section) }
                grouped[r.section, default: []].append(r)
            }
            sections = order.map { ($0, grouped[$0] ?? []) }
            table.reloadData()
            if rows.isEmpty {
                var config = UIContentUnavailableConfiguration.empty()
                config.text = q.isEmpty ? emptyText : "No matches found for “\(q)”"
                config.textProperties.color = Theme.current.centerChannelColor.opacity(0.72)
                config.textProperties.font = Typography.style(.body, 200).font
                table.backgroundView = UIContentUnavailableView(configuration: config)
            } else {
                table.backgroundView = nil
            }
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let title = sections[section].title
        guard !title.isEmpty else { return nil }
        let wrap = UIView()
        wrap.backgroundColor = Theme.current.centerChannelBg
        let label = UILabel(title.uppercased(), Typography.style(.heading, 75), color: Theme.current.centerChannelColor.opacity(0.56))
        label.frame = CGRect(x: 20, y: 12, width: 300, height: 16)
        wrap.addSubview(label)
        return wrap
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title.isEmpty ? 0 : 36
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath) as! ListRowCell
        let row = sections[indexPath.section].rows[indexPath.row]
        cell.configure(row, checked: multiSelect ? selected.contains { $0.id == row.id } : nil)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if multiSelect {
            if let i = selected.firstIndex(where: { $0.id == row.id }) { selected.remove(at: i) }
            else if selected.count < maxSelection { selected.append(row) }
            else { showToast("Group messages are limited to \(maxSelection) members") }
            tableView.reloadRows(at: [indexPath], with: .none)
            onSelectionChange?()
        } else {
            onSelect?(row)
        }
    }
}

final class ListRowCell: UITableViewCell {
    private let avatar = AvatarView(size: 32)
    private let icon = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let detail = UILabel()
    private let check = UIImageView()
    private let emojiLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let bg = UIView()
        bg.backgroundColor = Theme.current.centerChannelColor.opacity(0.08)
        selectedBackgroundView = bg
        avatar.translatesAutoresizingMaskIntoConstraints = true
        [avatar, icon, title, subtitle, detail, check, emojiLabel].forEach(contentView.addSubview)
        emojiLabel.font = .systemFont(ofSize: 24)
        emojiLabel.textAlignment = .center
        icon.contentMode = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: SearchListViewController.Row, checked: Bool?) {
        let theme = Theme.current
        avatar.isHidden = row.userId == nil
        icon.isHidden = row.userId != nil
        emojiLabel.isHidden = true
        if let name = row.emoji {
            icon.isHidden = true
            if let unicode = EmojiStore.shared.unicode(for: name) {
                emojiLabel.isHidden = false
                emojiLabel.text = unicode
            } else if let image = CustomEmojiStore.shared.image(name) {
                icon.isHidden = false
                icon.image = image.resized(to: 28)
                icon.tintColor = nil
            }
        } else if let userId = row.userId {
            avatar.setUser(userId, pictureUpdate: row.pictureUpdate)
            avatar.setStatus(row.status, background: theme.centerChannelBg)
        } else {
            icon.image = CompassIcon.image(row.icon ?? "globe", size: 24)
            icon.tintColor = theme.centerChannelColor.opacity(0.64)
        }
        title.attributedText = NSAttributedString(string: row.title, attributes: Typography.style(.body, 200).attributes(color: theme.centerChannelColor))
        subtitle.attributedText = NSAttributedString(string: row.subtitle ?? "", attributes: Typography.style(.body, 75).attributes(color: theme.centerChannelColor.opacity(0.64)))
        subtitle.isHidden = (row.subtitle ?? "").isEmpty
        detail.attributedText = NSAttributedString(string: row.detail ?? "", attributes: Typography.style(.body, 75).attributes(color: theme.centerChannelColor.opacity(0.56)))
        check.isHidden = checked == nil
        if let checked {
            check.image = CompassIcon.image(checked ? "check-circle" : "circle-outline", size: 24)
            check.tintColor = checked ? theme.buttonBg : theme.centerChannelColor.opacity(0.32)
            accessibilityTraits = checked ? [.button, .selected] : .button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        avatar.frame = CGRect(x: 20, y: (b.height - 32) / 2, width: 32, height: 32)
        icon.frame = avatar.frame
        emojiLabel.frame = avatar.frame
        let trailing: CGFloat = check.isHidden ? 20 : 56
        check.frame = CGRect(x: b.width - 44, y: (b.height - 24) / 2, width: 24, height: 24)
        let detailWidth = min(120, detail.intrinsicContentSize.width)
        detail.frame = CGRect(x: b.width - trailing - detailWidth, y: 0, width: detailWidth, height: b.height)
        let w = b.width - 64 - trailing - detailWidth - 8
        if subtitle.isHidden {
            title.frame = CGRect(x: 64, y: 0, width: w, height: b.height)
        } else {
            title.frame = CGRect(x: 64, y: 4, width: w, height: 24)
            subtitle.frame = CGRect(x: 64, y: 26, width: w, height: 16)
        }
    }
}

@MainActor
private func userRow(_ u: User, section: String = "") -> SearchListViewController.Row {
    let session = AppSession.shared
    var title = "@\(u.username)"
    if !u.fullName.isEmpty { title = "\(u.fullName)  @\(u.username)" }
    if u.id == session.me?.id { title += " (you)" }
    return .init(id: u.id, title: title, subtitle: u.position, userId: u.id, pictureUpdate: u.lastPictureUpdate,
                 status: (u.isBot ?? false) ? nil : session.status(u.id), detail: (u.isBot ?? false) ? "BOT" : nil, section: section)
}

@MainActor
private func channelRow(_ c: Channel, section: String = "") -> SearchListViewController.Row {
    let session = AppSession.shared
    if c.type == .direct, let other = session.teammateId(of: c) {
        let u = session.user(other)
        return .init(id: c.id, title: session.title(for: c), userId: other, pictureUpdate: u?.lastPictureUpdate,
                     status: session.status(other), section: section)
    }
    let icon = c.type == .privateChannel ? "lock-outline" : (c.type == .group ? "account-multiple-outline" : "globe")
    return .init(id: c.id, title: session.title(for: c), subtitle: c.purpose, icon: icon, section: section)
}

/// Find Channels (`screens/find_channels`): your channels and DMs, filtered as you type.
final class FindChannelsViewController: SearchListViewController {
    override func viewDidLoad() {
        title = "Find Channels"
        placeholder = "Find channels..."
        load = { query in
            let session = AppSession.shared
            let q = query.lowercased()
            let mine = session.allChannels.sorted { $0.lastPostAt > $1.lastPostAt }
            if q.isEmpty {
                let unread = Set(session.sidebar.flatMap(\.channels).filter { $0.unread || $0.mentions > 0 }.map(\.id))
                return mine.filter { unread.contains($0.id) }.map { channelRow($0, section: "Unreads") }
                    + mine.filter { !unread.contains($0.id) }.prefix(20).map { channelRow($0, section: "Recent") }
            }
            var rows = mine.filter { session.title(for: $0).lowercased().contains(q) || $0.name.contains(q) }.map { channelRow($0) }
            // People you don't have a DM with yet, and public channels you could join.
            if let team = session.team {
                async let users = try? session.client.searchUsers(term: query, teamId: team.id)
                async let channels = try? session.client.searchChannels(teamId: team.id, term: query)
                let known = Set(mine.compactMap { session.teammateId(of: $0) })
                let memberOf = Set(mine.map(\.id))
                let foundUsers = (await users) ?? []
                session.cache(foundUsers)
                rows += foundUsers.filter { !known.contains($0.id) && ($0.deleteAt ?? 0) == 0 }.map { userRow($0, section: "People") }
                rows += ((await channels) ?? []).filter { !memberOf.contains($0.id) && $0.deleteAt == 0 }
                    .map { var r = channelRow($0, section: "Other channels"); r.detail = "Join"; return r }
            }
            return rows
        }
        onSelect = { [weak self] row in
            let session = AppSession.shared
            if row.section == "People" { Router.shared.openDirect(userId: row.id); return }
            if row.section == "Other channels" {
                Task {
                    guard let channel = try? await session.client.channel(id: row.id) else { return }
                    do { try await session.join(channel); Router.shared.openChannel(row.id) } catch { self?.showError(error) }
                }
                return
            }
            Router.shared.openChannel(row.id)
        }
        super.viewDidLoad()
        field.becomeFirstResponder()
    }
}

/// Browse Channels (`screens/browse_channels`): public channels you haven't joined; tap to join.
final class BrowseChannelsViewController: SearchListViewController {
    override func viewDidLoad() {
        title = "Browse Channels"
        placeholder = "Search channels"
        emptyText = "No more channels to join"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Create", primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(CreateChannelViewController(), animated: true)
        })
        load = { query in
            let session = AppSession.shared
            guard let team = session.team else { return [] }
            let mine = Set(session.allChannels.map(\.id))
            let found: [Channel] = query.isEmpty
                ? ((try? await session.client.publicChannels(teamId: team.id)) ?? [])
                : ((try? await session.client.searchChannels(teamId: team.id, term: query)) ?? [])
            return found.filter { !mine.contains($0.id) && $0.deleteAt == 0 && $0.type == .open }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { channelRow($0, section: "Public Channels") }
        }
        onSelect = { [weak self] row in
            Task {
                let session = AppSession.shared
                guard let channel = try? await session.client.channel(id: row.id) else { return }
                do { try await session.join(channel); Router.shared.openChannel(row.id) }
                catch { self?.showToast("Error joining the channel") }
            }
        }
        super.viewDidLoad()
    }
}

/// Open a DM (`screens/create_direct_message`): pick one person for a DM, or several for a group message.
final class CreateDirectMessageViewController: SearchListViewController {
    override func viewDidLoad() {
        title = "New Message"
        placeholder = "Search for people"
        multiSelect = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Start", primaryAction: UIAction { [weak self] _ in self?.start() })
        navigationItem.rightBarButtonItem?.isEnabled = false
        onSelectionChange = { [weak self] in
            guard let self else { return }
            navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
            navigationItem.prompt = selected.isEmpty ? nil : selected.map { $0.title.components(separatedBy: "@").last.map { "@" + $0 } ?? $0.title }.joined(separator: ", ")
        }
        load = { query in
            let session = AppSession.shared
            guard let team = session.team else { return [] }
            let users: [User] = query.isEmpty
                ? ((try? await session.client.users(inTeam: team.id)) ?? [])
                : ((try? await session.client.searchUsers(term: query, teamId: team.id)) ?? [])
            session.cache(users)
            if let statuses = try? await session.client.statuses(userIds: users.map(\.id)) {
                for s in statuses where session.status(s.userId) != s.status { session.setStatusLocally(s.userId, s.status) }
            }
            return users.filter { ($0.deleteAt ?? 0) == 0 }.map { userRow($0) }
        }
        super.viewDidLoad()
    }

    private func start() {
        let ids = selected.map(\.id)
        Task {
            do { Router.shared.openChannel(try await AppSession.shared.openDirect(with: ids).id) }
            catch { showError(error) }
        }
    }
}

/// New Channel (`screens/create_or_edit_channel`), also used to edit name, purpose and header.
final class CreateChannelViewController: StackScreenViewController {
    private let existing: Channel?
    private let name = ThemedTextField(placeholder: "Bugs, Marketing")
    private let purpose = ThemedTextField(placeholder: "A channel to file bugs and improvements")
    private let header = ThemedTextField(placeholder: "Use Markdown to format header text")
    private var isPrivate = false

    init(editing channel: Channel? = nil) {
        self.existing = channel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = existing == nil ? "New Channel" : "Edit Channel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: existing == nil ? "Create" : "Save",
                                                            primaryAction: UIAction { [weak self] _ in self?.save() })
        if existing == nil {
            let toggle = MenuRow(icon: "lock-outline", title: "Make Private",
                                 subtitle: "When a channel is set to private, only invited team members can access and participate in that channel",
                                 accessory: .toggle(false))
            toggle.onToggle = { [weak self] on in self?.isPrivate = on }
            stack.addArrangedSubview(toggle)
        }
        func add(_ label: String, _ field: ThemedTextField, _ value: String?, note: String? = nil) {
            addPadded(UILabel(label, Typography.style(.body, 75), color: Theme.current.centerChannelColor.opacity(0.64)), top: 12, bottom: 4)
            field.text = value
            let w = UIView()
            field.translatesAutoresizingMaskIntoConstraints = false
            w.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: w.topAnchor), field.bottomAnchor.constraint(equalTo: w.bottomAnchor),
                field.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 20), field.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -20),
            ])
            stack.addArrangedSubview(w)
            if let note { addText(note, style: Typography.style(.body, 75), alpha: 0.56) }
        }
        if existing == nil || (existing?.type != .direct && existing?.type != .group) {
            add("Name", name, existing?.displayName)
            add("Purpose (optional)", purpose, existing?.purpose, note: "Describe how this channel should be used.")
        }
        add("Header (optional)", header, existing?.header,
            note: "Specify text to appear in the channel header beside the channel name. For example, include frequently used links by typing link text [Link Title](http://example.com).")
    }

    private func save() {
        let display = (name.text ?? "").trimmingCharacters(in: .whitespaces)
        let isDirect = existing?.type == .direct || existing?.type == .group
        guard isDirect || display.count >= 2 else { showToast("Channel name must be 2 or more characters"); return }
        let session = AppSession.shared
        Task {
            do {
                if let existing {
                    _ = try await session.client.patchChannel(id: existing.id, header: header.text ?? "",
                                                              purpose: isDirect ? nil : purpose.text ?? "",
                                                              displayName: isDirect ? nil : display)
                    try? await session.refreshSidebar()
                    navigationController?.popViewController(animated: true)
                } else {
                    guard let team = session.team else { return }
                    let channel = try await session.client.createChannel(teamId: team.id, displayName: display, isPrivate: isPrivate,
                                                                         purpose: purpose.text ?? "", header: header.text ?? "")
                    try? await session.refreshSidebar()
                    Router.shared.openChannel(channel.id)
                }
            } catch { showError(error) }
        }
    }
}

/// Quick actions for a channel, shared by the sidebar long-press and the channel header menu.
@MainActor
enum ChannelActions {
    static func options(for channel: Channel, from presenter: UIViewController, includeInfo: Bool = true) -> [PostOptionsViewController.Option] {
        let session = AppSession.shared
        let favorite = session.isFavorite(channel.id), muted = session.isMuted(channel.id)
        var options: [PostOptionsViewController.Option] = [
            .init(icon: favorite ? "star" : "star-outline", title: favorite ? "Unfavorite" : "Favorite",
                  shortTitle: favorite ? "Unstar" : "Star") {
                session.setFavorite(!favorite, channelId: channel.id)
            },
            .init(icon: muted ? "bell-outline" : "bell-off-outline", title: muted ? "Unmute" : "Mute") {
                session.setMuted(!muted, channelId: channel.id)
            },
        ]
        if channel.type == .open || channel.type == .privateChannel {
            options.append(.init(icon: "account-plus-outline", title: "Add members", shortTitle: "Add") {
                Router.shared.top?.present(AddMembersViewController(channel: channel).wrappedForModal(), animated: true)
            })
            options.append(.init(icon: "link-variant", title: "Copy Link") { [weak presenter] in
                let team = session.team?.name ?? ""
                UIPasteboard.general.string = ServerConfig.baseURL.appendingPathComponent("\(team)/channels/\(channel.name)").absoluteString
                presenter?.showToast("Link copied")
            })
        }
        if includeInfo {
            let label = channel.type == .direct ? "Direct message info" : (channel.type == .group ? "Group message info" : "Channel Info")
            options.append(.init(icon: "information-outline", title: label) {
                Router.shared.top?.present(ChannelInfoViewController(channelId: channel.id).wrappedForModal(), animated: true)
            })
        }
        let leaveTitle = channel.type == .direct ? "Close direct message" : (channel.type == .group ? "Close group message" : "Leave channel")
        options.append(.init(icon: "close", title: leaveTitle, destructive: true) { [weak presenter] in
            let name = session.title(for: channel)
            let message: String = switch channel.type {
            case .direct: "Are you sure you want to close this direct message? This will remove it from your home screen, but you can always open it again."
            case .group: "Are you sure you want to close this group message? This will remove it from your home screen, but you can always open it again."
            case .privateChannel: "Are you sure you want to leave the private channel \(name)? You cannot rejoin the channel unless you're invited again."
            case .open: "Are you sure you want to leave the public channel \(name)? You can always rejoin."
            }
            Router.shared.top?.confirm(title: leaveTitle, message: message, action: channel.type == .open || channel.type == .privateChannel ? "Leave" : "Close") {
                Task {
                    await session.leaveOrClose(channel)
                    Router.shared.root?.closeConversation(channelId: channel.id)
                    presenter?.presentingViewController?.dismiss(animated: true)
                }
            }
        })
        return options
    }
}

/// Channel Info (`screens/channel_info`): title, purpose and header, quick actions, then options.
final class ChannelInfoViewController: StackScreenViewController {
    private let channelId: String
    private var stats: ChannelStats?

    init(channelId: String) {
        self.channelId = channelId
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Info"
        Task {
            stats = try? await AppSession.shared.client.channelStats(id: channelId)
            build()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        build()
    }

    private func build() {
        clear()
        let session = AppSession.shared
        let theme = Theme.current
        guard let channel = session.channel(channelId) else { addText("Channel not found"); return }
        let name = session.title(for: channel)

        // Title block
        if channel.type == .direct, let other = session.teammateId(of: channel) {
            let avatar = AvatarView(size: 64)
            let u = session.user(other)
            avatar.setUser(other, pictureUpdate: u?.lastPictureUpdate)
            avatar.setStatus(session.status(other), background: theme.centerChannelBg)
            addPadded(avatar, top: 24, bottom: 8)
            addPadded(UILabel(u.map { $0.fullName.isEmpty ? $0.username : $0.fullName } ?? name, Typography.style(.heading, 600), color: theme.centerChannelColor, lines: 2), top: 0, bottom: 0)
            addPadded(UILabel("@\(u?.username ?? name)", Typography.style(.body, 200), color: theme.centerChannelColor.opacity(0.64)), top: 2, bottom: 8)
            if let position = u?.position, !position.isEmpty { addText(position) }
        } else {
            addPadded(UILabel(name, Typography.style(.heading, 700), color: theme.centerChannelColor, lines: 3), top: 24, bottom: 8)
            if let purpose = channel.purpose, !purpose.isEmpty { addText(purpose, style: Typography.style(.body, 200), alpha: 0.72) }
        }
        if let header = channel.header, !header.isEmpty {
            let style = RenderStyle.current(myUsername: session.me?.username ?? "")
            let text = MessageLabel(PostRenderer.render(header, style: style))
            addPadded(text, top: 4, bottom: 12)
        }

        // Quick actions row: Favorite, Mute, (Add members), Copy link.
        let favorite = session.isFavorite(channelId), muted = session.isMuted(channelId)
        let actions = UIStackView()
        actions.distribution = .fillEqually
        actions.spacing = 8
        func box(_ icon: String, _ title: String, active: Bool, _ run: @escaping () -> Void) {
            var config = UIButton.Configuration.filled()
            config.image = CompassIcon.image(icon, size: 24)
            config.imagePlacement = .top
            config.imagePadding = 6
            var t = AttributedString(title)
            t.font = Typography.style(.body, 50, .semibold).font
            config.attributedTitle = t
            config.baseBackgroundColor = active ? theme.buttonBg.opacity(0.08) : theme.centerChannelColor.opacity(0.04)
            config.baseForegroundColor = active ? theme.buttonBg : theme.centerChannelColor.opacity(0.64)
            config.background.cornerRadius = 4
            config.titleAlignment = .center
            config.titleLineBreakMode = .byTruncatingTail
            config.contentInsets = .init(top: 8, leading: 4, bottom: 8, trailing: 4)
            // One line, centred, shrinking to fit: two-line labels sat left-aligned and lower.
            let b = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in run(); self?.build() })
            b.titleLabel?.numberOfLines = 1
            b.titleLabel?.adjustsFontSizeToFitWidth = true
            b.titleLabel?.minimumScaleFactor = 0.8
            b.heightAnchor.constraint(equalToConstant: 70).isActive = true
            actions.addArrangedSubview(b)
        }
        box(favorite ? "star" : "star-outline", favorite ? "Favorited" : "Favorite", active: favorite) { session.setFavorite(!favorite, channelId: self.channelId) }
        box(muted ? "bell-off-outline" : "bell-outline", muted ? "Muted" : "Mute", active: muted) { session.setMuted(!muted, channelId: self.channelId) }
        if channel.type == .open || channel.type == .privateChannel {
            box("account-plus-outline", "Add", active: false) { [weak self] in
                self?.navigationController?.pushViewController(AddMembersViewController(channel: channel), animated: true)
            }
            box("link-variant", "Copy Link", active: false) { [weak self] in
                let team = session.team?.name ?? ""
                UIPasteboard.general.string = ServerConfig.baseURL.appendingPathComponent("\(team)/channels/\(channel.name)").absoluteString
                self?.showToast("Link copied")
            }
        } else {
            box("pencil-outline", "Set Header", active: false) { [weak self] in
                self?.navigationController?.pushViewController(CreateChannelViewController(editing: channel), animated: true)
            }
        }
        let aw = UIView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        aw.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: aw.topAnchor, constant: 8), actions.bottomAnchor.constraint(equalTo: aw.bottomAnchor, constant: -16),
            actions.leadingAnchor.constraint(equalTo: aw.leadingAnchor, constant: 20), actions.trailingAnchor.constraint(equalTo: aw.trailingAnchor, constant: -20),
        ])
        stack.addArrangedSubview(aw)

        // Options
        let ignore = session.member(channelId)?.notifyProps?["ignore_channel_mentions"]?.stringValue == "on"
        if channel.type != .direct {
            let row = MenuRow(icon: "at", title: "Ignore @channel, @here, @all", accessory: .toggle(ignore))
            row.onToggle = { on in session.setChannelNotifyProp("ignore_channel_mentions", on ? "on" : "off", channelId: self.channelId) }
            stack.addArrangedSubview(row)
        }
        let push = session.member(channelId)?.notifyProps?["push"]?.stringValue ?? "default"
        let pushLabel = ["default": "Default", "all": "All new messages", "mention": "Mentions", "none": "Nothing"][push] ?? push
        stack.addArrangedSubview(MenuRow(icon: "cellphone", title: "Mobile Notifications", detail: pushLabel, accessory: .chevron) { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(ChoiceListViewController(
                title: "Mobile Notifications", header: "Notify me about...",
                choices: [.init(value: "default", title: "Global default"), .init(value: "all", title: "All new messages"),
                          .init(value: "mention", title: "Mentions only"), .init(value: "none", title: "Nothing")],
                selected: push) { session.setChannelNotifyProp("push", $0, channelId: self.channelId) }, animated: true)
        })
        stack.addArrangedSubview(MenuRow(icon: "pin-outline", title: "Pinned Messages",
                                         detail: stats?.pinnedpostCount.map(String.init), accessory: .chevron) { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(PostResultsViewController.pinned(channelId: channelId), animated: true)
        })
        stack.addArrangedSubview(MenuRow(icon: "file-text-outline", title: "Files", detail: stats?.filesCount.map(String.init), accessory: .chevron) { [weak self] in
            guard let self else { return }
            let files = FileListViewController(emptyText: "No files yet") {
                guard let team = AppSession.shared.team else { return [] }
                return try await AppSession.shared.client.searchFiles(teamId: team.id, terms: "channel:\(channel.id)").ordered
            }
            files.title = "Files"
            navigationController?.pushViewController(files, animated: true)
        })
        if channel.type != .direct {
            stack.addArrangedSubview(MenuRow(icon: "account-multiple-outline", title: "Members",
                                             detail: stats.map { "\($0.memberCount)" }, accessory: .chevron) { [weak self] in
                self?.navigationController?.pushViewController(MembersViewController(channel: channel), animated: true)
            })
        }
        if channel.type == .open || channel.type == .privateChannel {
            stack.addArrangedSubview(MenuRow(icon: "settings-outline", title: "Edit Channel", accessory: .chevron) { [weak self] in
                self?.navigationController?.pushViewController(CreateChannelViewController(editing: channel), animated: true)
            })
        }
        addDivider()
        for option in ChannelActions.options(for: channel, from: self, includeInfo: false) where option.destructive {
            stack.addArrangedSubview(MenuRow(icon: option.icon, title: option.title, destructive: true, action: option.action))
        }
        if channel.type == .open || channel.type == .privateChannel, session.me?.isSystemAdmin == true || channel.creatorId == session.me?.id {
            stack.addArrangedSubview(MenuRow(icon: "archive-outline", title: "Archive Channel", destructive: true) { [weak self] in
                self?.confirm(title: "Archive Channel", message: "Are you sure you want to archive \(name)?", action: "Archive") {
                    Task {
                        do {
                            try await session.client.archiveChannel(id: channel.id)
                            try? await session.refreshSidebar()
                            Router.shared.root?.closeConversation(channelId: channel.id)
                            self?.dismiss(animated: true)
                        } catch { self?.showError(error) }
                    }
                }
            })
        }
        if let created = channel.createAt, created > 0 {
            let f = DateFormatter()
            f.dateStyle = .long
            addText("Created on \(f.string(from: Date(timeIntervalSince1970: TimeInterval(created) / 1000)))", style: Typography.style(.body, 75), alpha: 0.48)
        }
    }
}

/// Self-sizing label that draws rendered markdown.
final class MessageLabel: UILabel {
    init(_ text: NSAttributedString) {
        super.init(frame: .zero)
        numberOfLines = 0
        attributedText = text
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Members (`screens/manage_channel_members`): tap for the profile; long list searchable.
final class MembersViewController: SearchListViewController {
    private let channel: Channel
    init(channel: Channel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        title = "Members"
        placeholder = "Search members"
        let channel = channel
        var cache: [User] = []
        load = { query in
            let session = AppSession.shared
            if cache.isEmpty {
                cache = (try? await session.client.users(inChannel: channel.id)) ?? []
                session.cache(cache)
                if let statuses = try? await session.client.statuses(userIds: cache.map(\.id)) {
                    for s in statuses where session.status(s.userId) != s.status { session.setStatusLocally(s.userId, s.status) }
                }
            }
            let q = query.lowercased()
            return cache.filter { q.isEmpty || $0.username.contains(q) || $0.fullName.lowercased().contains(q) }.map { userRow($0) }
        }
        onSelect = { row in Router.shared.showProfile(userId: row.id, channelId: channel.id) }
        if channel.type == .open || channel.type == .privateChannel {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in
                self?.navigationController?.pushViewController(AddMembersViewController(channel: channel), animated: true)
            })
        }
        super.viewDidLoad()
    }
}

/// Add members (`screens/channel_add_members`).
final class AddMembersViewController: SearchListViewController {
    private let channel: Channel
    init(channel: Channel) {
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        title = "Add members"
        placeholder = "Search for people"
        multiSelect = true
        maxSelection = 50
        let channel = channel
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.add() })
        navigationItem.rightBarButtonItem?.isEnabled = false
        onSelectionChange = { [weak self] in self?.navigationItem.rightBarButtonItem?.isEnabled = !(self?.selected.isEmpty ?? true) }
        load = { query in
            let session = AppSession.shared
            guard let team = session.team else { return [] }
            let users = (try? await session.client.searchUsers(term: query, teamId: team.id, notInChannel: channel.id)) ?? []
            session.cache(users)
            return users.filter { ($0.deleteAt ?? 0) == 0 }.map { userRow($0) }
        }
        super.viewDidLoad()
    }

    private func add() {
        let ids = selected.map(\.id), channel = channel
        Task {
            for id in ids { try? await AppSession.shared.client.addMember(channelId: channel.id, userId: id) }
            showToast("\(ids.count) \(ids.count == 1 ? "member" : "members") added")
            if navigationController?.viewControllers.first === self { dismiss(animated: true) }
            else { navigationController?.popViewController(animated: true) }
        }
    }
}
