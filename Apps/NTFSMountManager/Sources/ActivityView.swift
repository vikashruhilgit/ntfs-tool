import SwiftUI
import NTFSUIKit

/// Global activity timeline: a scrollable, newest-first list of everything the
/// app has done this session — mounts/ejects, verify/health scans,
/// format/repair, and system-extension activation. Running operations show a
/// spinner and later flip to success/warning/error with a completion detail.
struct ActivityView: View {
    @ObservedObject var activity: ActivityLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                header

                if activity.entries.isEmpty {
                    EmptyStateView(
                        systemImage: "list.bullet.rectangle",
                        title: "No activity yet",
                        message: "Mounts, scans and repairs will show here."
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    SectionCard {
                        VStack(spacing: 0) {
                            ForEach(Array(activity.entries.enumerated()), id: \.element.id) { index, entry in
                                ActivityRow(entry: entry)
                                if index < activity.entries.count - 1 {
                                    Divider().overlay(Color.ntfsOutline.opacity(0.15))
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.large)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.ntfsSurface)
        .animation(.easeInOut(duration: 0.2), value: activity.entries)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Activity")
                .font(.ntfsDisplay)
                .foregroundStyle(Color.ntfsOnSurface)
            Spacer()
            Button {
                activity.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(activity.entries.isEmpty)
            .accessibilityLabel("Clear activity log")
        }
    }
}

/// One activity entry: a tinted status icon (a spinner overlays it while
/// running) + title + optional detail + a relative timestamp.
private struct ActivityRow: View {
    let entry: ActivityLog.Entry

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.medium) {
            ZStack {
                Image(systemName: entry.status.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(entry.status.tone)
                if entry.status == .running {
                    ProgressView()
                        .scaleEffect(0.6)
                        .offset(x: 16)
                }
            }
            .frame(width: 22, alignment: .center)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: Spacing.unit) {
                Text(entry.title)
                    .font(.ntfsTitle)
                    .foregroundStyle(Color.ntfsOnSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.ntfsCodeCaption)
                        .foregroundStyle(Color.ntfsOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.small)

            Text(entry.time.formatted(.relative(presentation: .named)))
                .font(.ntfsCodeCaption)
                .foregroundStyle(Color.ntfsOnSurfaceVariant)
                .fixedSize()
                .padding(.top, 2)
        }
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title). \(entry.detail ?? "")")
    }
}
