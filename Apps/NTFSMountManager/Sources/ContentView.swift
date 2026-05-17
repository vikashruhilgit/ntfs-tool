import SwiftUI

struct ContentView: View {
    @ObservedObject var installer: ExtensionInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NTFS Mount Manager")
                .font(.title)
            Text("Activates the NTFS FSKit system extension so macOS can mount NTFS volumes via the in-repo driver.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Extension status").font(.headline)
            Text(installer.status).monospaced()

            HStack {
                Button("Activate Extension") { installer.activate() }
                    .disabled(installer.isWorking)
                Button("Deactivate Extension") { installer.deactivate() }
                    .disabled(installer.isWorking)
                Spacer()
                if installer.isWorking { ProgressView().scaleEffect(0.6) }
            }

            Divider()

            Text("First-run flow: macOS will prompt you to approve the extension in System Settings → Privacy & Security. After approval, plug in an NTFS volume — `diskutil list` should show it; mount via `diskutil mount /dev/diskNsM` or wait for Finder to surface it. See README for detailed steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
    }
}
