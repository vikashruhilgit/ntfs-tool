import XCTest
@testable import NTFSUIKit

@MainActor
final class VolumeDetailLoaderTests: XCTestCase {

    private func sampleFacts(dirty: Bool = false) -> VolumeFacts {
        VolumeFacts(
            label: "SANDISK",
            devicePath: "/dev/disk6s1",
            totalBytes: 100_000_000_000,
            freeBytes: 38_400_000_000,
            usedBytes: 61_600_000_000,
            bytesPerCluster: 4096,
            mftByteOffset: 3_221_225_472,
            mftCluster: 786_432,
            isDirty: dirty,
            ntfsMajorVersion: 3,
            ntfsMinorVersion: 1,
            isWritable: false
        )
    }

    func testViewModelMappingFromFacts() {
        let vm = VolumeInfoViewModel(facts: sampleFacts())
        XCTAssertEqual(vm.label, "SANDISK")
        XCTAssertEqual(vm.totalDisplay, "100.0 GB")
        XCTAssertEqual(vm.usedDisplay, "61.6 GB")
        XCTAssertEqual(vm.freeDisplay, "38.4 GB")
        XCTAssertEqual(vm.percentUsedDisplay, "61.6%")
        XCTAssertEqual(vm.healthStatus, "Clean")
        XCTAssertEqual(vm.permissionDisplay, "Read-only")
        XCTAssertEqual(vm.versionDisplay, "NTFS 3.1")
        XCTAssertEqual(vm.percentUsed, 0.616, accuracy: 0.0001)
        XCTAssertTrue(vm.ntfsDetailsAvailable)
    }

    /// The `statfs` fallback shape: capacity/used/free/cluster/percent are all
    /// present (mounted volumes populate the ring + metric cards), but the
    /// NTFS-internal facts are nil and degrade to the "Unavailable" strings.
    func testViewModelFromStatfsShapePartialFacts() {
        // Mimics what statfsFacts(...) returns: NTFS-internal fields all nil.
        let facts = VolumeFacts(
            label: "SANDISK",
            devicePath: "/dev/disk8s1",
            totalBytes: 100_000_000_000,
            freeBytes: 38_400_000_000,
            usedBytes: 61_600_000_000,
            bytesPerCluster: 4096,
            isWritable: false
        )
        XCTAssertFalse(facts.ntfsDetailsAvailable)

        let vm = VolumeInfoViewModel(facts: facts)
        // Capacity numbers + ring still populate.
        XCTAssertEqual(vm.totalDisplay, "100.0 GB")
        XCTAssertEqual(vm.usedDisplay, "61.6 GB")
        XCTAssertEqual(vm.freeDisplay, "38.4 GB")
        XCTAssertEqual(vm.clusterDisplay, "4 KB")
        XCTAssertEqual(vm.percentUsedDisplay, "61.6%")
        XCTAssertEqual(vm.percentUsed, 0.616, accuracy: 0.0001)
        // NTFS-only facts degrade gently.
        XCTAssertFalse(vm.ntfsDetailsAvailable)
        XCTAssertNil(vm.isDirty)
        XCTAssertEqual(vm.healthStatus, "Unavailable")
        XCTAssertEqual(vm.mftLocationDisplay, "Unavailable while mounted")
        XCTAssertEqual(vm.versionDisplay, "Unavailable")
        // Permissions still shown.
        XCTAssertEqual(vm.permissionDisplay, "Read-only")
    }

    /// `statfsFacts` reads real numbers off the current mount point without any
    /// privileges — proves the non-privileged path works end-to-end.
    func testStatfsFactsReadsMountPointWithoutPrivilege() throws {
        let facts = try VolumeDetailLoader.statfsFacts(
            mountPoint: "/",
            devicePath: "/dev/diskDummy",
            label: "root",
            isWritable: false
        )
        XCTAssertGreaterThan(facts.totalBytes, 0)
        XCTAssertGreaterThan(facts.bytesPerCluster, 0)
        XCTAssertFalse(facts.ntfsDetailsAvailable)
        XCTAssertEqual(facts.devicePath, "/dev/diskDummy")
    }

