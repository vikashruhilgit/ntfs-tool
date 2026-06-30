import SwiftUI
import NTFSUIKit

/// One-time onboarding sheet describing the read-write flow end to end. Gated by
/// `@AppStorage` so it appears once; the user can reopen it from Settings later.
/// Stays inside the design system (tokens + AccentButtonStyle).
struct FirstRunSheet: View {
    @Binding var isPresented: Bool

    private struct Step: Identifiable {
        let id = UUID()
        let systemImage: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(
            systemImage: "puzzlepiece.extension.fill",
            title: "Activate the extension",
            detail: "Approve the NTFS file-system extension once in System Settings. This unlocks read-write NTFS without a kernel extension or disabling SIP."
        ),
        Step(
            systemImage: "externaldrive.fill.badge.plus",
            title: "Plug in an NTFS volume",
            detail: "Connect a USB drive or partition formatted as NTFS. It appears in the sidebar and mounts read-write through the extension."
        ),
        Step(
            systemImage: "square.and.arrow.down.on.square.fill",
            title: "Write in Finder",
            detail: "Copy, rename, and delete files directly in Finder, just like a native disk. All changes are written straight to the NTFS volume."
        ),
        Step(
            systemImage: "eject.fill",
            title: "Eject safely",
            detail: "Always eject before unplugging so pending writes flush and the volume stays clean for Windows."
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.unit) {
                Label("Read-Write NTFS", systemImage: "internaldrive.fill")
                    .font(.ntfsHeadline)
                    .foregroundStyle(Color.ntfsOnSurface)
                Text("Here's the end-to-end flow for reading and writing NTFS drives on this Mac.")
                    .font(.ntfsBody)
                    .foregroundStyle(Color.ntfsOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.medium) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: Spacing.medium) {
                        Image(systemName: step.systemImage)
                            .font(.system(size: 22))
                            .foregroundStyle(Color.ntfsPrimary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.ntfsTitle)
                                .foregroundStyle(Color.ntfsOnSurface)
                            Text(step.detail)
                                .font(.ntfsBody)
                                .foregroundStyle(Color.ntfsOnSurfaceVariant)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.title). \(step.detail)")
                }
            }

            Text("Need to fix or erase a drive? Use the Danger Zone on a volume: Format reformats it as NTFS, and Repair runs a consistency check (real corruption is repaired with Windows chkdsk /F).")
                .font(.ntfsCodeCaption)
                .foregroundStyle(Color.ntfsOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button { isPresented = false } label: {
                    Text("Get Started")
                }
                .buttonStyle(AccentButtonStyle())
                .accessibilityLabel("Dismiss the read-write onboarding")
            }
        }
        .padding(Spacing.large)
        .frame(width: 480)
        .background(Color.ntfsSurface)
    }
}
