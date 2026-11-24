import UIKit

/// Navigation controller for the app's solid-color header. iOS 26+ wraps bar buttons in Liquid Glass
/// bubbles, which are designed for translucent bars and look like grey blobs on ours; the official
/// app uses flat icons. This strips the glass from every bar button and supplies a flat back chevron,
/// keeping the swipe-back gesture.
final class ThemedNavigationController: UINavigationController, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private static let backTag = 0xBAC

    /// On the iPhone Duo the status bar is a column at the side. The header stops where that column
    /// begins: this covers the bar's background (and its hairline) there with the chat color, under
    /// the bar's buttons.
    private let columnCover = UIView()

    /// Bar buttons keep the system Liquid Glass (full-screen sheets) instead of drawing flat.
    var usesGlassButtons = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        applyThemedBar()
        interactivePopGestureRecognizer?.delegate = self
        columnCover.isUserInteractionEnabled = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Folding/unfolding moves screens between navigation stacks without willShow; re-check.
        updateBarVisibility()
        // The Duo reports its status column as a side safe-area inset (~84pt; a landscape notch is ≤62).
        let insets = view.safeAreaInsets
        let bar = navigationBar
        var cover = CGRect.zero
        if insets.right >= 70 {
            cover = CGRect(x: bar.bounds.width - insets.right, y: -bar.frame.minY, width: insets.right, height: bar.frame.maxY + 1)
        } else if insets.left >= 70 {
            cover = CGRect(x: 0, y: -bar.frame.minY, width: insets.left, height: bar.frame.maxY + 1)
        }
        if cover.isEmpty || isNavigationBarHidden {
            columnCover.removeFromSuperview()
        } else {
            // Index 1: above the bar's background view, below its title and buttons.
            if columnCover.superview !== bar || bar.subviews.firstIndex(of: columnCover) != 1 {
                bar.insertSubview(columnCover, at: min(1, bar.subviews.count))
            }
            columnCover.frame = cover
            columnCover.backgroundColor = Theme.current.centerChannelBg
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        view.setNeedsLayout()
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        flatten(viewController)
        setNavigationBarHidden(Self.hidesBar(viewController), animated: animated)
        (navigationController as? ThemedNavigationController)?.updateBarVisibility()   // nested: outer bar
        // A swipe back that's let go: the screen we were on stays, so does its bar state.
        if let coordinator = transitionCoordinator, coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard context.isCancelled, let self, let top = self.topViewController else { return }
                self.setNavigationBarHidden(Self.hidesBar(top), animated: false)
            }
        }
    }

    /// Shows or hides the bar for the top screen, once any transition (ours or a parent's) ends.
    func updateBarVisibility() {
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.updateBarVisibility() }
            return
        }
        // Folded, the detail stack sits inside the list's stack, whose bar is the one on screen.
        (navigationController as? ThemedNavigationController)?.updateBarVisibility()
        guard let top = topViewController else { return }
        let hidden = Self.hidesBar(top)
        guard isNavigationBarHidden != hidden else { return }
        flatten(top)
        setNavigationBarHidden(hidden, animated: false)
    }

    /// Whether a screen draws its own header. The navigation controller is the only place the bar
    /// is shown or hidden: screens toggling it themselves raced each other when folding moved them
    /// between stacks, and left the system bar (and its Back button) over the glass header.
    static func hidesBar(_ vc: UIViewController) -> Bool {
        let shown = Self.shown(vc)
        if let own = shown as? HidesNavigationBar { return !own.showsSystemBack }
        return shown is UINavigationController
    }

    /// The screen whose items a bar shows for `vc`: a nested navigation stack (the detail stack
    /// inside the list's when folded) shows its top screen's items in the outer bar.
    private static func shown(_ vc: UIViewController) -> UIViewController {
        (vc as? UINavigationController)?.topViewController ?? vc
    }

    /// Call again after a screen replaces its bar buttons.
    func flatten(_ vc: UIViewController) {
        let item = vc.navigationItem
        let isRoot = viewControllers.first === vc
        // Collapsed split view: the detail stack's first screen still needs a way back to the list.
        let collapsedDetail = isRoot && splitViewController?.isCollapsed == true
            && splitViewController?.viewController(for: .secondary) === self
        if item.leftBarButtonItem == nil || item.leftBarButtonItem?.tag == Self.backTag {
            if (!isRoot || collapsedDetail) && !item.hidesBackButton {
                let back = UIBarButtonItem(image: CompassIcon.image("arrow-back-ios", size: 24), primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    if viewControllers.count > 1 { popViewController(animated: true) }
                    else { splitViewController?.show(.primary) }
                })
                back.tag = Self.backTag
                back.accessibilityLabel = "Back"
                item.leftBarButtonItem = back
            } else if item.leftBarButtonItem?.tag == Self.backTag {
                item.leftBarButtonItem = nil
            }
        }
        // A screen with its own header that borrows the bar only for Back keeps the system glass on
        // it (it floats over the chat, in the Duo's status column); elsewhere buttons are flat.
        let shown = Self.shown(vc)
        let glassBack = usesGlassButtons || (shown as? HidesNavigationBar)?.showsSystemBack == true
        let tint = glassBack ? Theme.current.centerChannelColor : Theme.current.sidebarHeaderTextColor
        let shownItem = shown.navigationItem
        for button in (shownItem.leftBarButtonItems ?? []) + (shownItem.rightBarButtonItems ?? []) {
            // Without the glass, items no longer pick up the bar's tint; set it on each one.
            button.tintColor = tint
            if #available(iOS 26.0, *) { button.hidesSharedBackground = !glassBack }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// Screens with their own header; their navigation controller hides the system bar, unless the
/// screen asks for it to carry just its Back button (on a transparent bar).
protocol HidesNavigationBar: UIViewController {
    var showsSystemBack: Bool { get }
}

extension HidesNavigationBar {
    var showsSystemBack: Bool { false }
}
