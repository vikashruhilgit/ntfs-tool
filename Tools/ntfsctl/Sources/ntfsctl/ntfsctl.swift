import ArgumentParser
import Foundation
import NTFSCore

@main
struct Ntfsctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ntfsctl",
        abstract: "Command-line companion to the ntfs-tool NTFSCore reader.",
        discussion: """
            Operates on raw block devices (/dev/diskNsM) and disk-image files.
            Read-only in v1; write subcommands land with Block G.
            """,
        version: "0.1.0",
        subcommands: [Info.self, List.self, Verify.self, Cat.self, Dump.self, Create.self, Delete.self, Write.self, Truncate.self, SetDirty.self, Cp.self, Rm.self, Mv.self, Scan.self, ReclaimOrphans.self]
    )
}
