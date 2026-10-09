import SwiftUI
import UIKit

/// Installs the lock cover for the scene that contains it. Place it once in
/// each scene's root view; it covers presented sheets, full-screen sessions,
/// and menus because it uses its own window above them.
struct AppLockCoverInstaller: View {
    var controller: AppLockController = .shared
    /// External displays show a plain cover without controls.
    var isInteractive = true

    var body: some View {
        AppLockCoverWindowHost(isCovered: controller.showsCover,
                               controller: controller,
                               isInteractive: isInteractive)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct AppLockCoverWindowHost: UIViewRepresentable {
    let isCovered: Bool
    let controller: AppLockController
    let isInteractive: Bool

    func makeUIView(context: Context) -> AppLockCoverAnchorView {
        AppLockCoverAnchorView(controller: controller, isInteractive: isInteractive)
    }

    func updateUIView(_ uiView: AppLockCoverAnchorView, context: Context) {
        uiView.setCovered(isCovered)
    }

    static func dismantleUIView(_ uiView: AppLockCoverAnchorView, coordinator: ()) {
        uiView.removeCover()
    }
}

/// A zero-size view whose only job is to find its scene and manage the cover
/// window there.
final class AppLockCoverAnchorView: UIView {
    private let controller: AppLockController
    private let isInteractive: Bool
    private var coverWindow: UIWindow?
    private var isCovered = false

    init(controller: AppLockController, isInteractive: Bool) {
        self.controller = controller
        self.isInteractive = isInteractive
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyCover()
    }

    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        applyCover()
    }

    func removeCover() {
        coverWindow?.isHidden = true
        coverWindow = nil
    }

    var debugCoverWindow: UIWindow? { coverWindow }

    private func applyCover() {
        guard let hostWindow = window, let scene = hostWindow.windowScene else { return }
        if isCovered {
            let cover = coverWindow ?? makeCoverWindow(in: scene)
            coverWindow = cover
            cover.frame = scene.effectiveGeometry.coordinateSpace.bounds
            if isInteractive {
                // Taking key status moves hardware keyboard focus away from
                // the remote desktop, so keystrokes cannot reach the Mac.
                cover.makeKeyAndVisible()
            } else {
                cover.isHidden = false
            }
        } else if let cover = coverWindow, !cover.isHidden {
            cover.isHidden = true
            if isInteractive, cover.isKeyWindow {
                hostWindow.makeKey()
            }
        }
    }

    private func makeCoverWindow(in scene: UIWindowScene) -> UIWindow {
        let cover = UIWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.backgroundColor = .black
        let host = UIHostingController(rootView: AppLockView(controller: controller, isInteractive: isInteractive))
        host.view.backgroundColor = .black
        cover.rootViewController = host
        return cover
    }
}

/// The lock screen. Without a lock (only obscured for the app switcher) it
/// shows just the app's mark.
struct AppLockView: View {
    let controller: AppLockController
    var isInteractive = true

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.08), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: controller.isLocked ? "lock.fill" : "display")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .accessibilityHidden(true)

                Text("Glassy Desk")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                if controller.isLocked, isInteractive {
                    Text("Locked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await controller.unlock() }
                    } label: {
                        Label(unlockTitle, systemImage: controller.availableMethod?.systemImage ?? "lock.open")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(controller.isAuthenticating)
                    .padding(.top, 8)

                    if let message = controller.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
    }

    private var unlockTitle: String {
        guard let method = controller.availableMethod else { return String(localized: "Unlock") }
        return String(localized: "Unlock with \(method.title)")
    }
}
