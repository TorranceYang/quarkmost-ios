import UIKit

/// A bottom sheet: a card floating just above the bottom edge with a grabber, a dimmed backdrop,
/// and stops ("detents") you can drag between or drag below to dismiss.
///
/// On a wide screen (the unfolded Duo, a phone in landscape) it floats instead as a popover card
/// beside where it was opened from, rather than stretching a sheet across the whole screen.
///
/// Replaces `UISheetPresentationController`, which on iOS 26 floats sheets on Liquid Glass. Its
/// bright rim shimmered along the top edge whenever the sheet moved, under our opaque background.
///
///     BottomSheet.install(on: viewController, detents: [.medium, .large])
///     viewController.bottomSheet?.move(to: .large)
@MainActor
final class BottomSheet: NSObject, UIViewControllerTransitioningDelegate {
    enum Detent: Equatable {
        /// Fits the content: the closure returns the content's height (grabber excluded).
        case fitting(@MainActor () -> CGFloat)
        case medium
        case large

        static func == (a: Detent, b: Detent) -> Bool {
            switch (a, b) {
            case (.fitting, .fitting), (.medium, .medium), (.large, .large): return true
            default: return false
            }
        }
    }

    let detents: [Detent]
    /// A vertical scroll view in the content; dragging it down from its top moves the sheet instead.
    weak var scrollView: UIScrollView?
    fileprivate weak var presentation: SheetPresentationController?

    private init(detents: [Detent]) {
        self.detents = detents.isEmpty ? [.medium] : detents
    }

    static func install(on viewController: UIViewController, detents: [Detent]) {
        let sheet = BottomSheet(detents: detents)
        objc_setAssociatedObject(viewController, &BottomSheet.key, sheet, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        viewController.modalPresentationStyle = .custom
        viewController.transitioningDelegate = sheet
    }

    nonisolated(unsafe) fileprivate static var key: UInt8 = 0

    private static var pendingAnchor: (point: CGPoint, time: Date)?

    /// Where the next sheet should float from when it shows as a popover (window coordinates),
    /// e.g. the spot a message was long-pressed. Used by a sheet presented within a second.
    static func anchor(at point: CGPoint) { pendingAnchor = (point, Date()) }

    fileprivate static func takeAnchor() -> CGPoint? {
        defer { pendingAnchor = nil }
        guard let pending = pendingAnchor, Date().timeIntervalSince(pending.time) < 1 else { return nil }
        return pending.point
    }

    /// Moves to another detent (e.g. the emoji picker grows when you start searching).
    func move(to detent: Detent, animated: Bool = true) {
        presentation?.move(to: detent, animated: animated)
    }

    // MARK: UIViewControllerTransitioningDelegate

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        let controller = SheetPresentationController(presentedViewController: presented, presenting: presenting, sheet: self)
        controller.source = source
        controller.anchor = BottomSheet.takeAnchor()
        presentation = controller
        return controller
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SheetAnimator(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SheetAnimator(presenting: false)
    }
}

extension UIViewController {
    /// The `BottomSheet` this view controller (or one it's embedded in) is presented with.
    var bottomSheet: BottomSheet? {
        var vc: UIViewController? = self
        while let current = vc {
            if let sheet = objc_getAssociatedObject(current, &BottomSheet.key) as? BottomSheet { return sheet }
            vc = current.parent ?? current.navigationController
        }
        return nil
    }
}

// MARK: - Presentation

@MainActor
private final class SheetPresentationController: UIPresentationController, UIGestureRecognizerDelegate {
    private let sheet: BottomSheet
    /// The screen that opened the sheet: the sheet spans only its visible width, so on the Duo it
    /// covers the chat, not the channel list or the status-bar column.
    weak var source: UIViewController?
    /// Window point a popover floats from; nil centers it over the chat.
    var anchor: CGPoint?
    private let dimming = UIView()
    private let container = UIView()      // rounded, clips the content
    private let grabber = UIView()
    private var current: BottomSheet.Detent
    private var dragStartHeight: CGFloat = 0
    private var dragging = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    static let grabberArea: CGFloat = 20
    /// The card floats this far in from the screen edges, all corners rounded.
    static let inset: CGFloat = 8
    static let cornerRadius: CGFloat = 34
    static let maxWidth: CGFloat = 640
    static let popoverWidth: CGFloat = 400
    static let popoverRadius: CGFloat = 24
    static let popoverTop: CGFloat = 10
    static let popoverMargin: CGFloat = 12

