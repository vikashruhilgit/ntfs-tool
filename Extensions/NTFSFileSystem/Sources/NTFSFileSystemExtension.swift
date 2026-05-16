import FSKit
import Foundation

// Entry point for the NTFS FSKit System Extension. The @main attribute lets
// the system loader instantiate the extension at runtime; UnaryFileSystem
// Extension is the FSKit protocol for filesystems that present one underlying
// resource as one user-visible volume (the common case — see FSKit docs).
@available(macOS 15.4, *)
@main
struct NTFSFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: NTFSUnaryFS { NTFSUnaryFS() }
}
