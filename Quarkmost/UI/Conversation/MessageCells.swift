import UIKit

/// Draws a pre-rendered attributed string, plus the code-block backgrounds and quote bars
/// NSString drawing can't. Rasterization runs on a background thread (`drawsAsynchronously`).
final class MessageTextView: UIView {
    var text: NSAttributedString? {
        didSet {
            guard text !== oldValue else { return }
            cached = nil
            setNeedsDisplay()
        }
    }
    var codeBackground: UIColor = .clear
    var quoteBar: UIColor = .clear

    private var cached: (NSTextStorage, NSLayoutManager, NSTextContainer, CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        layer.drawsAsynchronously = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func stack() -> (NSLayoutManager, NSTextContainer)? {
        guard let text else { return nil }
        if let cached, cached.3 == bounds.width { return (cached.1, cached.2) }
        let (storage, lm, c) = TextMeasure.stack(text, width: bounds.width)
        cached = (storage, lm, c, bounds.width)
        return (lm, c)
    }

    override func draw(_ rect: CGRect) {
        guard let text, let (lm, container) = stack() else { return }
        let glyphs = lm.glyphRange(for: container)
        let full = NSRange(location: 0, length: text.length)

        text.enumerateAttribute(.codeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                    in: container)
            let box = CGRect(x: 0, y: r.minY - 6, width: bounds.width, height: r.height + 12)
            codeBackground.setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 4).fill()
        }
        text.enumerateAttribute(.quote, in: full) { value, range, _ in
            guard value != nil else { return }
            let r = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                    in: container)
            quoteBar.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: r.minY, width: 3, height: r.height)).fill()
        }
        lm.drawBackground(forGlyphRange: glyphs, at: .zero)
        lm.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    /// The link, @mention or ~channel under a point, if any.
    func target(at point: CGPoint) -> (NSAttributedString.Key, Any)? {
        guard let text, let (lm, container) = stack() else { return nil }
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        for key in [NSAttributedString.Key.link, .mentionUser, .channelMention, .hashtag] {
            if let value = text.attribute(key, at: index, effectiveRange: nil) { return (key, value) }
        }
        return nil
    }
}

/// One post. Flipped vertically when the list is inverted (newest at the bottom, anchored there).
final class PostCell: UICollectionViewCell {
    var onTapTarget: ((NSAttributedString.Key, Any) -> Void)?
    var onToggleReaction: ((Post, String) -> Void)?
    var onShowReactions: ((Post, String?) -> Void)?
    var onAddReaction: ((Post) -> Void)?
    var onLongPress: ((Post) -> Void)?
    var onOpenImage: ((Post, Int) -> Void)?
    var onOpenThread: ((Post) -> Void)?
    var onTap: ((Post) -> Void)?
    var onTapAvatar: ((Post) -> Void)?
    var onTapFile: ((Post, FileInfo) -> Void)?
    var onTapFailed: ((Post) -> Void)?
    var onToggleExpand: ((Post) -> Void)?
    /// Swipe right-to-left on a message to reply in its thread (like iMessage's swipe-to-reply).
    var onSwipeReply: ((Post) -> Void)?
    private let replyHint = UIImageView()
    private var swipeArmed = false
    private lazy var swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
    private let showMoreLabel = UILabel()
    /// The channel list is inverted (flipped); result lists are not.
    var flipped = true { didSet { contentView.transform = baseTransform } }
    private var baseTransform: CGAffineTransform { flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity }

