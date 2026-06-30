import SwiftUI

@main
struct NTFSMountManagerApp: App {
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var diskService = DiskArbitrationService()

    var body: some Scene {
        // Main dashboard window — sidebar + bento detail, the everyday surface.
        // Declared FIRST so it is the app's primary scene: when a MenuBarExtra
        // is primary instead, macOS doesn't give this window a standard title
        // bar, and the NavigationSplitView sidebar's top rows render above the
        // window's content area (clipped behind / above the traffic lights).
        Window("NTFS", id: "main") {
            MainWindowView(installer: installer, diskService: diskService)
        }
        // Size the WINDOW, not the split-view content. A min-height frame on
        // the NavigationSplitView itself mis-anchors the sidebar list (its top
        // rows render above the window's content area). NOTE: do NOT use
        // .windowResizability(.contentSize) here either — it breaks the
        // title-bar safe-area inset.
        .defaultSize(width: 980, height: 640)
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
