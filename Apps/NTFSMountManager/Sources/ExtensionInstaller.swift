import Foundation
import SystemExtensions
import SwiftUI

/// Drives the OSSystemExtensionManager lifecycle for the embedded NTFS FSKit
/// extension. The containing app must trigger activation explicitly — macOS
/// then asks the user to approve in System Settings → Privacy & Security
/// before the extension is actually loaded.
@MainActor
final class ExtensionInstaller: NSObject, ObservableObject {
    static let extensionBundleIdentifier = "com.ntfs-tool.NTFSMountManager.NTFSFileSystem"

    @Published var status: String = "Idle — not yet activated this session."
    @Published var isWorking: Bool = false

    /// Shared session log — set by the app after init. Activation lifecycle
    /// milestones are recorded here for the Activity view.
    weak var activityLog: ActivityLog?

    /// The in-flight activation/deactivation entry, updated as the request
    /// resolves via the delegate callbacks.
    private var pendingLogID: UUID?

    /// Short summary suitable for menu-bar display.
    var shortStatus: String {
        if isWorking { return "working…" }
        if status.contains("activated") { return "activated" }
        if status.contains("failed") { return "failed" }
        return "idle"
    }

    func activate() {
        isWorking = true
        status = "Submitting activation request…"
        pendingLogID = activityLog?.log("Activating system extension…", status: .running)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        isWorking = true
        status = "Submitting deactivation request…"
        pendingLogID = activityLog?.log("Deactivating system extension…", status: .running)
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Resolve the in-flight activation/deactivation log entry.
    fileprivate func finishLog(status: ActivityLog.Status, detail: String) {
        if let id = pendingLogID {
            activityLog?.update(id, status: status, detail: detail)
        }
        pendingLogID = nil
    }
}

extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.status = "Approve in System Settings → Privacy & Security, then come back here."
            if let id = self.pendingLogID {
                self.activityLog?.update(id, status: .info, detail: "Waiting for approval in System Settings → Privacy & Security.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.status = "Extension activated. NTFS volumes should now be recognized."
                self.finishLog(status: .success, detail: "Extension activated.")
            case .willCompleteAfterReboot:
                self.status = "Activation queued. Reboot required."
                self.finishLog(status: .warning, detail: "Activation queued — reboot required.")
            @unknown default:
                self.status = "Activation finished with unknown result."
                self.finishLog(status: .info, detail: "Activation finished with unknown result.")
            }
            self.isWorking = false
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        Task { @MainActor in
            self.status = "Activation failed: \(error.localizedDescription)"
            self.finishLog(status: .error, detail: "Activation failed: \(error.localizedDescription)")
            self.isWorking = false
        }
    }
}
