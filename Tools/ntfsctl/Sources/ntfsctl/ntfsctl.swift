import ArgumentParser
import Foundation
import NTFSCore

@main
struct Ntfsctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ntfsctl",
        abstract: "Read/write NTFS volumes on macOS from the command line.",
        discussion: """
            Operates on raw block devices (/dev/diskNsM) and disk-image files.
            Reads (info/list/cat/dump/verify/scan) and writes
            (create/write/truncate/cp/mv/rm/delete) — addressed by path or by
            MFT record number. ntfsctl operates on EXISTING NTFS volumes;
            format on Windows (or mkntfs-3g).
            """,
        version: "0.1.0",
        subcommands: [Info.self, List.self, Verify.self, Cat.self, Dump.self, Create.self, Delete.self, Write.self, Truncate.self, SetDirty.self, Cp.self, Rm.self, Mv.self, Scan.self, ReclaimOrphans.self]
    )
}