    /// Screens at least this wide (the unfolded Duo, landscape) get a popover instead of a sheet.
    static let popoverMinWidth: CGFloat = 700
    var isPopover: Bool { (containerView?.bounds.width ?? 0) >= Self.popoverMinWidth }

    init(presentedViewController: UIViewController, presenting: UIViewController?, sheet: BottomSheet) {
        self.sheet = sheet
        current = sheet.detents[0]
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var presentedView: UIView? { container }

    // MARK: Layout

    private func height(for detent: BottomSheet.Detent, in bounds: CGRect) -> CGFloat {
        if isPopover {
            let insets = containerView?.safeAreaInsets ?? .zero
            let maxHeight = bounds.height - insets.top - insets.bottom - 2 * Self.popoverMargin
            switch detent {
            case .large: return maxHeight
            case .medium: return min(maxHeight, 460)
            case .fitting(let content): return min(maxHeight, (content() + Self.popoverTop + 4).rounded())
            }
        }
        let top = (containerView?.safeAreaInsets.top ?? 0) + 10
        let maxHeight = bounds.height - top
        switch detent {
        case .large: return maxHeight
        case .medium: return min(maxHeight, (bounds.height * 0.5).rounded())
        case .fitting(let content):
            let bottom = containerView?.safeAreaInsets.bottom ?? 0
            return min(maxHeight, (content() + Self.grabberArea + bottom).rounded())
        }
    }

    private var maxDetentHeight: CGFloat {
        guard let bounds = containerView?.bounds else { return 0 }
        return sheet.detents.map { height(for: $0, in: bounds) }.max() ?? 0
    }

    /// The horizontal span the sheet may use, in container coordinates.
    private var span: (minX: CGFloat, width: CGFloat) {
        guard let containerView else { return (0, 0) }
        var area = containerView.bounds
        // Presented from the split view itself (e.g. a profile): use the chat column, not the
        // whole screen, so a popover doesn't straddle the channel list.
        var sourceView = source?.view
        if let split = source as? UISplitViewController, !split.isCollapsed,
           let secondary = split.viewController(for: .secondary)?.view {
            sourceView = secondary
        }
        if let view = sourceView, view.window != nil {
            let insets = view.safeAreaInsets
            let visible = view.bounds.inset(by: UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right))
            area = view.convert(visible, to: containerView).intersection(containerView.bounds)
            if area.isNull || area.width < 200 { area = containerView.bounds }
        }
        return (area.minX, area.width)
    }

    /// The card's horizontal extent, and how much of it the content may use. Next to the Duo's
    /// status-bar column the card runs on under the column, but its content stops
    /// where the column starts, so nothing tappable sits under the clock.
    private var horizontal: (minX: CGFloat, width: CGFloat, contentWidth: CGFloat) {
        guard let bounds = containerView?.bounds else { return (0, 0, 0) }
        let (spanX, available) = span
        let width = min(available, Self.maxWidth) - 2 * Self.inset
        let minX = (spanX + (available - min(available, Self.maxWidth)) / 2 + Self.inset).rounded()
        var maxX = minX + width
        let column = containerView?.window?.safeAreaInsets.right ?? 0
        if column >= 70, abs((spanX + available) - (bounds.width - column)) < 1 {
            maxX = bounds.width - Self.inset
        }
        return (minX, maxX - minX, width)
    }

