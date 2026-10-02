import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationController.shared.allowedOrientations
    }
}

/// On iPhone the app is portrait-only, except for the fullscreen player which is landscape.
/// On iPad every orientation is always allowed.
@MainActor
final class OrientationController {
    static let shared = OrientationController()

    private(set) var allowedOrientations: UIInterfaceOrientationMask

    private init() {
        allowedOrientations = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    func enterFullscreen() {
        guard isPhone else { return }
        apply(.landscape)
    }

    func exitFullscreen() {
        guard isPhone else { return }
        apply(.portrait)
    }

    private func apply(_ mask: UIInterfaceOrientationMask) {
        allowedOrientations = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}
