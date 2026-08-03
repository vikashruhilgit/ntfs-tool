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
            Reads (info/list/tree/find/cat/dump/verify/scan) and writes
            (create/write/truncate/cp/mv/rm/delete) — addressed by path or by
            MFT record number, plus `format` to create a fresh NTFS volume.

            `tree` renders a directory recursively with a trailing
            `N directories, M files` summary; `find` searches a directory
            recursively and prints the full path of every entry whose name
            matches a glob (`--name '*.jpg' --type f`).
            """,
        version: "0.1.0",
        subcommands: [Info.self, List.self, Tree.self, Find.self, Verify.self, Cat.self, Dump.self, Create.self, Delete.self, Write.self, Truncate.self, SetDirty.self, Cp.self, Rm.self, Mv.self, Scan.self, ReclaimOrphans.self, Format.self]
    )
}
