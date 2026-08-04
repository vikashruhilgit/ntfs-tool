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

    /// Explicit activation state.
    ///
    /// Derived state used to be sniffed out of `status` with
    /// `status.contains("activated")` — and the DEFAULT status string is
    /// "Idle — not yet activated this session.", which contains "activated"
    /// as a substring of "not yet activated". So the UI badge read
    /// "Extension: activated" before anything had been attempted, and kept
    /// reading it no matter how activation actually went. A status indicator
    /// that is green regardless of the truth is worse than none: it cost real
    /// debugging time during FSKit mount validation.
    enum State: Equatable {
        case idle
        case working
        case awaitingApproval
        case activated
        case queuedForReboot
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var status: String = "Idle — not yet activated this session."
    var isWorking: Bool { state == .working }

    /// Shared session log — set by the app after init. Activation lifecycle
    /// milestones are recorded here for the Activity view.
    weak var activityLog: ActivityLog?

    /// The in-flight activation/deactivation entry, updated as the request
    /// resolves via the delegate callbacks.
    private var pendingLogID: UUID?

    /// Short summary suitable for menu-bar display. Driven by `state`, never
    /// by substring-matching a human-readable message.
    var shortStatus: String {
        switch state {
        case .idle:             return "idle"
        case .working:          return "working…"
        case .awaitingApproval: return "needs approval"
        case .activated:        return "activated"
        case .queuedForReboot:  return "reboot required"
        case .failed:           return "failed"
        }
    }

    func activate() {
        state = .working
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
        state = .working
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
            self.state = .awaitingApproval
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
                self.state = .activated
                self.status = "Extension activated. NTFS volumes should now be recognized."
                self.finishLog(status: .success, detail: "Extension activated.")
            case .willCompleteAfterReboot:
                self.state = .queuedForReboot
                self.status = "Activation queued. Reboot required."
                self.finishLog(status: .warning, detail: "Activation queued — reboot required.")
            @unknown default:
                self.state = .idle
                self.status = "Activation finished with unknown result."
                self.finishLog(status: .info, detail: "Activation finished with unknown result.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.status = "Activation failed: \(error.localizedDescription)"
            self.finishLog(status: .error, detail: "Activation failed: \(error.localizedDescription)")
        }
    }
}