    func testLoadSuccessTransitionsToLoaded() async {
        let facts = sampleFacts()
        let loader = VolumeDetailLoader(
            devicePath: "/dev/disk6s1",
            label: "SANDISK",
            isWritable: false,
            factsProvider: { facts }
        )
        XCTAssertEqual(loader.info, .idle)
        await loader.load()
        XCTAssertNotNil(loader.info.value)
        XCTAssertEqual(loader.info.value?.usedDisplay, "61.6 GB")
    }

    func testLoadFailureSurfacesClearMessage() async {
        struct Boom: Error {}
        let loader = VolumeDetailLoader(
            devicePath: "/dev/diskX",
            label: "X",
            isWritable: false,
            factsProvider: { throw Boom() }
        )
        await loader.load()
        XCTAssertNotNil(loader.info.errorMessage)
    }

    func testVerifyCleanAndDirty() async {
        let cleanLoader = VolumeDetailLoader(
            devicePath: "/dev/disk6s1", label: "C", isWritable: false,
            verifyProvider: { VerifyResult(isClean: true, problems: []) }
        )
        await cleanLoader.runVerify()
        XCTAssertEqual(cleanLoader.verify.value?.isClean, true)

        let dirtyLoader = VolumeDetailLoader(
            devicePath: "/dev/disk6s1", label: "D", isWritable: false,
            verifyProvider: { VerifyResult(isClean: false, problems: ["dirty bit set"]) }
        )
        await dirtyLoader.runVerify()
        XCTAssertEqual(dirtyLoader.verify.value?.isClean, false)
        XCTAssertEqual(dirtyLoader.verify.value?.problems.first, "dirty bit set")
    }

    func testErrorMessageMappingForPermission() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let msg = VolumeDetailLoader.message(for: err)
        XCTAssertTrue(msg.lowercased().contains("permission"), msg)
    }

    // MARK: - Re-pointing an existing loader (the @StateObject staleness trap)

    private func loader(mountPoint: String?) -> VolumeDetailLoader {
        VolumeDetailLoader(
            devicePath: "/dev/disk6s1",
            label: "Untitled",
            isWritable: true,
            mountPoint: mountPoint
        )
    }

    /// The regression this exists for. A SwiftUI view owning the loader via
    /// `@StateObject` builds it exactly once per view identity, so a loader
    /// created before DiskArbitration reported a mount point must be able to
    /// learn it later — otherwise the non-privileged `statfs` fallback can
    /// never fire and the dashboard shows the root-only raw-device error
    /// instead of capacity.
    func testConfigureLearnsAMountPointThatArrivesLater() {
        let l = loader(mountPoint: nil)
        XCTAssertNil(l.mountPoint)

        let changed = l.configure(
            devicePath: "/dev/disk6s1",
            label: "Untitled",
            isWritable: true,
            mountPoint: "/Volumes/Untitled"
        )

        XCTAssertTrue(changed, "a newly-arrived mount point must register as a change")
        XCTAssertEqual(l.mountPoint, "/Volumes/Untitled")
    }

    /// Eject must clear the mount point, so the loader stops claiming a
    /// `statfs` path that no longer exists.
    func testConfigureClearsMountPointOnEject() {
        let l = loader(mountPoint: "/Volumes/Untitled")
        XCTAssertTrue(l.configure(devicePath: "/dev/disk6s1", label: "Untitled", isWritable: true, mountPoint: nil))
        XCTAssertNil(l.mountPoint)
    }

    /// Idempotence: re-configuring with identical values reports no change, so
    /// callers can skip a redundant reload.
    func testConfigureWithIdenticalValuesReportsNoChange() {
        let l = loader(mountPoint: "/Volumes/Untitled")
        XCTAssertFalse(
            l.configure(devicePath: "/dev/disk6s1", label: "Untitled", isWritable: true, mountPoint: "/Volumes/Untitled"),
            "unchanged inputs must not report a change"
        )
        XCTAssertEqual(l.mountPoint, "/Volumes/Untitled")
    }

    /// A renamed volume (DiskArbitration resolves the real name after the row
    /// first appears with the BSD id) must reach the loader too.
    func testConfigureUpdatesLabelAndDevicePath() {
        let l = loader(mountPoint: nil)
        XCTAssertTrue(l.configure(devicePath: "/dev/disk7s2", label: "SANDISK", isWritable: false, mountPoint: nil))
        XCTAssertEqual(l.devicePath, "/dev/disk7s2")
        XCTAssertEqual(l.label, "SANDISK")
        XCTAssertFalse(l.isWritable)
    }
}
