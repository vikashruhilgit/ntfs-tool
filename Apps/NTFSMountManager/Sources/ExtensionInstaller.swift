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
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
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
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.status = "Extension activated. NTFS volumes should now be recognized."
            case .willCompleteAfterReboot:
                self.status = "Activation queued. Reboot required."
            @unknown default:
                self.status = "Activation finished with unknown result."
            }
            self.isWorking = false
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        Task { @MainActor in
            self.status = "Activation failed: \(error.localizedDescription)"
            self.isWorking = false
        }
    }
}