    private func frame(height: CGFloat) -> CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let h = horizontal
        // Whole points avoid a shimmering edge from sub-pixel positions while it moves.
        let y = (bounds.height - height).rounded()
        return CGRect(x: h.minX, y: y, width: h.width, height: max(0, bounds.height - y - Self.inset))
    }

    /// The popover card: beside the anchor (the press point sits in its upper part, near the
    /// reactions), kept inside the chat and clear of the status bar and home indicator.
    private func popoverFrame(height: CGFloat) -> CGRect {
        guard let containerView else { return .zero }
        let bounds = containerView.bounds
        let insets = containerView.safeAreaInsets
        let (spanX, available) = span
        let m = Self.popoverMargin
        let width = min(Self.popoverWidth, available - 2 * m)
        var x = spanX + (available - width) / 2
        var y = (bounds.height - height) / 2
        if let anchor, let window = containerView.window {
            let p = containerView.convert(anchor, from: window)
            x = p.x - width / 2
            y = p.y - min(80, height * 0.25)
        }
        x = min(max(x, spanX + m), spanX + available - m - width)
        y = min(max(y, insets.top + m), bounds.height - insets.bottom - m - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let h = height(for: current, in: bounds)
        return isPopover ? popoverFrame(height: h) : frame(height: h)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard !dragging, let containerView else { return }
        dimming.frame = containerView.bounds
        applyStyle()
        place(frameOfPresentedViewInContainerView)
        layoutContent()
    }

    /// Sets the card's frame through bounds and center, which stay valid while a popover is scaled
    /// during its entrance animation (`frame` doesn't).
    private func place(_ frame: CGRect) {
        container.bounds.size = frame.size
        container.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func applyStyle() {
        let popover = isPopover
        let theme = Theme.current
        container.layer.cornerRadius = popover ? Self.popoverRadius : Self.cornerRadius
        container.layer.borderWidth = popover ? 1 / max(1, container.traitCollection.displayScale) : 0
        container.layer.borderColor = theme.centerChannelColor.withAlphaComponent(0.16).cgColor
        dimming.backgroundColor = UIColor.black.withAlphaComponent(popover ? 0.3 : 0.5)
        grabber.isHidden = popover
    }

    private func layoutContent() {
        if isPopover {
            presentedViewController.view.frame = CGRect(x: 0, y: Self.popoverTop, width: container.bounds.width,
                                                        height: container.bounds.height - Self.popoverTop)
            return
        }
        let contentWidth = min(container.bounds.width, horizontal.contentWidth)
        presentedViewController.view.frame = CGRect(x: 0, y: Self.grabberArea, width: contentWidth,
                                                    height: container.bounds.height - Self.grabberArea)
        grabber.frame = CGRect(x: (contentWidth - 36) / 2, y: 7, width: 36, height: 5)
    }

    // MARK: Presentation lifecycle

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        let background = presentedViewController.view.backgroundColor ?? .systemBackground
        dimming.alpha = 0
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimmingTapped)))
        containerView.addSubview(dimming)

        container.backgroundColor = background
        container.layer.cornerRadius = Self.cornerRadius
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.addSubview(presentedViewController.view)
        grabber.backgroundColor = Theme.current.centerChannelColor.withAlphaComponent(0.24)
        grabber.layer.cornerRadius = 2.5
        container.addSubview(grabber)
        pan.delegate = self
        container.addGestureRecognizer(pan)
        applyStyle()

        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in self.dimming.alpha = 1 })
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { dimming.removeFromSuperview() }
    }

    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in self.dimming.alpha = 0 })
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { dimming.removeFromSuperview() }
    }

    @objc private func dimmingTapped() {
        presentedViewController.view.endEditing(true)
        presentedViewController.dismiss(animated: true)
    }

    func move(to detent: BottomSheet.Detent, animated: Bool) {
        guard sheet.detents.contains(detent) else { return }
        current = detent
        let target = frameOfPresentedViewInContainerView
        let apply = { self.place(target); self.layoutContent() }
        if animated {
            UIViewPropertyAnimator(duration: 0.35, dampingRatio: 1, animations: apply).startAnimation()
        } else {
            apply()
        }
    }

    // MARK: Dragging

    private var scrollAtTop: Bool {
        guard let scroll = sheet.scrollView else { return true }
        return scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === sheet.scrollView
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return true }
        if isPopover { return false }
        let velocity = pan.velocity(in: container)
        guard abs(velocity.y) > abs(velocity.x) else { return false }   // leave horizontal swipes alone
        // On the scroll view: only take over when pulling down from its top, or growing the sheet.
        if let scroll = sheet.scrollView, scroll.bounds.contains(pan.location(in: scroll)) {
            let grow = velocity.y < 0 && container.frame.height < maxDetentHeight - 1
            return (velocity.y > 0 && scrollAtTop) || grow
        }
        return true
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let containerView else { return }
        let bounds = containerView.bounds
        switch g.state {
        case .began:
            dragging = true
            dragStartHeight = bounds.height - container.frame.minY
        case .changed:
            var h = dragStartHeight - g.translation(in: containerView).y
            let maxH = maxDetentHeight
            if h > maxH { h = maxH + (h - maxH) / 4 }       // rubber band past the top stop
            container.frame = frame(height: max(0, h))
            layoutContent()
            if let scroll = sheet.scrollView {               // the sheet moves, the content doesn't
                scroll.contentOffset.y = -scroll.adjustedContentInset.top
            }
        case .ended, .cancelled, .failed:
            dragging = false
            let h = bounds.height - container.frame.minY
            let projected = h - g.velocity(in: containerView).y * 0.2
            let heights = sheet.detents.map { ($0, height(for: $0, in: bounds)) }
            let smallest = heights.map(\.1).min() ?? 0
            if projected < smallest * 0.6 {
                presentedViewController.view.endEditing(true)
                presentedViewController.dismiss(animated: true)
                return
            }
            let nearest = heights.min { abs($0.1 - projected) < abs($1.1 - projected) }!.0
            move(to: nearest, animated: true)
        default:
            break
        }
    }
}