    private let highlight = UIView()
    private let replyBar = UIView()
    private let commentedOnLabel = UILabel()
    private let headerRepliesButton = UIButton(type: .custom)
    private let preHeaderIcon = UIImageView()
    private let preHeaderLabel = UILabel()
    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let botTag = UILabel()
    private let timeLabel = UILabel()
    private let failedIcon = UIImageView()
    private let messageView = MessageTextView()
    private var attachmentViews: [(bar: UIView, text: MessageTextView)] = []
    private var cardViews: [UIView] = []
    private var imageViews: [UIImageView] = []
    private var playBadges: [UIImageView] = []
    private var fileViews: [FileCardView] = []
    private var chipViews: [ReactionChipView] = []
    private let addReactionButton = UIButton(type: .custom)
    private let footerLabel = UILabel()
    private var imageTasks: [Task<Void, Never>] = []
    private var layout: PostLayout?
    private var avatarTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        [highlight, replyBar, preHeaderIcon, preHeaderLabel, avatar, nameLabel, botTag, timeLabel, commentedOnLabel,
         headerRepliesButton, messageView, footerLabel, failedIcon].forEach(contentView.addSubview)
        headerRepliesButton.addAction(UIAction { [weak self] _ in
            if let post = self?.layout?.post { self?.onOpenThread?(post) }
        }, for: .touchUpInside)
        botTag.text = "BOT"
        botTag.textAlignment = .center
        botTag.layer.cornerRadius = 4
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        addGestureRecognizer(longPress)
        addReactionButton.layer.cornerRadius = 4
        addReactionButton.accessibilityLabel = "Add reaction"
        addReactionButton.addAction(UIAction { [weak self] _ in
            if let post = self?.layout?.post { self?.onAddReaction?(post) }
        }, for: .primaryActionTriggered)
        contentView.addSubview(addReactionButton)
        contentView.addSubview(showMoreLabel)
        messageView.clipsToBounds = true
        swipe.delegate = self
        addGestureRecognizer(swipe)
        replyHint.contentMode = .center
        replyHint.alpha = 0
        insertSubview(replyHint, belowSubview: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        guard let layout else { return }
        let threshold: CGFloat = 64
        // Follows the finger, with resistance past the trigger point.
        let raw = min(0, g.translation(in: self).x)
        let x = raw > -threshold ? raw : -threshold + (raw + threshold) * 0.25
        switch g.state {
        case .began:
            swipeArmed = false
            replyHint.image = CompassIcon.image("reply-outline", size: 24)
            replyHint.tintColor = Theme.current.centerChannelColor.opacity(0.64)
            replyHint.frame = CGRect(x: bounds.width - 44, y: (bounds.height - 32) / 2, width: 32, height: 32)
        case .changed:
            contentView.transform = baseTransform.concatenating(CGAffineTransform(translationX: x, y: 0))
            let progress = min(1, -raw / threshold)
            replyHint.alpha = progress
            replyHint.transform = CGAffineTransform(scaleX: 0.6 + 0.4 * progress, y: 0.6 + 0.4 * progress)
            let armed = raw <= -threshold
            if armed != swipeArmed {
                swipeArmed = armed
                if armed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                replyHint.tintColor = armed ? Theme.current.buttonBg : Theme.current.centerChannelColor.opacity(0.64)
            }
        case .ended, .cancelled, .failed:
            let fire = swipeArmed && g.state == .ended
            swipeArmed = false
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.contentView.transform = self.baseTransform
                self.replyHint.alpha = 0
            }
            if fire { onSwipeReply?(layout.post) }
        default: break
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let layout, !layout.pending else { return }
        let p = g.location(in: contentView)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Long-pressing a reaction shows who reacted, as in the official app.
        if let chip = chipViews.first(where: { !$0.isHidden && $0.frame.contains(p) }) {
            onShowReactions?(layout.post, chip.name)
            return
        }
        if layout.failed { onTapFailed?(layout.post); return }
        if let window { BottomSheet.anchor(at: g.location(in: window)) }
        onLongPress?(layout.post)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.transform = baseTransform
        replyHint.alpha = 0
        avatarTask?.cancel()
        imageTasks.forEach { $0.cancel() }
        imageTasks = []
    }

