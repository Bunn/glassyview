import SwiftUI
import UIKit

/// Keeps the remote shortcut controls attached to UIKit's software keyboard.
/// UIKit owns this controller's presentation; it owns only its SwiftUI child.
final class RemoteKeyboardAccessoryController: UIInputViewController {
    static let height: CGFloat = 52

    private let hostingController: UIHostingController<AnyView>

    init(content: AnyView) {
        hostingController = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: Self.height)
        hostingController.safeAreaRegions = []
        hostingController.overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        inputView = RemoteKeyboardAccessoryView(height: Self.height)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    func updateContent(_ content: AnyView) {
        hostingController.rootView = content
    }
}

private final class RemoteKeyboardAccessoryView: UIInputView {
    private let accessoryHeight: CGFloat
    private var containerConstraints: [NSLayoutConstraint] = []

    init(height: CGFloat) {
        accessoryHeight = height
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .keyboard)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: accessoryHeight)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        NSLayoutConstraint.deactivate(containerConstraints)
        containerConstraints.removeAll()
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let superview else { return }
        // The input system positions its container, including during keyboard
        // animation. Fill that container's width without measuring a screen or
        // changing frames from a layout callback.
        containerConstraints = [
            leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            topAnchor.constraint(equalTo: superview.topAnchor),
            heightAnchor.constraint(equalToConstant: accessoryHeight)
        ]
        NSLayoutConstraint.activate(containerConstraints)
    }
}
