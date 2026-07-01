import SwiftUI

@main
struct NTFSMountManagerApp: App {
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var diskService = DiskArbitrationService()
    @StateObject private var helper = PrivilegedHelperClient()

    var body: some Scene {
        // Main dashboard window — sidebar + bento detail, the everyday surface.
        // Declared FIRST so it is the app's primary scene: when a MenuBarExtra
        // is primary instead, macOS doesn't give this window a standard title
        // bar, and the NavigationSplitView sidebar's top rows render above the
        // window's content area (clipped behind / above the traffic lights).
        Window("NTFS", id: "main") {
            MainWindowView(installer: installer, diskService: diskService, helper: helper)
                // A modest minimum so the window can be resized freely in BOTH
                // directions (down to this floor, up to the screen). Paired with
                // .contentMinSize below — without a content min size the window's
                // vertical resize was locked and it could grow past the screen.
                .frame(minWidth: 720, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 720)
        .defaultPosition(.center)

        // Menu-bar dropdown: the quick panel with attached NTFS volumes and
        // their mount/unmount affordances.
        MenuBarExtra("NTFS", systemImage: "externaldrive.connected.to.line.below") {
            MenuBarContent(installer: installer, diskService: diskService)
        }
        .menuBarExtraStyle(.window)

        // Extension-activation settings window (kept from the prior scaffold).
        Window("NTFS Mount Manager", id: "settings") {
            ContentView(installer: installer)
                .frame(minWidth: 440, minHeight: 280)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