    func configure(_ layout: PostLayout, theme: Theme) {
        self.layout = layout
        let codeBg = theme.centerChannelColor.blended(over: theme.centerChannelBg, opacity: 0.06)
        let quote = theme.centerChannelColor.opacity(0.16)

        highlight.backgroundColor = layout.background
        highlight.isHidden = layout.background == nil
        preHeaderLabel.attributedText = layout.preHeader
        preHeaderLabel.isHidden = layout.preHeader == nil
        preHeaderIcon.isHidden = layout.preHeader == nil
        if layout.preHeader != nil {
            preHeaderIcon.image = CompassIcon.image((layout.post.isPinned ?? false) ? "pin-outline" : "bookmark-outline", size: 14)
            preHeaderIcon.tintColor = theme.linkColor
        }

        messageView.codeBackground = codeBg
        messageView.quoteBar = quote
        messageView.text = layout.message
        contentView.alpha = layout.pending ? 0.5 : 1
        failedIcon.isHidden = !layout.failed
        if layout.failed {
            failedIcon.image = CompassIcon.image("alert-circle-outline", size: 20)
            failedIcon.tintColor = theme.errorTextColor
        }

        let showHeader = !layout.consecutive
        [avatar, nameLabel, timeLabel].forEach { $0.isHidden = !showHeader }
        botTag.isHidden = !(showHeader && layout.isBot)
        nameLabel.attributedText = layout.name
        timeLabel.attributedText = layout.time
        if layout.isBot {
            botTag.font = UIFont(name: "OpenSans-SemiBold", size: 10)
            botTag.textColor = theme.centerChannelColor
            botTag.layer.backgroundColor = theme.centerChannelColor.opacity(0.08).cgColor
        }

        while cardViews.count < layout.cards.count {
            let v = UIView()
            v.layer.cornerRadius = 4
            v.layer.borderWidth = 1
            v.isUserInteractionEnabled = false
            contentView.insertSubview(v, aboveSubview: highlight)
            cardViews.append(v)
        }
        for (i, v) in cardViews.enumerated() {
            v.isHidden = i >= layout.cards.count
            v.layer.borderColor = theme.centerChannelColor.opacity(0.16).cgColor
        }

        while attachmentViews.count < layout.attachments.count {
            let bar = UIView(), text = MessageTextView()
            bar.layer.cornerRadius = 2
            contentView.addSubview(bar)
            contentView.addSubview(text)
            attachmentViews.append((bar, text))
        }
        for (i, pair) in attachmentViews.enumerated() {
            let visible = i < layout.attachments.count
            pair.bar.isHidden = !visible
            pair.text.isHidden = !visible
            guard visible else { continue }
            let a = layout.attachments[i]
            pair.bar.backgroundColor = a.color
            pair.text.codeBackground = codeBg
            pair.text.quoteBar = quote
            pair.text.text = a.text
        }
        footerLabel.attributedText = layout.footer
        footerLabel.isHidden = layout.footer == nil
        replyBar.isHidden = layout.replyBarFrame == nil
        replyBar.backgroundColor = layout.replyBarHighlight ? theme.mentionHighlightBg
            : theme.centerChannelColor.blended(over: theme.centerChannelBg, opacity: 0.1)
        commentedOnLabel.attributedText = layout.commentedOn
        commentedOnLabel.isHidden = layout.commentedOn == nil
        headerRepliesButton.isHidden = layout.headerReplies == nil
        if let count = layout.headerReplies {
            var config = UIButton.Configuration.plain()
            config.image = CompassIcon.image("reply-outline", size: 18)
            config.imagePadding = 2
            config.contentInsets = .zero
            var title = AttributedString(count)
            title.font = Typography.style(.body, 75, scaled: false).font
            config.attributedTitle = title
            config.baseForegroundColor = theme.linkColor
            headerRepliesButton.configuration = config
            headerRepliesButton.accessibilityLabel = "\(count) \(count == "1" ? "reply" : "replies")"
        }
        showMoreLabel.attributedText = layout.showMore
        showMoreLabel.isHidden = layout.showMore == nil

        configureImages(layout, theme: theme)
        configureFiles(layout, theme: theme)
        configureReactions(layout, theme: theme)
        if showHeader { loadAvatar(layout, theme: theme) }
        setNeedsLayout()
    }

