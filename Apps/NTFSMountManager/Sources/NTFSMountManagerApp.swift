import SwiftUI

@main
struct NTFSMountManagerApp: App {
    @StateObject private var installer = ExtensionInstaller()

    var body: some Scene {
        // Block E v1 ships the FSKit extension only — a SwiftUI menu-bar UI
        // arrives in Block F. For now the containing app is a one-window
        // installer that activates the system extension and surfaces its
        // status. Block F will replace this with a real `MenuBarExtra`.
        WindowGroup("NTFS Mount Manager") {
            ContentView(installer: installer)
                .frame(minWidth: 440, minHeight: 280)
        }
        .windowResizability(.contentSize)
    }
}
