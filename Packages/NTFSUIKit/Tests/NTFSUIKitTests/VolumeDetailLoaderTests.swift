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
}