    private func loadAvatar(_ layout: PostLayout, theme: Theme) {
        avatarTask?.cancel()
        guard let url = layout.avatarURL else {
            avatar.image = CompassIcon.image("information-outline", size: 32)
            avatar.tintColor = theme.centerChannelColor.opacity(0.64)
            return
        }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        if let hit = ImageLoader.shared.cached(url, pointSize: 32, scale: scale) {
            avatar.image = hit
            return
        }
        avatar.image = CompassIcon.image("account-outline", size: 32)
        avatar.tintColor = theme.centerChannelColor.opacity(0.32)
        let id = layout.id
        avatarTask = Task { [weak self] in
            guard let image = await ImageLoader.shared.image(url, pointSize: 32, scale: scale),
                  !Task.isCancelled, let self, self.layout?.id == id else { return }
            UIView.transition(with: avatar, duration: 0.15, options: .transitionCrossDissolve) { self.avatar.image = image }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        let top = layout.top
        highlight.frame = contentView.bounds
        preHeaderIcon.frame = CGRect(x: PostLayout.textX - 20, y: 7, width: 14, height: 14)
        preHeaderLabel.frame = CGRect(x: PostLayout.textX, y: 6, width: bounds.width - PostLayout.textX - 16, height: 16)
        avatar.frame = CGRect(x: PostLayout.side, y: top + 10, width: PostLayout.avatar, height: PostLayout.avatar)
        var x = PostLayout.textX
        nameLabel.frame = CGRect(x: x, y: top + 10, width: layout.nameWidth, height: 24)
        x += layout.nameWidth + 5
        if !botTag.isHidden {
            let w = ceil(botTag.intrinsicContentSize.width) + 8
            botTag.frame = CGRect(x: x, y: top + 14, width: w, height: 16)
            x += w + 5
        }
        timeLabel.frame = CGRect(x: x, y: top + 14, width: max(0, bounds.width - x - PostLayout.side), height: 16)
        failedIcon.frame = CGRect(x: bounds.width - 28, y: layout.messageFrame.minY, width: 20, height: 20)
        messageView.frame = layout.messageFrame
        for (i, a) in layout.attachments.enumerated() where i < attachmentViews.count {
            attachmentViews[i].bar.frame = a.barFrame
            attachmentViews[i].text.frame = a.frame
        }
        for (i, c) in layout.cards.enumerated() where i < cardViews.count { cardViews[i].frame = c.frame }
        for (i, image) in layout.images.enumerated() where i < imageViews.count {
            imageViews[i].frame = image.frame
            playBadges[i].frame = CGRect(x: (image.frame.width - 48) / 2, y: (image.frame.height - 48) / 2, width: 48, height: 48)
        }
        for (i, f) in layout.files.enumerated() where i < fileViews.count { fileViews[i].frame = f.frame }
        for (i, chip) in layout.reactions.enumerated() where i < chipViews.count { chipViews[i].frame = chip.frame }
        if let f = layout.addReactionFrame { addReactionButton.frame = f }
        footerLabel.frame = layout.footerFrame
        showMoreLabel.frame = layout.showMoreFrame
        if let f = layout.replyBarFrame { replyBar.frame = f }
        commentedOnLabel.frame = layout.commentedOnFrame
        if !headerRepliesButton.isHidden {
            let size = headerRepliesButton.intrinsicContentSize
            headerRepliesButton.frame = CGRect(x: bounds.width - PostLayout.side - size.width - 4, y: layout.top + 8,
                                               width: size.width + 8, height: 28)
            // Keep the time label clear of the count.
            timeLabel.frame.size.width = max(0, headerRepliesButton.frame.minX - timeLabel.frame.minX - 4)
        }
    }

    private func configureImages(_ layout: PostLayout, theme: Theme) {
        while imageViews.count < layout.images.count {
            let v = UIImageView()
            v.accessibilityTraits = .image
            v.isAccessibilityElement = true
            v.accessibilityLabel = "Image"
            let badge = UIImageView(image: CompassIcon.image("play", size: 32))
            badge.tintColor = .white
            badge.contentMode = .center
            badge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            badge.layer.cornerRadius = 24
            badge.layer.masksToBounds = true
            v.addSubview(badge)
            contentView.addSubview(v)
            imageViews.append(v)
            playBadges.append(badge)
        }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let placeholder = theme.centerChannelColor.blended(over: theme.centerChannelBg, opacity: 0.08)
        for (i, v) in imageViews.enumerated() {
            guard i < layout.images.count else { v.isHidden = true; continue }
            v.isHidden = false
            let item = layout.images[i]
            playBadges[i].isHidden = !item.isVideo
            if let hit = ImageLoader.shared.cached(item.previewURL, size: item.frame.size, scale: scale, cornerRadius: 8) {
                v.image = hit
                v.layer.backgroundColor = nil
                continue
            }
            v.image = nil
            v.layer.backgroundColor = placeholder.cgColor
            v.layer.cornerRadius = 8
            let id = layout.id
            imageTasks.append(Task { [weak self, weak v] in
                guard let image = await ImageLoader.shared.image(item.previewURL, size: item.frame.size, scale: scale, cornerRadius: 8),
                      !Task.isCancelled, let self, let v, self.layout?.id == id else { return }
                UIView.transition(with: v, duration: 0.2, options: .transitionCrossDissolve) {
                    v.image = image
                    v.layer.backgroundColor = nil
                }
            })
        }
    }

    private func configureFiles(_ layout: PostLayout, theme: Theme) {
        while fileViews.count < layout.files.count {
            let v = FileCardView()
            v.isUserInteractionEnabled = false
            contentView.addSubview(v)
            fileViews.append(v)
        }
        for (i, v) in fileViews.enumerated() {
            v.isHidden = i >= layout.files.count
            if i < layout.files.count { v.configure(layout.files[i].info, theme: theme) }
        }
    }

    private func configureReactions(_ layout: PostLayout, theme: Theme) {
        while chipViews.count < layout.reactions.count {
            let chip = ReactionChipView()
            chip.addAction(UIAction { [weak self, weak chip] _ in
                guard let self, let chip, let post = self.layout?.post else { return }
                self.onToggleReaction?(post, chip.name)
            }, for: .touchUpInside)
            contentView.addSubview(chip)
            chipViews.append(chip)
        }
        for (i, chip) in chipViews.enumerated() {
            chip.isHidden = i >= layout.reactions.count
            if i < layout.reactions.count { chip.configure(layout.reactions[i], theme: theme) }
        }
        addReactionButton.isHidden = layout.addReactionFrame == nil
        addReactionButton.layer.backgroundColor = theme.centerChannelColor.opacity(0.08).cgColor
        addReactionButton.setImage(CompassIcon.image("emoticon-plus-outline", size: 24), for: .normal)
        addReactionButton.tintColor = theme.centerChannelColor.opacity(0.5)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let layout else { return }
        let p = g.location(in: contentView)
        if layout.failed { onTapFailed?(layout.post); return }
        if layout.showMore != nil, layout.showMoreFrame.contains(p) { onToggleExpand?(layout.post); return }
        for view in [messageView] + attachmentViews.map(\.text) where !view.isHidden {
            let q = g.location(in: view)
            if view.bounds.contains(q), let target = view.target(at: q) {
                onTapTarget?(target.0, target.1)
                return
            }
        }
        if let i = layout.images.firstIndex(where: { $0.frame.contains(p) }) { onOpenImage?(layout.post, i); return }
        if let file = layout.files.first(where: { $0.frame.contains(p) }) { onTapFile?(layout.post, file.info); return }
        if let card = layout.cards.first(where: { $0.frame.contains(p) }), let url = card.url {
            onTapTarget?(.link, url)
            return
        }
        if layout.footer != nil, layout.footerFrame.insetBy(dx: 0, dy: -8).contains(p) { onOpenThread?(layout.post); return }
        if !layout.consecutive, !layout.isSystem,
           avatar.frame.insetBy(dx: -6, dy: -6).contains(p) || nameLabel.frame.contains(p) {
            onTapAvatar?(layout.post)
            return
        }
        onTap?(layout.post)
    }
}

/// 64pt file card: type icon, name, and "TYPE size". Audio files show play/pause for inline playback.
final class FileCardView: UIView {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let infoLabel = UILabel()
    private var fileId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 4
        layer.borderWidth = 1
        [icon, nameLabel, infoLabel].forEach(addSubview)
        NotificationCenter.default.addObserver(forName: AudioPlayback.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioState() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var info: FileInfo?

    func configure(_ info: FileInfo, theme: Theme) {
        self.info = info
        fileId = info.id
        layer.borderColor = theme.centerChannelColor.opacity(0.16).cgColor
        backgroundColor = theme.centerChannelBg
        nameLabel.attributedText = NSAttributedString(string: info.name, attributes:
            Typography.style(.body, 200, .semibold, scaled: false).attributes(color: theme.centerChannelColor))
        nameLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.attributedText = NSAttributedString(
            string: "\(info.extension.uppercased()) \(formatFileSize(info.size))",
            attributes: Typography.style(.body, 75, scaled: false).attributes(color: theme.centerChannelColor.opacity(0.64)))
        refreshAudioState()
        setNeedsLayout()
    }

    private func refreshAudioState() {
        guard let info else { return }
        let theme = Theme.current
        if info.mimeType.hasPrefix("audio/") {
            let playing = AudioPlayback.shared.playingFileId == info.id
            icon.image = CompassIcon.image(playing ? "pause" : "play", size: 40)
            icon.tintColor = theme.buttonBg
        } else {
            icon.image = CompassIcon.image(Self.iconName(info), size: 40)
            icon.tintColor = Self.iconColor(info, theme)
        }
    }

    static func iconName(_ f: FileInfo) -> String {
        let e = f.extension.lowercased()
        if f.mimeType.hasPrefix("image/") { return "file-image-outline" }
        if f.mimeType.hasPrefix("video/") { return "file-video-outline" }
        if f.mimeType.hasPrefix("audio/") { return "file-audio-outline" }
        switch e {
        case "pdf": return "file-pdf-outline"
        case "doc", "docx", "pages": return "file-word-outline"
        case "xls", "xlsx", "csv", "numbers": return "file-excel-outline"
        case "ppt", "pptx", "key": return "file-powerpoint-outline"
        case "zip", "gz", "tar", "rar", "7z": return "file-zip-outline"
        case "txt", "md", "rtf", "log": return "file-text-outline"
        case "swift", "js", "ts", "py", "go", "json", "html", "css", "java", "c", "cpp", "sh", "yml", "yaml", "xml", "rb", "rs":
            return "file-code-outline"
        case "patch", "diff": return "file-patch-outline"
        default: return "file-generic-outline"
        }
    }

    static func iconColor(_ f: FileInfo, _ theme: Theme) -> UIColor {
        switch iconName(f) {
        case "file-pdf-outline": return .hex(0xD24B4E)
        case "file-word-outline": return .hex(0x1875F0)
        case "file-excel-outline": return .hex(0x06D6A0)
        case "file-powerpoint-outline": return .hex(0xE07315)
        case "file-zip-outline": return .hex(0x0F65CB)
        default: return theme.centerChannelColor.opacity(0.64)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 12, y: 12, width: 40, height: 40)
        nameLabel.frame = CGRect(x: 64, y: 10, width: bounds.width - 76, height: 24)
        infoLabel.frame = CGRect(x: 64, y: 34, width: bounds.width - 76, height: 16)
    }
}

extension PostCell: UIGestureRecognizerDelegate {
    /// Controls inside the cell (reaction chips, buttons) get their own taps; the link-tap recognizer
    /// only sees touches on text.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === swipe else { return true }
        // Only a clearly horizontal, leftward drag starts the reply swipe; everything else scrolls.
        guard onSwipeReply != nil, let layout, !layout.isSystem, !layout.pending, !layout.failed else { return false }
        let v = swipe.velocity(in: self)
        return v.x < 0 && abs(v.x) > abs(v.y) * 1.5
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

/// "Today" / "Yesterday" / "Nov 12" between days: thin lines either side, 12pt SemiBold.
final class DateSeparatorCell: UICollectionViewCell {
    static let height: CGFloat = 8 + 16 + 8
    var flipped = true { didSet { contentView.transform = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity } }
    private let label = UILabel()
    private let left = UIView(), right = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        [left, right, label].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, theme: Theme, color: UIColor? = nil) {
        let c = color ?? theme.centerChannelColor
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: Typography.style(.body, 75, .semibold).font, .foregroundColor: c])
        let line = color ?? theme.centerChannelColor.blended(over: theme.centerChannelBg, opacity: 0.1)
        left.backgroundColor = line
        right.backgroundColor = line
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = label.intrinsicContentSize
        let mid = bounds.midY
        label.frame = CGRect(x: (bounds.width - size.width) / 2, y: mid - size.height / 2,
                             width: size.width, height: size.height)
        let px = 1 / max(traitCollection.displayScale, 1)
        left.frame = CGRect(x: 16, y: mid, width: max(0, label.frame.minX - 12 - 16), height: px)
        right.frame = CGRect(x: label.frame.maxX + 12, y: mid, width: max(0, bounds.width - 16 - label.frame.maxX - 12), height: px)
    }
}