// MARK: - Present / dismiss animation

@MainActor
private final class SheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        let vc = context?.viewController(forKey: presenting ? .to : .from)
        if (vc?.presentationController as? SheetPresentationController)?.isPopover == true { return presenting ? 0.3 : 0.2 }
        return presenting ? 0.4 : 0.3
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let vc = context.viewController(forKey: key), let sheetView = vc.presentationController?.presentedView else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        if presenting {
            container.addSubview(sheetView)
            sheetView.frame = context.finalFrame(for: vc)
            sheetView.setNeedsLayout()
            sheetView.layoutIfNeeded()
            vc.presentationController?.containerViewWillLayoutSubviews()
        }
        if let controller = vc.presentationController as? SheetPresentationController, controller.isPopover {
            // A popover grows in place rather than sliding up from the bottom edge.
            let small = CGAffineTransform(scaleX: 0.92, y: 0.92)
            if presenting { sheetView.alpha = 0; sheetView.transform = small }
            let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: presenting ? 0.85 : 1) {
                sheetView.alpha = self.presenting ? 1 : 0
                sheetView.transform = self.presenting ? .identity : small
            }
            animator.addCompletion { _ in
                let done = !context.transitionWasCancelled
                sheetView.transform = .identity
                if !self.presenting, done { sheetView.removeFromSuperview() }
                context.completeTransition(done)
            }
            animator.startAnimation()
            return
        }
        let onScreen = sheetView.frame
        let offScreen = onScreen.offsetBy(dx: 0, dy: container.bounds.height - onScreen.minY)
        if presenting { sheetView.frame = offScreen }
        let animator = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: presenting ? 0.9 : 1) {
            sheetView.frame = self.presenting ? onScreen : offScreen
        }
        animator.addCompletion { _ in
            let done = !context.transitionWasCancelled
            if !self.presenting, done { sheetView.removeFromSuperview() }
            context.completeTransition(done)
        }
        animator.startAnimation()
    }
}
