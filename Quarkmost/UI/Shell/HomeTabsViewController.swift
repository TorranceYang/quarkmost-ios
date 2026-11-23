import UIKit

/// The official bottom tab bar (`screens/home/tab_bar`): Home, Search, Mentions, Saved, Account.
/// 52pt tall on the center background, a 48×4 indicator in the button color above the active tab,
/// inactive icons at 48%. It lives inside the left navigation stack, so it disappears when a channel
/// is pushed on a phone and stays under the sidebar on the Duo's inner screen.
final class HomeTabsViewController: UIViewController, HidesNavigationBar {
    enum Tab: Int, CaseIterable { case home, search, mentions, saved, account }

    let channelList = ChannelListViewController()
    private lazy var searchVC = SearchViewController()
    private lazy var mentionsVC = PostResultsViewController.mentions()
    private lazy var savedVC = PostResultsViewController.saved()
    private lazy var accountVC = AccountViewController()

    private let content = UIView()
    private let bar = UIView()
    private let barStack = UIStackView()
    private let indicator = UIView()
    private var buttons: [UIButton] = []
    private let homeBadge = UILabel()
    private let accountAvatar = AvatarView(size: 28)
    private var indicatorLeading: NSLayoutConstraint!
    private(set) var selected: Tab = .home
    private var current: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        [content, bar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        barStack.axis = .horizontal
        barStack.distribution = .fillEqually
        barStack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(barStack)
        indicator.layer.cornerRadius = 4
        indicator.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        indicator.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(indicator)

        let icons = ["home-variant-outline", "magnify", "at", "bookmark-outline", "account-outline"]
        let labels = ["Home", "Search", "Recent Mentions", "Saved Messages", "Account"]
        for tab in Tab.allCases {
            let b = UIButton(type: .custom)
            b.setImage(CompassIcon.image(icons[tab.rawValue], size: 28), for: .normal)
            b.accessibilityLabel = labels[tab.rawValue]
            b.addAction(UIAction { [weak self] _ in self?.select(tab) }, for: .primaryActionTriggered)
            barStack.addArrangedSubview(b)
            buttons.append(b)
        }
        // Account tab shows your avatar instead of an icon.
        buttons[Tab.account.rawValue].setImage(nil, for: .normal)
        buttons[Tab.account.rawValue].addSubview(accountAvatar)
        accountAvatar.centerXAnchor.constraint(equalTo: buttons[Tab.account.rawValue].centerXAnchor).isActive = true
        accountAvatar.centerYAnchor.constraint(equalTo: buttons[Tab.account.rawValue].centerYAnchor).isActive = true

        homeBadge.textAlignment = .center
        homeBadge.layer.masksToBounds = true
        homeBadge.isHidden = true
        homeBadge.translatesAutoresizingMaskIntoConstraints = false
        buttons[0].addSubview(homeBadge)

        indicatorLeading = indicator.centerXAnchor.constraint(equalTo: buttons[0].centerXAnchor)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barStack.topAnchor.constraint(equalTo: bar.topAnchor),
            barStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            barStack.heightAnchor.constraint(equalToConstant: 52),
            barStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            indicator.topAnchor.constraint(equalTo: bar.topAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 48),
            indicator.heightAnchor.constraint(equalToConstant: 4),
            indicatorLeading,
            homeBadge.centerXAnchor.constraint(equalTo: buttons[0].centerXAnchor, constant: 14),
            homeBadge.centerYAnchor.constraint(equalTo: buttons[0].centerYAnchor, constant: -10),
            homeBadge.heightAnchor.constraint(equalToConstant: 18),
            homeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])

        show(channelList)
        applyTheme()
        NotificationCenter.default.addObserver(forName: .sessionSidebarChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadge() }
        }
    }

    func applyTheme() {
        let theme = Theme.current
        view.backgroundColor = theme.sidebarBg
        bar.backgroundColor = theme.centerChannelBg
        bar.layer.shadowColor = UIColor.black.cgColor
        bar.layer.shadowOpacity = 0.08
        bar.layer.shadowRadius = 4
        bar.layer.shadowOffset = CGSize(width: 0, height: -4)
        indicator.backgroundColor = theme.buttonBg
        homeBadge.backgroundColor = theme.buttonBg
        homeBadge.textColor = theme.buttonColor
        homeBadge.font = UIFont(name: "OpenSans-Bold", size: 11)
        homeBadge.layer.borderColor = theme.centerChannelBg.cgColor
        homeBadge.layer.borderWidth = 2
        homeBadge.layer.cornerRadius = 9
        refreshSelection()
        refreshBadge()
    }

    func refreshBadge() {
        let session = AppSession.shared
        accountAvatar.setUser(session.me?.id, pictureUpdate: session.me?.lastPictureUpdate)
        accountAvatar.setStatus(session.me.flatMap { session.status($0.id) }, background: Theme.current.centerChannelBg)
        let mentions = session.totalMentions
        if mentions > 0 {
            homeBadge.isHidden = false
            homeBadge.text = mentions > 99 ? " 99+ " : " \(mentions) "
        } else if session.hasUnreads {
            homeBadge.isHidden = false
            homeBadge.text = ""
        } else {
            homeBadge.isHidden = true
        }
    }

    private func refreshSelection() {
        let theme = Theme.current
        for (i, b) in buttons.enumerated() {
            let on = i == selected.rawValue
            b.tintColor = on ? theme.buttonBg : theme.centerChannelColor.opacity(0.48)
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
        accountAvatar.alpha = selected == .account ? 1 : 0.72
    }

    func select(_ tab: Tab) {
        if tab == selected {
            if tab == .search { searchVC.focus() }
            return
        }
        selected = tab
        let vc: UIViewController = switch tab {
        case .home: channelList
        case .search: searchVC
        case .mentions: mentionsVC
        case .saved: savedVC
        case .account: accountVC
        }
        show(vc)
        indicatorLeading.isActive = false
        indicatorLeading = indicator.centerXAnchor.constraint(equalTo: buttons[tab.rawValue].centerXAnchor)
        indicatorLeading.isActive = true
        UIView.animate(withDuration: 0.15) { self.bar.layoutIfNeeded() }
        refreshSelection()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func showSearch(terms: String) {
        navigationController?.popToRootViewController(animated: true)
        select(.search)
        searchVC.run(terms)
    }

    private func show(_ vc: UIViewController) {
        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(vc)
        vc.view.frame = content.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(vc.view)
        vc.didMove(toParent: self)
        current = vc
    }
}

extension Notification.Name {
    static let sessionSidebarChanged = Notification.Name("Quarkmost.sidebarChanged")
}

/// Sidebar-colored header with a large Metropolis title, used by the tab screens.
final class TabHeaderView: UIView {
    let titleLabel = UILabel()
    let accessory = UIStackView()

    init(title: String) {
        super.init(frame: .zero)
        let theme = Theme.current
        backgroundColor = theme.sidebarBg
        titleLabel.set(title, Typography.style(.heading, 700), color: theme.sidebarHeaderTextColor)
        titleLabel.accessibilityTraits = .header
        [titleLabel, accessory].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        accessory.axis = .horizontal
        accessory.spacing = 8
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 18),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            accessory.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            accessory.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