/// Inverted single-column list with precomputed heights: no self-sizing passes, ever.
final class MessageListLayout: UICollectionViewLayout {
    var heightForItem: ((IndexPath) -> CGFloat)?
    /// Space before the first item (the visual bottom of an inverted list).
    var leadingPadding: CGFloat = 0
    private var frames: [CGRect] = []
    private var contentHeight: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let cv = collectionView, cv.numberOfSections > 0 else { frames = []; contentHeight = 0; return }
        let count = cv.numberOfItems(inSection: 0)
        let width = cv.bounds.width
        frames.removeAll(keepingCapacity: true)
        var y: CGFloat = leadingPadding
        for i in 0..<count {
            let h = heightForItem?(IndexPath(item: i, section: 0)) ?? 44
            frames.append(CGRect(x: 0, y: y, width: width, height: h))
            y += h
        }
        contentHeight = y
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !frames.isEmpty else { return [] }
        // Binary search for the first frame intersecting rect.
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var result: [UICollectionViewLayoutAttributes] = []
        var i = lo
        while i < frames.count, frames[i].minY <= rect.maxY {
            let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
            a.frame = frames[i]
            result.append(a)
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < frames.count else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        a.frame = frames[indexPath.item]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

/// One reaction: emoji + count in a 32pt chip. Yours gets the button-color outline and count.
final class ReactionChipView: UIControl {
    private(set) var name = ""
    private let emojiLabel = UILabel()
    private let emojiImage = UIImageView()
    private let countLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 4
        emojiLabel.font = .systemFont(ofSize: 18)
        emojiLabel.textAlignment = .center
        emojiImage.contentMode = .scaleAspectFit
        [emojiLabel, emojiImage, countLabel].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ chip: PostLayout.ReactionChip, theme: Theme) {
        name = chip.name
        let custom = CustomEmojiStore.shared.image(chip.name)
        emojiImage.image = custom
        emojiImage.isHidden = custom == nil
        emojiLabel.isHidden = custom != nil
        emojiLabel.text = chip.emoji
        emojiLabel.font = chip.emoji.hasPrefix(":") ? Typography.style(.body, 75).font : .systemFont(ofSize: 18)
        countLabel.attributedText = NSAttributedString(string: "\(chip.count)", attributes: [
            .font: Typography.style(.body, 100, .semibold).font,
            .foregroundColor: chip.mine ? theme.buttonBg : theme.centerChannelColor.opacity(0.56)])
        layer.backgroundColor = (chip.mine ? theme.buttonBg.opacity(0.08) : theme.centerChannelColor.opacity(0.08)).cgColor
        layer.borderWidth = chip.mine ? 1 : 0
        layer.borderColor = theme.buttonBg.cgColor
        accessibilityLabel = "\(chip.name.replacingOccurrences(of: "_", with: " ")), \(chip.count)"
        accessibilityValue = chip.mine ? "Reacted" : nil
        setNeedsLayout()
    }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let count = countLabel.intrinsicContentSize
        emojiLabel.frame = CGRect(x: 5, y: 0, width: 22, height: bounds.height)
        emojiImage.frame = CGRect(x: 5, y: (bounds.height - 20) / 2, width: 22, height: 20)
        countLabel.frame = CGRect(x: bounds.width - 8 - count.width, y: (bounds.height - count.height) / 2,
                                  width: count.width, height: count.height)
    }
}
