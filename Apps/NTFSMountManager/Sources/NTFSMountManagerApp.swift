import SwiftUI

@main
struct NTFSMountManagerApp: App {
    @StateObject private var installer = ExtensionInstaller()
    @StateObject private var diskService = DiskArbitrationService()

    var body: some Scene {
        // Block F: real menu-bar app. The single-window installer the
        // Block-E scaffold shipped is now reachable via "Open Settings…"
        // for the extension activation flow; the everyday surface is the
        // menu-bar dropdown with the list of currently-attached NTFS
        // volumes and their mount/unmount affordances.
        MenuBarExtra("NTFS", systemImage: "externaldrive.connected.to.line.below") {
            MenuBarContent(installer: installer, diskService: diskService)
        }
        .menuBarExtraStyle(.window)

        Window("NTFS Mount Manager", id: "settings") {
            ContentView(installer: installer)
                .frame(minWidth: 440, minHeight: 280)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
