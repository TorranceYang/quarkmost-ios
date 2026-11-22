import UIKit

/// A bottom sheet in the official app's style (`@gorhom/bottom-sheet`): flush with the bottom edge,
/// rounded top corners, a grabber, a dimmed backdrop, and stops ("detents") you can drag between or
/// drag below to dismiss.
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

    /// Moves to another detent (e.g. the emoji picker grows when you start searching).
    func move(to detent: Detent, animated: Bool = true) {
        presentation?.move(to: detent, animated: animated)
    }

    // MARK: UIViewControllerTransitioningDelegate

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        let controller = SheetPresentationController(presentedViewController: presented, presenting: presenting, sheet: self)
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
    private let dimming = UIView()
    private let container = UIView()      // rounded, clips the content
    private let grabber = UIView()
    private var current: BottomSheet.Detent
    private var dragStartHeight: CGFloat = 0
    private var dragging = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    static let grabberArea: CGFloat = 20
    static let cornerRadius: CGFloat = 12
    static let maxWidth: CGFloat = 640

    init(presentedViewController: UIViewController, presenting: UIViewController?, sheet: BottomSheet) {
        self.sheet = sheet
        current = sheet.detents[0]
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var presentedView: UIView? { container }

    // MARK: Layout

    private func height(for detent: BottomSheet.Detent, in bounds: CGRect) -> CGFloat {
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

    private func frame(height: CGFloat) -> CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        let width = min(bounds.width, Self.maxWidth)
        // Whole points avoid a shimmering edge from sub-pixel positions while it moves.
        let y = (bounds.height - height).rounded()
        return CGRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: bounds.height - y)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let bounds = containerView?.bounds else { return .zero }
        return frame(height: height(for: current, in: bounds))
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard !dragging, let containerView else { return }
        dimming.frame = containerView.bounds
        container.frame = frameOfPresentedViewInContainerView
        layoutContent()
    }

    private func layoutContent() {
        presentedViewController.view.frame = CGRect(x: 0, y: Self.grabberArea, width: container.bounds.width,
                                                    height: container.bounds.height - Self.grabberArea)
        grabber.frame = CGRect(x: (container.bounds.width - 36) / 2, y: 7, width: 36, height: 5)
    }

    // MARK: Presentation lifecycle

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        let background = presentedViewController.view.backgroundColor ?? .systemBackground
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        dimming.alpha = 0
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimmingTapped)))
        containerView.addSubview(dimming)

        container.backgroundColor = background
        container.layer.cornerRadius = Self.cornerRadius
        container.layer.cornerCurve = .continuous
        container.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        container.clipsToBounds = true
        container.addSubview(presentedViewController.view)
        grabber.backgroundColor = Theme.current.centerChannelColor.withAlphaComponent(0.24)
        grabber.layer.cornerRadius = 2.5
        container.addSubview(grabber)
        pan.delegate = self
        container.addGestureRecognizer(pan)

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
        let apply = { self.container.frame = target; self.layoutContent() }
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

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { presenting ? 0.4 : 0.3 }

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
