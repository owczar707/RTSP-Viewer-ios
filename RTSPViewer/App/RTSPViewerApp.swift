import SwiftData
import SwiftUI

@main
struct RTSPViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            StreamListView()
        }
        .modelContainer(for: CameraStream.self)
    }
}
