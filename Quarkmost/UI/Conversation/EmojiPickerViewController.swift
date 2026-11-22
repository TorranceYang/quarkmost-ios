import UIKit

/// Emoji picker in the style of Messenger and the iOS emoji keyboard: opens at half height, search on
/// top, a "Recent" row first, then the categories with a category bar along the bottom that tracks
/// where you are and jumps on tap. Custom server emoji get their own section.
final class EmojiPickerViewController: UIViewController, UICollectionViewDelegate {
    var onPick: ((String) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        BottomSheet.install(on: self, detents: [.medium, .large])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private struct Section: Hashable {
        let id: String       // "recent", "custom", a category key, or "search"
        let title: String
        let icon: String
    }

    private let store = EmojiStore.shared
    private let custom = CustomEmojiStore.shared
    private let searchField = FlatSearchField(placeholder: "Search emoji")
    private let categoryBar = UIStackView()
    private let barBackground = UIView()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var sections: [Section] = []
    private var categoryButtons: [UIButton] = []
    private var selectedSection = 0
    private var jumping = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.current
        view.backgroundColor = theme.centerChannelBg

        searchField.returnKeyType = .done
        searchField.addAction(UIAction { [weak self] _ in self?.searchChanged() }, for: .editingChanged)
        searchField.addAction(UIAction { [weak self] _ in self?.searchField.resignFirstResponder() },
                              for: .editingDidEndOnExit)
        searchField.addAction(UIAction { [weak self] _ in
            // Searching wants room for results above the keyboard: grow the sheet, like Messenger.
            self?.bottomSheet?.move(to: .large)
        }, for: .editingDidBegin)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = theme.centerChannelBg
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        barBackground.backgroundColor = theme.centerChannelBg
        barBackground.translatesAutoresizingMaskIntoConstraints = false
        let hairline = UIView()
        hairline.backgroundColor = theme.centerChannelColor.opacity(0.12)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.axis = .horizontal
        categoryBar.distribution = .fillEqually
        categoryBar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(searchField)
        view.addSubview(collectionView)
        view.addSubview(barBackground)
        barBackground.addSubview(hairline)
        barBackground.addSubview(categoryBar)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            collectionView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: barBackground.topAnchor),
            barBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hairline.topAnchor.constraint(equalTo: barBackground.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: barBackground.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            categoryBar.topAnchor.constraint(equalTo: barBackground.topAnchor, constant: 4),
            categoryBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            categoryBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            categoryBar.heightAnchor.constraint(equalToConstant: 40),
            categoryBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -4),
        ])

        let cell = UICollectionView.CellRegistration<EmojiCell, String> { cell, _, name in
            cell.configure(name: name)
        }
        let header = UICollectionView.SupplementaryRegistration<EmojiHeader>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] view, _, indexPath in
            let title = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title ?? ""
            view.label.attributedText = NSAttributedString(
                string: title, attributes: Typography.style(.body, 75, .semibold)
                    .attributes(color: theme.centerChannelColor.opacity(0.56)))
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, name in
            cv.dequeueConfiguredReusableCell(using: cell, for: ip, item: name)
        }
        dataSource.supplementaryViewProvider = { cv, _, ip in
            cv.dequeueConfiguredReusableSupplementary(using: header, for: ip)
        }

        bottomSheet?.scrollView = collectionView
        showBrowse()
        NotificationCenter.default.addObserver(forName: CustomEmojiStore.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.searchField.text?.isEmpty ?? true else { return }
                self.showBrowse()
            }
        }
    }

    // MARK: Content

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, env in
            // ~48pt cells: 8 across on a regular phone, more on the Duo's inner screen.
            let columns = max(7, Int(env.container.effectiveContentSize.width / 48))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                                heightDimension: .absolute(48)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(48)),
                repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 0, leading: 8, bottom: 12, trailing: 8)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(28)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func showBrowse() {
        contentUnavailableConfiguration = nil
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        sections = []
        func add(_ section: Section, _ names: [String]) {
            guard !names.isEmpty else { return }
            sections.append(section)
            snapshot.appendSections([section])
            snapshot.appendItems(names, toSection: section)
        }
        var seen = Set<String>()
        let recent = store.recent.filter(store.exists).filter { seen.insert($0).inserted }
        add(Section(id: "recent", title: "Recent", icon: "clock-outline"), Array(recent.prefix(16)))
        add(Section(id: "custom", title: "Custom", icon: "emoticon-custom-outline"),
            custom.names.filter { seen.insert($0).inserted })
        let icons = ["smileys-emotion": "emoticon-happy-outline", "people-body": "account-outline",
                     "animals-nature": "leaf-outline", "food-drink": "food-apple", "travel-places": "airplane-variant",
                     "activities": "basketball", "objects": "lightbulb-outline", "symbols": "heart-outline",
                     "flags": "flag-outline"]
        for (i, c) in store.categories.enumerated() where c != "component" {
            let names = store.emoji.filter { $0.category == i && !$0.hasSkinTone }.map(\.name)
                .filter { seen.insert($0).inserted }
            add(Section(id: c, title: EmojiStore.title(forCategory: c), icon: icons[c] ?? "emoticon-outline"), names)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        rebuildCategoryBar()
        barBackground.isHidden = false
    }

    private func searchChanged() {
        let q = (searchField.text ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        guard !q.isEmpty else { showBrowse(); return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        let section = Section(id: "search", title: "", icon: "")
        var seen = Set<String>()
        let names = (custom.search(q) + store.search(q).map(\.name)).filter { seen.insert($0).inserted }
        snapshot.appendSections([section])
        snapshot.appendItems(names, toSection: section)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.setContentOffset(.zero, animated: false)
        barBackground.isHidden = true
        if names.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.text = "No emoji for “\(q)”"
            config.textProperties.color = Theme.current.centerChannelColor.opacity(0.64)
            config.textProperties.font = Typography.style(.body, 200).font
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    // MARK: Category bar

    private func rebuildCategoryBar() {
        categoryButtons.forEach { $0.removeFromSuperview() }
        categoryButtons = sections.enumerated().map { i, section in
            let b = UIButton(type: .custom)
            b.setImage(CompassIcon.image(section.icon, size: 22), for: .normal)
            b.layer.cornerRadius = 8
            b.accessibilityLabel = section.title
            b.addAction(UIAction { [weak self] _ in self?.jump(to: i) }, for: .primaryActionTriggered)
            categoryBar.addArrangedSubview(b)
            return b
        }
        highlight(min(selectedSection, max(0, sections.count - 1)))
    }

    private func highlight(_ index: Int) {
        selectedSection = index
        let theme = Theme.current
        for (i, b) in categoryButtons.enumerated() {
            let on = i == index
            b.tintColor = on ? theme.buttonBg : theme.centerChannelColor.opacity(0.48)
            b.layer.backgroundColor = (on ? theme.buttonBg.opacity(0.12) : UIColor.clear).cgColor
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    private func jump(to index: Int) {
        guard index < sections.count,
              let attrs = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: index)) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        highlight(index)
        jumping = true
        let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height
                       + collectionView.adjustedContentInset.bottom)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(attrs.frame.minY, maxY)), animated: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { jumping = false }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !jumping, !barBackground.isHidden else { return }
        // The section whose header is nearest above the top edge is the current one.
        let y = scrollView.contentOffset.y + 40
        var current = 0
        for i in sections.indices {
            guard let a = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: i)) else { continue }
            if a.frame.minY <= y { current = i } else { break }
        }
        if current != selectedSection { highlight(current) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let name = dataSource.itemIdentifier(for: indexPath) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        store.noteUsed(name)
        dismiss(animated: true) { [onPick] in onPick?(name) }
    }
}

final class EmojiCell: UICollectionViewCell {
    private let label = UILabel()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        imageView.contentMode = .scaleAspectFit
        contentView.addSubview(label)
        contentView.addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String) {
        if let unicode = EmojiStore.shared.unicode(for: name) {
            label.text = unicode
            imageView.image = nil
        } else {
            label.text = nil
            imageView.image = CustomEmojiStore.shared.image(name)
        }
        accessibilityLabel = name.replacingOccurrences(of: "_", with: " ")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
        imageView.frame = contentView.bounds.insetBy(dx: max(0, (contentView.bounds.width - 32) / 2),
                                                     dy: max(0, (contentView.bounds.height - 32) / 2))
    }

    /// Press feedback like the iOS emoji keyboard: the emoji pops up slightly.
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.contentView.transform = self.isHighlighted ? CGAffineTransform(scaleX: 1.25, y: 1.25) : .identity
            }
        }
    }
}

final class EmojiHeader: UICollectionReusableView {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 16, dy: 0)
    }
}

extension EmojiPickerViewController {
    /// Tapping the dimmed area above the sheet closes it, like the official bottom sheet.
}
